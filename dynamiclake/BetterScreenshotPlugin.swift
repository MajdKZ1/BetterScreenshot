import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

typealias Message = [String: Any]

let recentLimit = 2
let activityID = "screenshot"
let fileManager = FileManager.default
let home = ProcessInfo.processInfo.environment["HOME"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
} ?? fileManager.homeDirectoryForCurrentUser
let bridge = home.appendingPathComponent("Library/Application Support/BetterScreenshot")

struct CaptureState: Decodable {
    let folder: String
    let capture: String?
    let token: String?
    let deadline: TimeInterval?

    var directory: URL? {
        guard folder.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: folder, isDirectory: true).resolvingSymlinksInPath()
    }

    static func read() -> CaptureState? {
        guard let data = try? Data(contentsOf: bridge.appendingPathComponent("dynamiclake.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(CaptureState.self, from: data)
    }
}

struct Screenshot: Hashable {
    static let pattern = try! NSRegularExpression(
        pattern: #"^Screenshot_([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2}-[0-9]{2}-[0-9]{2})(?:_([0-9]+))?\.png$"#
    )

    let url: URL
    let date: String
    let time: String
    let sequence: Int
    let created: Date
    let modified: Date
    let size: UInt64

    init?(_ url: URL) {
        let name = url.lastPathComponent as NSString
        guard let match = Self.pattern.firstMatch(in: name as String, range: NSRange(location: 0, length: name.length)),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber, size.uint64Value > 0
        else { return nil }

        self.url = url
        date = name.substring(with: match.range(at: 1))
        time = name.substring(with: match.range(at: 2))
        let suffix = match.range(at: 3)
        sequence = suffix.location == NSNotFound ? 1 : Int(name.substring(with: suffix)) ?? 1
        self.modified = modified
        created = attributes[.creationDate] as? Date ?? modified
        self.size = size.uint64Value
    }

    var timestamp: String { date + " " + time.replacingOccurrences(of: "-", with: ":") }

    static func list(in directory: URL) throws -> [Screenshot] {
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                       options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return files.compactMap(Screenshot.init).sorted {
            ($0.date, $0.time, $0.sequence) > ($1.date, $1.time, $1.sequence)
        }
    }
}

struct HistoryCutoffs {
    private let file = bridge.appendingPathComponent("history-cutoffs.json")
    private var dates: [String: Date] = [:]

    init() {
        if let data = try? Data(contentsOf: file) {
            dates = (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
        }
    }

    subscript(directory: URL) -> Date? { dates[key(for: directory)] }

    mutating func clear(directory: URL) throws {
        var updated = dates
        updated[key(for: directory)] = Date()
        try fileManager.createDirectory(at: bridge, withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        dates = updated
    }

    private func key(for directory: URL) -> String { directory.resolvingSymlinksInPath().path }
}

func thumbnail(of screenshot: Screenshot) -> Data? {
    guard let source = CGImageSourceCreateWithURL(screenshot.url as CFURL, nil),
          CGImageSourceGetType(source) == UTType.png.identifier as CFString else { return nil }
    for dimension in [96, 56] {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: dimension
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        // A small inline thumbnail updates with its action in one frame.
        if CGImageDestinationFinalize(destination), CFDataGetLength(data) <= 3_000 { return data as Data }
    }
    return nil
}

func inlineImage(_ data: Data) -> Message {
    ["type": "image", "source": "inlineData", "mimeType": "image/jpeg",
     "base64Data": data.base64EncodedString()]
}

func copyImage(_ url: URL, to pasteboard: NSPasteboard) -> Bool {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetType(source) == UTType.png.identifier as CFString,
          CGImageSourceGetStatus(source) == .statusComplete else { return false }
    let item = NSPasteboardItem()
    guard item.setData(data, forType: .png) else { return false }
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
}

enum ProtocolError: Error {
    case socket, invalidFrame
}

final class HostConnection {
    let features: Set<String>
    private let handle: FileHandle
    private let frameLimit: Int

    init(environment: [String: String]) throws {
        features = Set((environment["DYNAMICLAKE_PLUGIN_FEATURES"] ?? "").split(separator: ",").map(String.init))
        frameLimit = features.contains("imageAssets") ? 256 * 1024 : 64 * 1024
        guard let path = environment["DYNAMICLAKE_JSON_SOCKET"] else { throw ProtocolError.socket }

        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ProtocolError.socket }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProtocolError.socket }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            throw ProtocolError.socket
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func send(_ type: String, _ fields: Message = [:]) throws {
        var message = fields
        message["schemaVersion"] = 1
        message["type"] = type
        let payload = try JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)
        guard payload.count <= frameLimit else { throw ProtocolError.invalidFrame }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        try handle.write(contentsOf: frame)
    }

    private func read(_ length: Int) throws -> Data? {
        var data = Data()
        while data.count < length {
            guard let chunk = try handle.read(upToCount: length - data.count), !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }

    func receive() throws -> Message? {
        guard let header = try read(4) else { return nil }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...frameLimit).contains(length), let payload = try read(length),
              let message = try JSONSerialization.jsonObject(with: payload) as? Message
        else { throw ProtocolError.invalidFrame }
        return message
    }
}

private struct HistoryRow {
    let screenshot: Screenshot
    let image: Message
}

private enum HistoryCopyControl {
    case thumbnail, button
}

private struct CopyFeedback {
    let screenshot: Screenshot
    let control: HistoryCopyControl
    let expiresAt: TimeInterval
}

final class Plugin {
    private let host: HostConnection
    private var lastRequest: String?
    private var pending: [String: Date] = [:]
    private var dismissAt: Date?
    private var creationRequest: String?
    private var copyTargets: [String: Screenshot] = [:]
    private var historyTargets: [String: HistoryRow] = [:]
    private var historyPage = 0
    private var historyExpanded = false
    private var historyNeedsRefresh = false
    private var copyFeedback: CopyFeedback?
    private var historyCutoffs = HistoryCutoffs()
    private var displayedHistoryDirectory: URL?

    init(host: HostConnection) { self.host = host }

    func tick() throws {
        let now = Date()
        pending = pending.filter { $0.value > now }

        if historyNeedsRefresh {
            historyNeedsRefresh = false
            try publishHistory()
        }

        if let feedback = copyFeedback, ProcessInfo.processInfo.systemUptime >= feedback.expiresAt {
            copyFeedback = nil
            try patchCopyFeedback(for: [feedback.screenshot])
        }

        // Process captures first so one arriving at the deadline extends the same activity.
        if let state = CaptureState.read(), let token = state.token, token != lastRequest {
            lastRequest = token
            try handleRequest(state, token: token)
        }

        if let dismissAt, Date() >= dismissAt { try dismiss() }
    }

    private func handleRequest(_ state: CaptureState, token: String) throws {
        guard let directory = state.directory, let time = state.deadline else { return }
        let deadline = Date(timeIntervalSince1970: time)
        guard deadline.timeIntervalSinceNow > 0.2, !acknowledgedTokens().contains(token) else { return }

        if let name = state.capture {
            guard !name.contains("/"), let screenshot = Screenshot(directory.appendingPathComponent(name)),
                  let jpeg = thumbnail(of: screenshot), deadline.timeIntervalSinceNow > 0.15 else { return }

            copyTargets.removeAll()
            let picture = selectableImage(jpeg, action: "recent", label: "Show recent screenshots")
            try show(["leftSlot": picture], duration: 3, requestID: token)
            historyNeedsRefresh = true
        } else {
            let pictures = recentImages(in: directory)
            guard deadline.timeIntervalSinceNow > 0.15 else { return }
            guard !pictures.isEmpty else {
                acknowledge(token)
                return
            }
            try showRecent(pictures, requestID: token)
        }
        pending[token] = deadline
    }

    private func selectableImage(_ data: Data, action: String, label: String) -> Message {
        var image = inlineImage(data)
        image["actionID"] = action
        image["title"] = label
        return image
    }

    private func show(_ compact: Message, duration: TimeInterval, requestID: String? = nil) throws {
        let creating = dismissAt == nil
        var command: Message = [
            "activityID": activityID,
            "surfaces": ["compactLiveActivity": compact]
        ]
        if creating {
            creationRequest = requestID
            command["title"] = "BetterScreenshot"
            command["size"] = "small"
            command["priority"] = "normal"
        }
        if let requestID { command["requestID"] = requestID }
        try host.send(creating ? "create" : "update", command)
        dismissAt = Date().addingTimeInterval(duration)
    }

    private func dismiss() throws {
        dismissAt = nil
        copyTargets.removeAll()
        try host.send("dismiss", ["activityID": activityID])
    }

    private func recentImages(in directory: URL) -> [(Screenshot, Data)] {
        do {
            let screenshots = try visibleScreenshots(in: directory)
            return Array(screenshots.lazy.compactMap { screenshot in
                thumbnail(of: screenshot).map { (screenshot, $0) }
            }.prefix(recentLimit))
        } catch {
            log("Screenshot folder unavailable: \(error.localizedDescription)")
            return []
        }
    }

    private func showRecent(_ pictures: [(Screenshot, Data)], requestID: String? = nil) throws {
        var compact: Message = [:]
        copyTargets.removeAll()
        for (slot, picture) in zip(["leftSlot", "rightSlot"], pictures) {
            let (screenshot, data) = picture
            let action = "copy:" + UUID().uuidString
            let label = slot == "leftSlot" ? "Copy latest screenshot" : "Copy previous screenshot"
            compact[slot] = selectableImage(data, action: action, label: label)
            copyTargets[action] = screenshot
        }
        try show(compact, duration: 8, requestID: requestID)
    }

    private var acknowledgementFile: URL { bridge.appendingPathComponent("dynamiclake-ack") }

    private func acknowledgedTokens() -> [String] {
        let contents = try? String(contentsOf: acknowledgementFile, encoding: .utf8)
        return (contents ?? "").split(separator: "\n").map(String.init)
    }

    private func acknowledge(_ token: String) {
        let recent = ([token] + acknowledgedTokens()).prefix(8)
        try? recent.joined(separator: "\n").write(to: acknowledgementFile, atomically: true, encoding: .utf8)
    }

    func receive(_ message: Message) throws {
        guard message["schemaVersion"] as? Int == 1 else { return }
        switch message["type"] as? String {
        case "response":
            guard let token = message["requestID"] as? String, let deadline = pending.removeValue(forKey: token)
            else { return }
            if message["ok"] as? Bool == true && Date() < deadline {
                acknowledge(token)
            } else if message["ok"] as? Bool == false && token == creationRequest {
                dismissAt = nil
                copyTargets.removeAll()
            }
        case "error":
            log(message["error"] as? String ?? "DynamicLake rejected a command.")
        case "lakeOpened":
            resetHistory()
            try publishHistory()
        case "lakeClosed":
            if historyExpanded || copyFeedback != nil {
                resetHistory()
                try publishHistory()
            }
        case "action":
            guard let action = message["actionID"] as? String else { return }
            if message["surface"] as? String == "lake" {
                try performHistoryAction(action)
            } else if message["activityID"] as? String == activityID, dismissAt != nil {
                try perform(action)
            }
        default:
            break
        }
    }

    private func perform(_ action: String) throws {
        let directory = screenshotDirectory
        if action == "recent", copyTargets.isEmpty {
            let pictures = recentImages(in: directory)
            if pictures.isEmpty {
                try dismiss()
            } else {
                try showRecent(pictures)
            }
        } else if let screenshot = copyTargets[action] {
            if available(screenshot) && copyImage(screenshot.url, to: .general) {
                try dismiss()
            } else {
                let pictures = recentImages(in: directory).filter { $0.0 != screenshot }
                if pictures.isEmpty {
                    try dismiss()
                } else {
                    try showRecent(pictures)
                }
            }
        }
    }

    private var screenshotDirectory: URL {
        CaptureState.read()?.directory ?? home.appendingPathComponent("Pictures/Screenshots", isDirectory: true)
    }

    private func available(_ screenshot: Screenshot) -> Bool {
        let parent = screenshot.url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return parent == screenshotDirectory.resolvingSymlinksInPath().path && Screenshot(screenshot.url) == screenshot
    }

    private func visibleScreenshots(in directory: URL) throws -> [Screenshot] {
        let screenshots = try Screenshot.list(in: directory)
        guard let cutoff = historyCutoffs[directory] else { return screenshots }
        return screenshots.filter { $0.created > cutoff }
    }

    private func resetHistory() {
        historyExpanded = false
        historyPage = 0
        copyFeedback = nil
    }

    func publishHistory() throws {
        guard host.features.contains("lake") else { return }
        var lake: Message = [
            "title": label("Screenshot History"),
            "leftSlot": ["type": "image", "source": "sfSymbol", "systemImage": "camera.viewfinder"]
        ]
        guard host.features.contains("lakeLayout") else {
            lake["subtitle"] = label("Update DynamicLake to browse screenshots")
            try host.send("lake", ["lake": lake])
            return
        }

        let screenshots: [Screenshot]
        let directory = screenshotDirectory
        var emptyMessage = historyCutoffs[directory] == nil ? "No screenshots yet" : "History cleared"
        do {
            screenshots = try visibleScreenshots(in: directory)
        } catch {
            screenshots = []
            emptyMessage = "Screenshot folder unavailable"
        }
        let pageSize = host.features.contains("imageAssets") ? 12 : 6
        let pageCount = max(1, (screenshots.count + pageSize - 1) / pageSize)
        historyPage = min(max(0, historyPage), pageCount - 1)
        historyTargets.removeAll()
        var rows: [Message] = []
        var glanceRows: [Message] = []
        let limit = historyExpanded ? pageSize : recentLimit
        for screenshot in screenshots.dropFirst(historyPage * pageSize).prefix(limit) {
            let id = UUID().uuidString
            var image: Message = ["type": "image", "source": "sfSymbol", "systemImage": "photo"]
            if let jpeg = thumbnail(of: screenshot) { image = inlineImage(jpeg) }
            image["actionID"] = "copy-image:" + id
            image["title"] = "Copy Image"
            image["size"] = historyExpanded ? 38 : 30
            image["cornerRadius"] = 6
            let row = HistoryRow(screenshot: screenshot, image: image)
            historyTargets[id] = row
            rows.append(historyRow(row, id: id, surface: "lake"))
            glanceRows.append(historyRow(row, id: id, surface: "glance"))
        }

        if rows.isEmpty {
            let content = [label(emptyMessage)]
            lake["content"] = content
            lake["glance"] = ["hideHeader": true, "content": content]
        } else if historyExpanded {
            lake["content"] = Array(rows.prefix(2))
            var bottom = [historyControls(pages: pageCount, compact: false)]
            if rows.count > 2 {
                bottom.insert(historyScroll(Array(rows.dropFirst(2)), surface: "lake"), at: 0)
            }
            lake["bottom"] = bottom
            lake["glance"] = ["hideHeader": true, "content": [
                historyScroll(glanceRows, surface: "glance"), historyControls(pages: pageCount, compact: true)
            ]]
        } else {
            let expand: Message = ["type": "hstack", "children": [
                ["type": "spacer"], capsule("Expand", icon: "chevron.down", action: "history:expand")
            ]]
            lake = ["hideHeader": true, "content": rows + [expand],
                    "glance": ["hideHeader": true, "content": glanceRows + [expand]]]
        }
        try host.send("lake", ["lake": lake])
        displayedHistoryDirectory = directory
    }

    private func historyRow(_ row: HistoryRow, id: String, surface: String) -> Message {
        let screenshot = row.screenshot
        let revealAction = "reveal:" + id
        let copy = historyCopyControls(row, id: id, surface: surface)
        let date = surface == "glance" ? String(screenshot.date.suffix(5)).replacingOccurrences(of: "-", with: "/")
                                      : screenshot.timestamp
        let menu: [Message] = [
            ["title": "Copy Image", "systemImage": "doc.on.doc", "actionID": "copy:" + id],
            ["title": "Reveal in Finder", "systemImage": "folder", "actionID": revealAction]
        ]
        return ["type": "hstack", "spacing": 6, "contextMenu": menu, "children": [
            copy.thumbnail, label(date), ["type": "spacer"], copy.button,
            historyButton("Reveal in Finder", icon: "folder", action: revealAction)
        ]]
    }

    private func historyScroll(_ rows: [Message], surface: String) -> Message {
        [
            "type": "scroll", "id": "\(surface)-page-\(historyPage)", "spacing": 6, "children": rows
        ]
    }

    private func historyControls(pages: Int, compact: Bool) -> Message {
        var controls: [Message] = [
            capsule(compact ? "Clear" : "Clear History", icon: "trash", action: "history:clear"),
            ["type": "spacer"]
        ]
        if historyPage > 0 {
            controls.append(historyButton("Newer screenshots", icon: "chevron.left", action: "page:newer"))
        }
        if pages > 1 {
            controls.append(label("\(historyPage + 1) / \(pages)"))
        }
        if historyPage + 1 < pages {
            controls.append(historyButton("Older screenshots", icon: "chevron.right", action: "page:older"))
        }
        controls.append(compact
            ? historyButton("Collapse", icon: "chevron.up", action: "history:collapse")
            : capsule("Collapse", icon: "chevron.up", action: "history:collapse"))
        return ["type": "hstack", "spacing": 4, "children": controls]
    }

    private func label(_ text: String) -> Message {
        ["type": "text", "text": text, "style": "compact"]
    }

    private func historyButton(_ title: String, icon: String, action: String) -> Message {
        ["type": "button", "shape": "plain", "title": title, "systemImage": icon, "actionID": action, "size": 24]
    }

    private func capsule(_ title: String, icon: String, action: String) -> Message {
        ["type": "button", "shape": "roundedRect", "title": title, "systemImage": icon, "actionID": action, "size": 24]
    }

    private func historyCopyControls(_ row: HistoryRow, id: String, surface: String) -> (thumbnail: Message, button: Message) {
        let feedback = copyFeedback?.screenshot == row.screenshot ? copyFeedback?.control : nil
        var images = [row.image]
        if feedback == .thumbnail {
            images.append([
                "type": "image", "source": "sfSymbol", "systemImage": "checkmark.circle.fill",
                "size": 22, "tint": "green", "title": "Copied", "actionID": "copy-image:" + id
            ])
        }
        let thumbnail: Message = [
            "type": "zstack", "id": "\(surface)-thumbnail-\(id)", "children": images
        ]
        let checked = feedback == .button
        var button = historyButton(checked ? "Copied" : "Copy Image",
                                   icon: checked ? "checkmark" : "doc.on.doc", action: "copy:" + id)
        button["id"] = "\(surface)-copy-\(id)"
        if checked { button["tint"] = "green" }
        return (thumbnail, button)
    }

    private func patchCopyFeedback(for screenshots: Set<Screenshot>) throws {
        let components = historyTargets.flatMap { id, row -> [Message] in
            guard screenshots.contains(row.screenshot) else { return [] }
            return ["lake", "glance"].flatMap { surface -> [Message] in
                let controls = historyCopyControls(row, id: id, surface: surface)
                return [controls.thumbnail, controls.button]
            }
        }
        if !components.isEmpty { try host.send("lakePatch", ["components": components]) }
    }

    private func performHistoryAction(_ action: String) throws {
        if action == "history:expand" || action == "history:collapse" {
            historyExpanded = action == "history:expand"
            historyPage = 0
            try publishHistory()
            return
        }
        if action == "history:clear" {
            let directory = screenshotDirectory
            guard directory.resolvingSymlinksInPath().path == displayedHistoryDirectory?.resolvingSymlinksInPath().path
            else {
                historyPage = 0
                try publishHistory()
                return
            }
            do {
                try historyCutoffs.clear(directory: directory)
            } catch {
                log("Could not clear screenshot history: \(error.localizedDescription)")
                return
            }
            resetHistory()
            if !copyTargets.isEmpty { try dismiss() }
            try publishHistory()
            return
        }
        let parts = action.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        if historyExpanded, parts[0] == "page", parts[1] == "older" || parts[1] == "newer" {
            historyPage += parts[1] == "older" ? 1 : -1
            try publishHistory()
            return
        }
        guard let screenshot = historyTargets[String(parts[1])]?.screenshot else { return }
        guard available(screenshot) else {
            try publishHistory()
            return
        }
        switch parts[0] {
        case "copy", "copy-image":
            guard copyImage(screenshot.url, to: .general) else {
                try publishHistory()
                return
            }
            var changed: Set<Screenshot> = [screenshot]
            if let previous = copyFeedback { changed.insert(previous.screenshot) }
            copyFeedback = CopyFeedback(screenshot: screenshot,
                                        control: parts[0] == "copy-image" ? .thumbnail : .button,
                                        expiresAt: ProcessInfo.processInfo.systemUptime + 1.2)
            try patchCopyFeedback(for: changed)
        case "reveal":
            let reveal = Process()
            reveal.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            reveal.arguments = ["-R", screenshot.url.path]
            do {
                try reveal.run()
            } catch {
                log("Could not reveal screenshot: \(error.localizedDescription)")
            }
        default:
            break
        }
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data(("BetterScreenshot: " + message + "\n").utf8))
}

func run() throws {
    signal(SIGPIPE, SIG_IGN)
    let host = try HostConnection(environment: ProcessInfo.processInfo.environment)
    let plugin = Plugin(host: host)
    try plugin.publishHistory()

    DispatchQueue.global().async {
        do {
            while let message = try host.receive() {
                DispatchQueue.main.async {
                    do { try plugin.receive(message) }
                    catch { log(String(describing: error)); exit(1) }
                }
            }
            exit(0)
        } catch {
            log(String(describing: error))
            exit(1)
        }
    }

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(125), leeway: .milliseconds(25))
    timer.setEventHandler {
        do { try plugin.tick() }
        catch { log(String(describing: error)); exit(1) }
    }
    timer.resume()
    withExtendedLifetime(timer) { dispatchMain() }
}

do { try run() }
catch { log("Could not start DynamicLake plugin: \(error)"); exit(1) }
