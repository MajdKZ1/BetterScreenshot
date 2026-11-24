import AppKit
import SwiftUI

@available(macOS 26.0, *)
private struct ToastView: View {
    static let cardSize = CGSize(width: 320, height: 92)
    static let closeOverhang: CGFloat = 12

    let thumbnail: NSImage?
    let reveal: () -> Void
    let dismiss: () -> Void
    @ObservedObject var state: ToastState

    var body: some View {
        ZStack(alignment: .topLeading) {
            banner
                .padding([.top, .leading], Self.closeOverhang)

            Button(action: dismiss) {
                Text("×")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
            .help("Dismiss notification")
            .opacity(state.hovering ? 1 : 0)
            .allowsHitTesting(state.hovering)
            .accessibilityHidden(!state.hovering)
        }
    }

    private var banner: some View {
        ZStack {
            Color.clear
                .contentShape(RoundedRectangle(cornerRadius: 22))
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screenshot saved")
                            .font(.headline)
                        Text("Copied to clipboard")
                            .font(.body)
                            .foregroundStyle(.primary.opacity(0.8))
                    }
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)

                    if state.hovering {
                        Button(action: reveal) {
                            Text("Open in Finder")
                                .font(.body)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary, in: .capsule)
                        .contentShape(.capsule)
                    }
                }

                Spacer(minLength: 0)
                thumbnailView
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
    }

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: "camera.viewfinder").font(.title3)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private final class ToastState: ObservableObject {
    @Published var hovering = false
}

private final class ToastHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@available(macOS 26.0, *)
private final class ToastController {
    private let panel: NSPanel
    private let state = ToastState()
    private let stayTime: TimeInterval
    private let fadeInTime: TimeInterval
    private let fadeOutTime: TimeInterval
    private let parentProcess = getppid()
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var hoverTimer: Timer?
    private var dismissTimer: Timer?

    init(path: String, anchor: CGPoint, stayTime: TimeInterval, fadeInTime: TimeInterval,
         fadeOutTime: TimeInterval, slideDistance: CGFloat) {
        self.stayTime = stayTime
        self.fadeInTime = fadeInTime
        self.fadeOutTime = fadeOutTime

        let frame = CGRect(x: anchor.x - ToastView.cardSize.width - ToastView.closeOverhang,
                           y: anchor.y - ToastView.cardSize.height,
                           width: ToastView.cardSize.width + ToastView.closeOverhang,
                           height: ToastView.cardSize.height + ToastView.closeOverhang)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "BetterScreenshot notification"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = ToastHostingView(rootView: ToastView(
            thumbnail: NSImage(contentsOfFile: path), reveal: { [weak self] in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                self?.dismiss()
            }, dismiss: { [weak self] in self?.dismiss() }, state: state
        ))

        let animate = !reduceMotion && fadeInTime > 0
        if animate {
            panel.alphaValue = 0
            panel.setFrame(frame.offsetBy(dx: slideDistance, dy: 0), display: false)
        }
        panel.orderFrontRegardless()
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeInTime
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }

        scheduleDismiss(after: stayTime + (animate ? fadeInTime : 0))
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateHover()
        }
    }

    private func updateHover() {
        if getppid() != parentProcess { exit(EXIT_SUCCESS) }
        let hovering = panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        guard hovering != state.hovering else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { state.hovering = hovering }
        if hovering {
            dismissTimer?.invalidate()
        } else {
            scheduleDismiss(after: stayTime)
        }
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard let hoverTimer else { return }
        hoverTimer.invalidate()
        self.hoverTimer = nil
        dismissTimer?.invalidate()
        panel.ignoresMouseEvents = true
        guard !reduceMotion && fadeOutTime > 0 else { exit(EXIT_SUCCESS) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeOutTime
            panel.animator().alphaValue = 0
        } completionHandler: {
            exit(EXIT_SUCCESS)
        }
    }
}

let arguments = CommandLine.arguments
let app = NSApplication.shared
guard #available(macOS 26.0, *), arguments.count == 8,
      let right = Double(arguments[2]), let top = Double(arguments[3]),
      let stay = Double(arguments[4]), let fadeIn = Double(arguments[5]),
      let fadeOut = Double(arguments[6]), let slide = Double(arguments[7]),
      [right, top, stay, fadeIn, fadeOut, slide].allSatisfy(\.isFinite),
      let primaryScreen = NSScreen.screens.first else { exit(EXIT_FAILURE) }

app.setActivationPolicy(.accessory)
private let controller = ToastController(path: arguments[1],
                                         anchor: CGPoint(x: right, y: primaryScreen.frame.maxY - top),
                                         stayTime: max(0, stay), fadeInTime: max(0, fadeIn),
                                         fadeOutTime: max(0, fadeOut), slideDistance: slide)
withExtendedLifetime(controller) { app.run() }
