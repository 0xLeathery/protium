// Protium.app: the window a player uses to set up Steam Play for Protium, check it, repair it
// and take it out again. Everything it does is done by the app's copy of macos/steamplay, run
// with the app's own Python; this file is the window and the few steps only an app can take
// (asking for an administrator's password, asking Steam to quit, refusing to run from a disk
// image or from a translocated copy).
//
// Built by macos/make-release.sh: swiftc -swift-version 5 -target arm64-apple-macos27.0.
// Copyright (C) 2026 Ethan Hurst. GPL-3.0-or-later, see LICENSE.protium.

import AppKit
import Darwin
import UserNotifications

let steamBundleID = "com.valvesoftware.steam"
let toolsDir = "/usr/local/share/steam/compatibilitytools.d"

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let output = NSTextView()
    var buttons: [NSButton] = []
    var busy = false
    /// "Protium 0.3.0 is available", Update and Later; hidden until a newer release is found
    let updateRow = NSStackView()
    let updateLabel = NSTextField(labelWithString: "")
    var updateButton: NSButton!
    var updatePage: URL?
    var updateVersion = ""
    var updateHasImage = false
    var tellCheckbox: NSButton!
    var hiresCheckbox: NSButton!
    var hudCheckbox: NSButton!
    var notifyButton: NSButton!
    /// what steamplay printed since the last command started, for the lines the app reads
    var lastOutput = ""
    var steamplayHome: String {
        ProcessInfo.processInfo.environment["STEAMPLAY_HOME"]
            ?? NSHomeDirectory() + "/Library/Application Support/SteamPlay"
    }
    var ownVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
    var steamplay: String { contents.appendingPathComponent("Resources/steamplay/steamplay").path }
    var python: String { contents.appendingPathComponent("SharedSupport/python/bin/python3").path }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Protium"
        window.center()

        let title = NSTextField(labelWithString: "Play Windows games from your Steam library on this Mac.")
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        output.isEditable = false
        output.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        output.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        output.autoresizingMask = [.width]
        output.isVerticallyResizable = true

        let row = NSStackView()
        row.orientation = .horizontal
        for (label, action) in [("Set up Steam", #selector(setUp)), ("Repair", #selector(setUp)),
                                ("Status", #selector(status)), ("Uninstall", #selector(uninstall)),
                                ("Diagnostics", #selector(diagnose))] {
            let button = NSButton(title: label, target: self, action: action)
            buttons.append(button)
            row.addArrangedSubview(button)
        }
        buttons[0].keyEquivalent = "\r"

        updateLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        updateRow.orientation = .horizontal
        updateRow.addArrangedSubview(updateLabel)
        updateButton = NSButton(title: "Update", target: self, action: #selector(update))
        updateRow.addArrangedSubview(updateButton)
        updateRow.addArrangedSubview(NSButton(title: "Later", target: self, action: #selector(updateLater)))
        updateRow.isHidden = true

        // the settings, on a row of their own below the buttons
        let options = NSStackView()
        options.orientation = .horizontal
        hiresCheckbox = NSButton(checkboxWithTitle: "Use the screen's full resolution in games", target: self, action: #selector(hiresChanged))
        hiresCheckbox.state = .on
        hiresCheckbox.toolTip = "On a Retina or 4K screen, games can use every pixel. Turn this off if games run too slowly; you can also pick a lower resolution in a game's own settings."
        options.addArrangedSubview(hiresCheckbox)
        hudCheckbox = NSButton(checkboxWithTitle: "Show frame rate in games", target: self, action: #selector(hudChanged))
        hudCheckbox.toolTip = "Draws macOS's performance display over every game: frames per second and frame times."
        options.addArrangedSubview(hudCheckbox)
        tellCheckbox = NSButton(checkboxWithTitle: "Tell me about new versions", target: self, action: #selector(tellChanged))
        tellCheckbox.state = .on
        options.addArrangedSubview(tellCheckbox)
        notifyButton = NSButton(title: "Allow notifications…", target: self, action: #selector(allowNotifications))
        options.addArrangedSubview(notifyButton)
        showNotificationState()
        askSteamplay(["hires"]) { text in self.hiresCheckbox.state = text.contains("in games: off") ? .off : .on }
        askSteamplay(["hud"]) { text in self.hudCheckbox.state = text.contains("in games: on") ? .on : .off }

        let stack = NSStackView(views: [title, updateRow, scroll, row, options])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.title = "Protium \(ownVersion)"
        afterUpdate()
        // the status first, then the newer version: what it changes is then the last thing in
        // the window, not scrolled away by the status
        setBusy(true)
        runSteamplay(["status"]) { _ in
            self.setBusy(false)
            self.checkForUpdate()
        }
    }

    // MARK: a newer version

    /// Runs steamplay quietly and gives its output, on the main thread.
    func askSteamplay(_ args: [String], then done: @escaping (String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", steamplay] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { done(text) }
        }
        do { try process.run() } catch { done("") }
    }

    /// Asks, through steamplay, whether GitHub has a newer release of Protium than this one. If
    /// so it shows the row above the output and what the newer versions change. Says nothing
    /// when there is none, no network, or the player turned the asking off.
    func checkForUpdate() {
        askSteamplay(["version", "--check"]) { text in
            var fields: [String: [String]] = [:]
            var changes: [String] = []
            var inChanges = false
            for line in text.components(separatedBy: "\n") {
                if line == "changes-begin" { inChanges = true; continue }
                if line == "changes-end" { inChanges = false; continue }
                if inChanges { changes.append(line); continue }
                let words = line.split(separator: " ").map(String.init)
                if let key = words.first { fields[key] = Array(words.dropFirst()) }
            }
            self.tellCheckbox.state = fields["check"]?.first == "off" ? .off : .on
            guard fields["newer"]?.first == "yes", let latest = fields["latest"], latest.count == 2,
                  let page = URL(string: latest[1]), page.scheme == "https", page.host == "github.com" else {
                self.updateRow.isHidden = true
                return
            }
            self.updatePage = page
            self.updateVersion = latest[0]
            self.updateHasImage = fields["download"] != nil
            self.updateButton.title = self.updateHasImage ? "Update" : "Open its page"
            self.updateLabel.stringValue = "Protium \(latest[0]) is available. You have \(self.ownVersion)."
            if self.updateRow.isHidden {
                self.say("\nWhat's new:\n\n" + changes.joined(separator: "\n") + "\n")
            }
            self.updateRow.isHidden = false
        }
    }

    @objc func updateLater() { updateRow.isHidden = true }

    // MARK: macOS notifications

    /// The button says what macOS allows: it asks while that is undecided, and is done once the
    /// player allowed notifications.
    func showNotificationState() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.notifyButton.title = "Notifications allowed"
                    self.notifyButton.isEnabled = false
                case .denied:
                    self.notifyButton.title = "Notifications are off…"
                default:
                    self.notifyButton.title = "Allow notifications…"
                }
            }
        }
    }

    /// Asked from the open window, where macOS shows its question. A game's start never asks.
    @objc func allowNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .denied {
                DispatchQueue.main.async {
                    _ = self.alert("Notifications are off for Protium",
                                   "Turn them on in System Settings > Notifications > Protium to be told there when a new version is available. The banner shown in games works either way.")
                }
                return
            }
            center.requestAuthorization(options: [.alert]) { _, error in
                DispatchQueue.main.async {
                    if let error = error { self.say("\nmacOS couldn't ask for permission to send notifications: \(error.localizedDescription)\n") }
                    self.showNotificationState()
                }
            }
        }
    }

    /// Checked is "automatic": full resolution when the main screen is a HiDPI one.
    @objc func hiresChanged() {
        askSteamplay(["hires", hiresCheckbox.state == .on ? "auto" : "off"]) { text in
            self.say("\n" + text)
        }
    }

    @objc func hudChanged() {
        askSteamplay(["hud", hudCheckbox.state == .on ? "on" : "off"]) { text in
            self.say("\n" + text)
        }
    }

    @objc func tellChanged() {
        askSteamplay(["updates", tellCheckbox.state == .on ? "on" : "off"]) { _ in self.checkForUpdate() }
    }

    /// Downloads the newer release, has steamplay test it, and hands over to the helper that
    /// puts it in this app's place once this app has quit. Every refusal is shown as it is.
    @objc func update() {
        guard !busy else { return }
        guard updateHasImage else {
            if let page = updatePage { NSWorkspace.shared.open(page) }
            return
        }
        guard inStablePlace() else { return }
        setBusy(true)
        runSteamplay(["update", "--fetch"]) { code in
            let words = self.lastOutput.components(separatedBy: "\n").last(where: { $0.hasPrefix("ok fetched ") })?
                .dropFirst("ok fetched ".count).split(separator: " ").map(String.init) ?? []
            guard code == 0, words.count >= 2, let version = words.last else {
                self.setBusy(false)
                return
            }
            let image = words.dropLast().joined(separator: " ")
            self.runSteamplay(["update", "--install", image, version, String(ProcessInfo.processInfo.processIdentifier)]) { code in
                guard code == 0 else {
                    self.setBusy(false)
                    return
                }
                self.say("\nProtium will now quit and reopen as version \(version).\n")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
            }
        }
    }

    /// The first start after an update: tells the helper that the new version runs (it puts the
    /// old one back otherwise), brings Steam's tools up to date, and says what is new, from the
    /// changelog the app carries.
    func afterUpdate() {
        let path = steamplayHome + "/update-pending.json"
        guard let data = FileManager.default.contents(atPath: path),
              var pending = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return }
        if let failed = pending["failed"] {
            try? FileManager.default.removeItem(atPath: path)
            _ = alert("Protium wasn't updated", failed)
            return
        }
        guard pending["new"] == ownVersion, pending["started"] == nil else {
            try? FileManager.default.removeItem(atPath: path)     // an update that is over
            return
        }
        pending["started"] = ownVersion
        if let out = try? JSONSerialization.data(withJSONObject: pending) {
            try? out.write(to: URL(fileURLWithPath: path))
        }
        say("Updated from \(pending["old"] ?? "an older version") to \(ownVersion).\n\n" + whatsNew(since: pending["old"] ?? "") + "\n")
        askSteamplay(["tools", "--refresh"]) { text in if !text.isEmpty { self.say(text) } }
    }

    /// The sections of the bundled CHANGELOG.md for the versions after `old`, up to this one.
    func whatsNew(since old: String) -> String {
        let file = contents.appendingPathComponent("Resources/steamplay/CHANGELOG.md").path
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return "" }
        func key(_ v: String) -> [Int] { v.split(separator: ".").prefix(3).map { Int($0) ?? 0 } }
        func newer(_ a: String, than b: String) -> Bool { key(a).lexicographicallyPrecedes(key(b)) == false && key(a) != key(b) }
        var out: [String] = []
        var keep = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## [") {
                let version = String(line.dropFirst(4).prefix(while: { $0 != "]" }))
                keep = version.first?.isNumber == true && newer(version, than: old) && !newer(version, than: ownVersion)
                if keep { out.append("What's new in \(version)") }
                continue
            }
            if line.hasPrefix("[") && line.contains("]: ") { keep = false }
            if keep { out.append(line.hasPrefix("### ") ? String(line.dropFirst(4)) + ":" : line) }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: output

    func say(_ text: String) {
        lastOutput += text
        output.textStorage?.append(NSAttributedString(string: text, attributes: [
            .font: output.font!, .foregroundColor: NSColor.textColor]))
        output.scrollToEndOfDocument(nil)
    }

    /// What the window does not show (which command ran, and with what status), kept in
    /// ~/Library/Logs/SteamPlay/app.log for whoever looks into a problem.
    func note(_ line: String) {
        let folder = NSHomeDirectory() + "/Library/Logs/SteamPlay"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: folder + "/app.log") {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: folder + "/app.log", contents: data)
        }
    }

    func setBusy(_ on: Bool) {
        busy = on
        buttons.forEach { $0.isEnabled = !on }
    }

    /// Runs the app's steamplay with its own Python; the output goes to the window as it comes.
    /// The completion gets the exit status, on the main thread.
    func runSteamplay(_ args: [String], then done: @escaping (Int32) -> Void) {
        say("\n")
        note("$ steamplay \(args.joined(separator: " "))")
        lastOutput = ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", steamplay] + args     // -B: nothing is written into the app
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.say(text) }
        }
        process.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                if !rest.isEmpty, let text = String(data: rest, encoding: .utf8) { self.say(text) }
                done(p.terminationStatus)
            }
        }
        do {
            try process.run()
        } catch {
            say("Protium couldn't run its helper: \(error.localizedDescription)\n")
            done(-1)
        }
    }

    /// Runs the steps one after another and stops at the first that fails.
    func runSteps(_ steps: [[String]], then done: @escaping (Bool) -> Void) {
        guard let first = steps.first else { return done(true) }
        runSteamplay(first) { code in
            if code != 0 {
                self.note("stopped: steamplay \(first.joined(separator: " ")) failed (\(code))")
                return done(false)
            }
            self.runSteps(Array(steps.dropFirst()), then: done)
        }
    }

    // MARK: checks only an app can make

    func alert(_ message: String, _ info: String, buttons labels: [String] = ["OK"]) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        labels.forEach { a.addButton(withTitle: $0) }
        return a.runModal()
    }

    /// The tools Steam starts hold this app's path, so it has to stay where it is: not on the disk
    /// image it came on, and not in the temporary copy macOS runs a downloaded app from.
    func inStablePlace() -> Bool {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            _ = alert("Move Protium to Applications first",
                      "Drag Protium into the Applications folder and open it from there. Steam starts games through Protium, so the app has to stay in one place.")
            return false
        }
        return true
    }

    /// Steam reads its tools and settings when it starts and rewrites them when it quits.
    func steamQuit() -> Bool {
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: steamBundleID)
        if running.isEmpty { return true }
        if alert("Quit Steam first", "Steam needs to be closed while Protium changes its settings.",
                 buttons: ["Quit Steam", "Cancel"]) != .alertFirstButtonReturn { return false }
        running.forEach { $0.terminate() }
        for _ in 0..<60 {
            running = NSRunningApplication.runningApplications(withBundleIdentifier: steamBundleID)
            if running.allSatisfy({ $0.isTerminated }) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        _ = alert("Steam is still running", "Quit Steam, then try again.")
        return false
    }

    /// Steam looks for tools in a folder outside the user's home, made once with an
    /// administrator's password and then given to this user.
    func toolsDirReady() -> Bool {
        if FileManager.default.isWritableFile(atPath: toolsDir) { return true }
        say("Protium needs to create a folder for Steam (\(toolsDir)), and macOS will ask for your password.\n")
        let source = """
            do shell script "mkdir -p \(toolsDir) && chown " & quoted form of "\(NSUserName())" & " \(toolsDir)" ¬
                with prompt "Protium needs to create the folder where Steam looks for compatibility tools." with administrator privileges
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            say("The folder wasn't created: \(error[NSAppleScript.errorMessage] ?? "cancelled")\n")
            return false
        }
        return FileManager.default.isWritableFile(atPath: toolsDir)
    }

    // MARK: actions

    @objc func setUp() {
        guard !busy, inStablePlace(), steamQuit() else { return }
        setBusy(true)
        let finish = { (ok: Bool) in
            self.setBusy(false)
            self.say(ok ? "\nDone. Open Steam and your Windows games can be installed and played from your library.\n"
                        : "\nSetup didn't finish. Fix the problem shown above and press Set up Steam again, or press Diagnostics to save a report.\n")
            // asked here, with Protium in front, and never when a game starts
            if ok { self.allowNotifications() }
        }
        // whether this Steam can be set up at all comes first: nobody is asked for an
        // administrator's password on a Mac where setting up cannot work
        runSteps([["setup", "--check"]]) { ready in
            guard ready, self.toolsDirReady() else { return finish(false) }
            self.runSteps([["steamclient"], ["setup"], ["guard", "install"], ["status"]], then: finish)
        }
    }

    @objc func status() {
        guard !busy else { return }
        setBusy(true)
        runSteamplay(["status"]) { _ in self.setBusy(false) }
    }

    /// Writes the diagnostics file and shows it in the Finder, for the player to attach to an issue.
    @objc func diagnose() {
        guard !busy else { return }
        setBusy(true)
        runSteamplay(["diagnose"]) { _ in
            self.setBusy(false)
            let mark = "diagnostics saved: "
            if let line = self.lastOutput.components(separatedBy: "\n").last(where: { $0.hasPrefix(mark) }) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: String(line.dropFirst(mark.count)))])
            }
        }
    }

    @objc func uninstall() {
        guard !busy else { return }
        if alert("Remove Protium from Steam?",
                 "Steam will go back to showing only Mac games and will delete the Windows games it installed through Protium. Cloud saves are kept, and local save data stays in steamapps/compatdata.",
                 buttons: ["Uninstall", "Cancel"]) != .alertFirstButtonReturn { return }
        guard steamQuit() else { return }
        setBusy(true)
        runSteps([["uninstall"]]) { ok in
            self.setBusy(false)
            self.say(ok ? "\nProtium has been removed from Steam. You can delete Protium.app now.\n"
                        : "\nUninstall didn't finish. Fix the problem shown above and try again, or press Diagnostics to save a report.\n")
        }
    }
}

// "Protium --game-notice <version> <what is new>": tells the player in the game they just started
// that a newer Protium is out. steamplay starts it when a game starts. It is an application
// without a Dock icon that never becomes the active one: it waits for a game window of this
// Protium to be on screen, shows a small banner at the top of that screen for a few seconds,
// which the mouse goes straight through, posts a macOS notification as well if the player
// allowed those, and ends.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--game-notice" {
    let version = CommandLine.arguments[2]
    let line = CommandLine.arguments.dropFirst(3).joined(separator: " ")
    // PROTIUM_RUNTIME and PROTIUM_NOTICE_WAIT are for macos/tests/check-notice.sh: another Wine
    // than the app's own, and fewer than 180 seconds of waiting for a game's window
    let runtime = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROTIUM_RUNTIME"]
        ?? Bundle.main.bundleURL.appendingPathComponent("Contents/SharedSupport/runtime").path).resolvingSymlinksInPath().path
    let longestWait = Int(ProcessInfo.processInfo.environment["PROTIUM_NOTICE_WAIT"] ?? "") ?? 180
    let notice = NSApplication.shared
    notice.setActivationPolicy(.accessory)

    /// The screen rectangle (origin top left, as Quartz counts) of a game's window: one of at
    /// least 640 by 480 that belongs to a program of this Protium's Wine.
    func gameWindow() -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in list {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.width >= 640, bounds.height >= 480 else { continue }
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            if String(cString: buffer).hasPrefix(runtime + "/") { return bounds }
        }
        return nil
    }

    func show(over game: CGRect) {
        // Quartz counts from the top of the main screen, AppKit from its bottom
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let centre = NSPoint(x: game.midX, y: mainHeight - game.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 520, height: 88)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height - 56,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)   // above a fullscreen game
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true     // a click here is the game's
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = "Protium notice"

        let back = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        back.material = .hudWindow
        back.state = .active
        back.blendingMode = .behindWindow
        back.wantsLayer = true
        back.layer?.cornerRadius = 18
        back.layer?.masksToBounds = true
        let title = NSTextField(labelWithString: "Protium \(version) is available")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        let what = NSTextField(labelWithString: line)
        what.font = NSFont.systemFont(ofSize: 12)
        what.textColor = NSColor.white.withAlphaComponent(0.85)
        what.lineBreakMode = .byTruncatingTail
        // a long line is cut short; it must not make the panel wider
        what.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let how = NSTextField(labelWithString: "Open Protium to update.")
        how.font = NSFont.systemFont(ofSize: 12)
        how.textColor = NSColor.white.withAlphaComponent(0.6)
        let text = NSStackView(views: [title, what, how])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        if let icon = NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Protium.icns")) {
            let image = NSImageView(image: icon)
            image.widthAnchor.constraint(equalToConstant: 56).isActive = true
            image.heightAnchor.constraint(equalToConstant: 56).isActive = true
            row.addArrangedSubview(image)
        }
        row.addArrangedSubview(text)
        row.frame = back.bounds
        row.autoresizingMask = [.width, .height]
        back.addSubview(row)
        panel.contentView = back
        panel.setFrame(frame, display: false)       // the size it was given, whatever its contents wish

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.4; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.4) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.6; panel.animator().alphaValue = 0 },
                                                 completionHandler: { exit(0) })
        }
        // the same, for Notification Centre, if the player allowed notifications (the binary
        // outside an app, as the checks run it, has no Notification Centre to talk to)
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Protium \(version) is available"
            content.body = line.isEmpty ? "Open Protium to update." : line
            center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)) { _ in }
        }
    }

    var waited = 0
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
        waited += 1
        if let game = gameWindow() {
            timer.invalidate()
            // not over a splash screen that is gone a moment later
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { show(over: gameWindow() ?? game) }
        } else if waited >= longestWait {
            exit(0)     // no game came
        }
    }
    notice.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Quit, and Copy and Select All for the window's text
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Protium", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
let editMenuItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
mainMenu.addItem(appMenuItem)
mainMenu.addItem(editMenuItem)
app.mainMenu = mainMenu
app.setActivationPolicy(.regular)
app.run()
