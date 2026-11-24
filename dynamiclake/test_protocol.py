#!/usr/bin/env python3
"""Exercise the packaged executable against a local DynamicLake protocol fixture."""
import base64
import contextlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import unittest
import zlib


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\x32\x54" * 16) * 16))
            + chunk(b"IEND", b""))


class ProtocolTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir="/tmp", prefix="bs-test-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.bridge = self.home / "Library/Application Support/BetterScreenshot"
        self.bridge.mkdir(parents=True)
        self.folder = self.home / "Custom shots é"
        self.state()
        self.executable = (Path(__file__).resolve().parents[1] / "build"
                           / "BetterScreenshot.dynamiclakeplugin/betterscreenshot-plugin")

    def state(self, **fields):
        temp = self.bridge / "state.tmp"
        temp.write_text(json.dumps({"folder": str(self.folder), **fields}))
        temp.replace(self.bridge / "dynamiclake.json")

    @contextlib.contextmanager
    def host(self, features):
        path = str(self.home / "host.sock")
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path)
            listener.listen()
            listener.settimeout(5)
            env = dict(os.environ, HOME=str(self.home), DYNAMICLAKE_JSON_SOCKET=path,
                       DYNAMICLAKE_PLUGIN_FEATURES=features)
            with subprocess.Popen([self.executable], env=env) as plugin:
                with contextlib.closing(listener.accept()[0]) as connection:
                    connection.settimeout(5)
                    yield connection
                self.assertEqual(plugin.wait(timeout=5), 0)
            Path(path).unlink()

    def read(self, connection, kind):
        def exact(count):
            data = b""
            while len(data) < count:
                part = connection.recv(count - len(data))
                self.assertTrue(part, "Unexpected socket EOF")
                data += part
            return data

        length = struct.unpack(">I", exact(4))[0]
        self.assertLessEqual(length, 64 * 1024)
        message = json.loads(exact(length))
        self.assertEqual(message["schemaVersion"], 1)
        self.assertEqual(message["type"], kind)
        return message

    def send(self, connection, kind, **fields):
        data = json.dumps(dict(schemaVersion=1, type=kind, **fields)).encode()
        connection.sendall(struct.pack(">I", len(data)) + data)

    def event(self, token, capture=None):
        self.state(capture=capture, token=token, deadline=time.time() + 1)

    def action(self, connection, action):
        self.send(connection, "action", activityID="screenshot", actionID=action)

    def assert_idle(self, connection, seconds=0.25):
        connection.settimeout(seconds)
        with self.assertRaises(socket.timeout):
            connection.recv(1)
        connection.settimeout(5)

    def test_repeated_capture_updates_one_compact_activity(self):
        self.folder.mkdir()
        names = [f"Screenshot_2026-11-24_12-00-0{i}.png" for i in range(2)]
        for name in names:
            (self.folder / name).write_bytes(png())

        with self.host("lakeLayout,presentSneakPeek,imageAssets") as connection:
            self.assert_idle(connection)
            for kind, name in zip(("create", "update"), names):
                self.event(name, name)
                message = self.read(connection, kind)
                self.assertEqual(message["activityID"], "screenshot")
                self.assertEqual(message.get("size"), "small" if kind == "create" else None)
                self.assertNotIn("presentSneakPeek", message)
                self.assertEqual(list(message["surfaces"]), ["compactLiveActivity"])
                compact = message["surfaces"]["compactLiveActivity"]
                self.assertEqual(list(compact), ["leftSlot"])
                thumb = compact["leftSlot"]
                self.assertEqual(thumb["actionID"], "recent")
                self.assertTrue(base64.b64decode(thumb["base64Data"]).startswith(b"\xff\xd8"))
                self.send(connection, "response", requestID=name, ok=True)

            ack = self.bridge / "dynamiclake-ack"
            for _ in range(50):
                if ack.exists() and len(ack.read_text().splitlines()) == 2:
                    break
                time.sleep(0.01)
            self.assertEqual(ack.read_text().splitlines(), names[::-1])
            self.assertEqual(self.read(connection, "dismiss")["activityID"], "screenshot")
            self.assert_idle(connection)

    def compact(self, connection, kind):
        message = self.read(connection, kind)
        self.assertNotIn("presentSneakPeek", message)
        self.assertEqual(list(message["surfaces"]), ["compactLiveActivity"])
        slots = message["surfaces"]["compactLiveActivity"]
        for image in slots.values():
            self.assertEqual(image["type"], "image")
            self.assertEqual(image["source"], "inlineData")
            self.assertTrue(image["actionID"].startswith("copy:") or image["actionID"] == "recent")
        return slots

    def test_recent_images_stay_compact_and_update_after_missing_file(self):
        self.folder.mkdir()
        older = self.folder / "Screenshot_2026-11-24_12-00-13.png"
        latest_base = self.folder / "Screenshot_2026-11-24_12-00-14.png"
        latest = self.folder / "Screenshot_2026-11-24_12-00-14_2.png"
        for file in (older, latest_base, latest):
            file.write_bytes(png())
        (self.folder / "unrelated.png").write_bytes(png())
        (self.folder / "Screenshot_2026-11-24_12-00-18.png").symlink_to(latest)

        with self.host("presentSneakPeek,lakeLayout") as connection:
            self.event("recent-1")
            slots = self.compact(connection, "create")
            self.assertEqual(set(slots), {"leftSlot", "rightSlot"})
            stale_action = slots["leftSlot"]["actionID"]
            latest.unlink()
            self.action(connection, stale_action)
            self.assertEqual(set(self.compact(connection, "update")), {"leftSlot", "rightSlot"})
            self.action(connection, stale_action)
            self.assert_idle(connection)

            self.event("capture", latest_base.name)
            slots = self.compact(connection, "update")
            self.assertEqual(list(slots), ["leftSlot"])
            self.assertEqual(slots["leftSlot"]["actionID"], "recent")
            self.action(connection, "recent")
            self.assertEqual(set(self.compact(connection, "update")), {"leftSlot", "rightSlot"})

        self.state()
        with self.host("") as connection:
            self.event("recent-2")
            self.assertEqual(set(self.compact(connection, "create")), {"leftSlot", "rightSlot"})

    def test_empty_cancel_and_single_image_on_older_host(self):
        name = "Screenshot_2026-11-24_12-00-14.png"
        with self.host("") as connection:
            self.event("cancelled", name)
            self.assert_idle(connection)
            self.event("recent-empty")
            self.assert_idle(connection)
            self.assertEqual((self.bridge / "dynamiclake-ack").read_text(), "recent-empty")

            self.folder.mkdir()
            (self.folder / name).write_bytes(png())
            self.event("capture", name)
            self.assertEqual(list(self.compact(connection, "create")), ["leftSlot"])
            self.action(connection, "recent")
            slots = self.compact(connection, "update")
            self.assertEqual(list(slots), ["leftSlot"])
            self.assertEqual(slots["leftSlot"]["title"], "Copy latest screenshot")

    def test_screenshot_directory_alias(self):
        self.folder.mkdir()
        (self.folder / "Screenshot_2026-11-24_12-00-14.png").write_bytes(png())
        alias = self.home / "Screenshot alias"
        alias.symlink_to(self.folder, target_is_directory=True)
        self.folder = alias
        with self.host("") as connection:
            self.event("recent-alias")
            self.assertEqual(list(self.compact(connection, "create")), ["leftSlot"])

    def lake_action(self, connection, action):
        self.send(connection, "action", activityID="lake", surface="lake", actionID=action)

    def full_rows(self, lake):
        rows = [row for row in lake["content"] if "contextMenu" in row]
        for item in lake.get("bottom", []):
            if item["type"] == "scroll":
                rows.extend(item["children"])
        return rows

    def test_history_opens_minimized_and_expands_to_paginated_saved_screenshots(self):
        self.folder.mkdir()
        for i in range(17):
            path = self.folder / f"Screenshot_2026-11-24_12-00-{i:02}.png"
            path.write_bytes(png())

        with self.host("lake,lakeLayout,imageAssets") as connection:
            lake = self.read(connection, "lake")["lake"]
            self.assertTrue(lake["hideHeader"])
            self.assertNotIn("bottom", lake)
            self.assertEqual(len(self.full_rows(lake)), 2)
            self.assertEqual(lake["content"][-1]["children"][-1]["title"], "Expand")
            self.assertEqual(lake["glance"]["content"][-1]["children"][-1]["actionID"], "history:expand")

            self.lake_action(connection, "history:expand")
            lake = self.read(connection, "lake")["lake"]
            rows = self.full_rows(lake)
            glance_rows = lake["glance"]["content"][0]["children"]
            self.assertEqual(len(glance_rows), len(rows))
            self.assertEqual(glance_rows[0]["children"][1]["text"], "11/24")
            self.assertEqual(glance_rows[0]["contextMenu"], rows[0]["contextMenu"])
            self.assertEqual(len(rows), 12)
            self.assertEqual(rows[0]["children"][1]["text"], "2026-11-24 12:00:16")
            self.assertTrue(rows[0]["children"][0]["children"][0]["actionID"].startswith("copy-image:"))
            self.assertEqual(rows[0]["contextMenu"][1]["title"], "Reveal in Finder")
            self.assertEqual(lake["bottom"][-1]["children"][-1]["title"], "Collapse")

            self.lake_action(connection, "page:older")
            rows = self.full_rows(self.read(connection, "lake")["lake"])
            self.assertEqual(len(rows), 5)
            self.assertEqual(rows[0]["children"][1]["text"], "2026-11-24 12:00:04")

            (self.folder / "Screenshot_2026-11-24_12-00-04.png").unlink()
            self.lake_action(connection, rows[0]["children"][0]["children"][0]["actionID"])
            rows = self.full_rows(self.read(connection, "lake")["lake"])
            self.assertEqual(len(rows), 4)
            self.assertEqual(rows[0]["children"][1]["text"], "2026-11-24 12:00:03")

            self.lake_action(connection, "history:collapse")
            lake = self.read(connection, "lake")["lake"]
            self.assertNotIn("bottom", lake)
            self.assertEqual(self.full_rows(lake)[0]["children"][1]["text"], "2026-11-24 12:00:16")

            self.lake_action(connection, "history:expand")
            self.assertIn("bottom", self.read(connection, "lake")["lake"])
            self.send(connection, "lakeClosed")
            self.assertNotIn("bottom", self.read(connection, "lake")["lake"])
            self.send(connection, "lakeOpened", trigger="glance")
            self.assertNotIn("bottom", self.read(connection, "lake")["lake"])

            self.event("capture-open-lake", "Screenshot_2026-11-24_12-00-16.png")
            create = self.read(connection, "create")
            self.assertEqual(list(create["surfaces"]), ["compactLiveActivity"])
            self.assertEqual(list(create["surfaces"]["compactLiveActivity"]), ["leftSlot"])
            self.read(connection, "lake")

    def test_clear_preserves_originals_and_persists_across_relaunch(self):
        self.folder.mkdir()
        earliest = self.folder / "Screenshot_2026-11-24_12-00-01.png"
        earliest.write_bytes(png())
        features = "lake,lakeLayout,imageAssets"

        with self.host(features) as connection:
            self.read(connection, "lake")
            self.lake_action(connection, "history:expand")
            lake = self.read(connection, "lake")["lake"]
            for footer, title in ((lake["bottom"][-1], "Clear History"), (lake["glance"]["content"][-1], "Clear")):
                clear = footer["children"][0]
                self.assertEqual(clear["title"], title)
                self.assertEqual(clear["actionID"], "history:clear")
            self.send(connection, "action", activityID="lake", surface="lake", actionID="history:clear")
            lake = self.read(connection, "lake")["lake"]
            self.assertEqual(lake["content"][0]["text"], "History cleared")
            self.assertEqual(lake["glance"]["content"], lake["content"])
            self.assertEqual(earliest.read_bytes(), png())

        with self.host(features) as connection:
            self.assertEqual(self.read(connection, "lake")["lake"]["content"][0]["text"], "History cleared")
            self.event("recent-after-clear")
            self.assert_idle(connection)
            self.assertIn("recent-after-clear", (self.bridge / "dynamiclake-ack").read_text().splitlines())

            self.send(connection, "lakeOpened", trigger="glance")
            self.read(connection, "lake")
            new = self.folder / "Screenshot_2026-11-24_12-00-02.png"
            new.write_bytes(png())
            self.event("capture-after-clear", new.name)
            self.compact(connection, "create")
            rows = self.full_rows(self.read(connection, "lake")["lake"])
            self.assertEqual([row["children"][1]["text"] for row in rows], ["2026-11-24 12:00:02"])

        self.state()
        with self.host(features) as connection:
            rows = self.full_rows(self.read(connection, "lake")["lake"])
            self.assertEqual([row["children"][1]["text"] for row in rows], ["2026-11-24 12:00:02"])


if __name__ == "__main__":
    unittest.main()
