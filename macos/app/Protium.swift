// Protium.app: the window a player uses to set up Steam Play for Protium, check it, repair it
// and take it out again. Everything it does is done by the app's copy of macos/steamplay, run
// with the app's own Python; this file is the window and the few steps only an app can take
// (asking for an administrator's password, asking Steam to quit, refusing to run from a disk
// image or from a translocated copy).
//
// Built by macos/make-release.sh: swiftc -swift-version 5 -target arm64-apple-macos27.0.
// Copyright (C) 2026 Ethan Hurst. GPL-3.0-or-later, see LICENSE.protium.

import AppKit
import UserNotifications

let steamBundleID = "com.valvesoftware.steam"
let toolsDir = "/usr/local/share/steam/compatibilitytools.d"

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let output = NSTextView()
    var buttons: [NSButton] = []
    var busy = false
    /// "Protium 0.3.0 is out", Update and Later; hidden until a newer release is found
    let updateRow = NSStackView()
    let updateLabel = NSTextField(labelWithString: "")
    var updateButton: NSButton!
    var updatePage: URL?
    var updateVersion = ""
    var updateHasImage = false
    var tellCheckbox: NSButton!
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

        let title = NSTextField(labelWithString: "Steam Play for this Mac: Windows games from your Steam library.")
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
                                ("Status", #selector(status)), ("Uninstall", #selector(uninstall))] {
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

        tellCheckbox = NSButton(checkboxWithTitle: "Tell me about new versions", target: self, action: #selector(tellChanged))
        tellCheckbox.state = .on
        row.addArrangedSubview(tellCheckbox)

        let stack = NSStackView(views: [title, updateRow, scroll, row])
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
        status()
        checkForUpdate()
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
            self.updateLabel.stringValue = "Protium \(latest[0]) is out. This is \(self.ownVersion)."
            if self.updateRow.isHidden {
                self.say("\nNew since this version:\n\n" + changes.joined(separator: "\n") + "\n")
            }
            self.updateRow.isHidden = false
        }
    }

    @objc func updateLater() { updateRow.isHidden = true }

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
                self.say("\nProtium quits now and comes back as \(version).\n")
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
            _ = alert("Protium was not updated", failed)
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

    func setBusy(_ on: Bool) {
        busy = on
        buttons.forEach { $0.isEnabled = !on }
    }

    /// Runs the app's steamplay with its own Python; the output goes to the window as it comes.
    /// The completion gets the exit status, on the main thread.
    func runSteamplay(_ args: [String], then done: @escaping (Int32) -> Void) {
        say("\n$ steamplay \(args.joined(separator: " "))\n")
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
            say("could not start steamplay: \(error.localizedDescription)\n")
            done(-1)
        }
    }

    /// Runs the steps one after another and stops at the first that fails.
    func runSteps(_ steps: [[String]], then done: @escaping (Bool) -> Void) {
        guard let first = steps.first else { return done(true) }
        runSteamplay(first) { code in
            if code != 0 {
                self.say("stopped: steamplay \(first.joined(separator: " ")) failed (\(code))\n")
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
                      "Drag Protium into the Applications folder and open it from there. Steam will start games through this copy of Protium, so it has to stay in one place.")
            return false
        }
        return true
    }

    /// Steam reads its tools and settings when it starts and rewrites them when it quits.
    func steamQuit() -> Bool {
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: steamBundleID)
        if running.isEmpty { return true }
        if alert("Quit Steam first", "Protium changes Steam's settings, which Steam only reads when it starts.",
                 buttons: ["Quit Steam", "Cancel"]) != .alertFirstButtonReturn { return false }
        running.forEach { $0.terminate() }
        for _ in 0..<60 {
            running = NSRunningApplication.runningApplications(withBundleIdentifier: steamBundleID)
            if running.allSatisfy({ $0.isTerminated }) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        _ = alert("Steam is still running", "Quit Steam yourself, then try again.")
        return false
    }

    /// Steam looks for tools in a folder outside the user's home, made once with an
    /// administrator's password and then given to this user.
    func toolsDirReady() -> Bool {
        if FileManager.default.isWritableFile(atPath: toolsDir) { return true }
        say("making \(toolsDir) (macOS asks for an administrator's password)\n")
        let source = """
            do shell script "mkdir -p \(toolsDir) && chown " & quoted form of "\(NSUserName())" & " \(toolsDir)" ¬
                with prompt "Protium makes the folder Steam finds its compatibility tools in." with administrator privileges
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            say("not made: \(error[NSAppleScript.errorMessage] ?? "cancelled")\n")
            return false
        }
        return FileManager.default.isWritableFile(atPath: toolsDir)
    }

    // MARK: actions

    @objc func setUp() {
        guard !busy, inStablePlace(), steamQuit(), toolsDirReady() else { return }
        setBusy(true)
        runSteps([["steamclient"], ["setup"], ["guard", "install"], ["status"]]) { ok in
            self.setBusy(false)
            self.say(ok ? "\nSet up. Start Steam: Windows games now install and play from your library.\n"
                        : "\nSetting up did not finish; the lines above say why.\n")
            // asked here, with Protium in front, and never when a game starts
            if ok { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
        }
    }

    @objc func status() {
        guard !busy else { return }
        setBusy(true)
        runSteamplay(["status"]) { _ in self.setBusy(false) }
    }

    @objc func uninstall() {
        guard !busy else { return }
        if alert("Take Protium out of Steam?",
                 "Steam then takes this Mac for a Mac again and removes the Windows builds of the games it installed through Protium. Their saves in Steam Cloud and their folders in steamapps/compatdata stay.",
                 buttons: ["Uninstall", "Cancel"]) != .alertFirstButtonReturn { return }
        guard steamQuit() else { return }
        setBusy(true)
        runSteps([["uninstall"]]) { ok in
            self.setBusy(false)
            if ok { self.say("\nProtium is out of Steam. You can now delete Protium.app.\n") }
        }
    }
}

// "Protium --notify <version> <what is new>": one notification that a newer version is out, for
// steamplay when a game starts. No window; nothing happens unless the player allowed
// notifications. Clicking it opens Protium, which shows the update as usual.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--notify" {
    let center = UNUserNotificationCenter.current()
    let done = DispatchSemaphore(value: 0)
    center.getNotificationSettings { settings in
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            done.signal()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Protium \(CommandLine.arguments[2]) is out"
        content.body = CommandLine.arguments.dropFirst(3).joined(separator: " ")
        center.add(UNNotificationRequest(identifier: "update-\(CommandLine.arguments[2])", content: content, trigger: nil)) { _ in
            done.signal()
        }
    }
    _ = done.wait(timeout: .now() + 10)
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
