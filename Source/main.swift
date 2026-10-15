import AppKit
import CoreGraphics
import ServiceManagement

struct Position: Codable {
    let uuid: String
    let x: Int32
    let y: Int32
}

enum DisplayFailure: LocalizedError {
    case system(String, CGError)
    case insufficientDisplays
    var errorDescription: String? {
        switch self {
        case let .system(operation, code): return "\(operation) failed (macOS error \(code.rawValue))."
        case .insufficientDisplays: return "Connect at least two displays to toggle mirroring."
        }
    }
}

func checked(_ result: CGError, _ operation: String) throws {
    if result != .success { throw DisplayFailure.system(operation, result) }
}

func onlineDisplays() throws -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    try checked(CGGetOnlineDisplayList(0, nil, &count), "Reading displays")
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    try checked(CGGetOnlineDisplayList(count, &displays, &count), "Reading displays")
    return Array(displays.prefix(Int(count)))
}

func identifier(_ display: CGDirectDisplayID) -> String {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else {
        return "display-\(display)"
    }
    return CFUUIDCreateString(nil, uuid) as String
}

func mirrored(_ displays: [CGDirectDisplayID]) -> Bool {
    displays.contains { CGDisplayIsInMirrorSet($0) != 0 }
}

// Reuse a saved layout only when the exact same monitors are connected.
func canRestore(_ saved: [Position], identifiers: [String]) -> Bool {
    saved.count == identifiers.count && Set(saved.map(\.uuid)) == Set(identifiers)
}

final class MirrorController {
    private let layoutKey = "extendedDisplayPositions"
    private(set) var busy = false

    func toggle() throws {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let displays = try onlineDisplays()
        guard displays.count >= 2 else { throw DisplayFailure.insufficientDisplays }
        let extending = mirrored(displays)
        let main = CGMainDisplayID()
        let positions = displays.map { display in
            let bounds = CGDisplayBounds(display)
            return Position(uuid: identifier(display), x: Int32(bounds.minX), y: Int32(bounds.minY))
        }
        let saved = UserDefaults.standard.data(forKey: layoutKey)
            .flatMap { try? JSONDecoder().decode([Position].self, from: $0) } ?? []
        var config: CGDisplayConfigRef?
        try checked(CGBeginDisplayConfiguration(&config), "Starting display change")
        var committed = false
        defer { if !committed { CGCancelDisplayConfiguration(config) } }

        if extending {
            for display in displays {
                try checked(CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay), "Stopping mirroring")
            }
            if canRestore(saved, identifiers: displays.map(identifier)) {
                for display in displays {
                    if let position = saved.first(where: { $0.uuid == identifier(display) }) {
                        try checked(CGConfigureDisplayOrigin(config, display, position.x, position.y), "Restoring layout")
                    }
                }
            } else {
                // No previous layout (or monitors changed): arrange from the main display to the right.
                var x: Int32 = 0
                for display in [main] + displays.filter({ $0 != main }) {
                    try checked(CGConfigureDisplayOrigin(config, display, x, 0), "Arranging displays")
                    x += Int32(CGDisplayPixelsWide(display))
                }
            }
        } else {
            for display in displays where display != main {
                try checked(CGConfigureDisplayMirrorOfDisplay(config, display, main), "Enabling mirroring")
            }
        }
        // Session scope: no permanent display preference changes.
        try checked(CGCompleteDisplayConfiguration(config, .forSession), "Applying display change")
        committed = true
        if !extending, let data = try? JSONEncoder().encode(positions) {
            UserDefaults.standard.set(data, forKey: layoutKey)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let controller = MirrorController()
    private var observer: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var debounceUntil = Date.distantPast
    private var helpWindow: NSWindow?
    private var stateLabel: NSTextField?
    private var displayLabel: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Mirror Toggle")
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        if CommandLine.arguments.contains("--help-window") { showHelp() }
    }

    private func refresh() {
        let displays = (try? onlineDisplays()) ?? []
        let isMirrored = mirrored(displays)
        let symbol = isMirrored ? "rectangle.on.rectangle" : "display.2"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mirror Toggle")
        item.button?.image?.isTemplate = true
        let state = displays.count < 2 ? "Connect a second display" : isMirrored ? "Mirroring · Click to extend" : "Extended · Click to mirror"
        item.button?.toolTip = "\(state)\nRight-click for options"
        item.button?.setAccessibilityValue(state)
        stateLabel?.stringValue = isMirrored ? "Mirroring" : "Extended displays"
        displayLabel?.stringValue = NSScreen.screens.map(\.localizedName).joined(separator: "  ·  ")
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    @objc private func toggle() {
        guard Date() >= debounceUntil else { return }
        debounceUntil = Date().addingTimeInterval(2)
        do {
            try controller.toggle()
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
        } catch { showError(error) }
    }

    private func makeMenu() -> NSMenu {
        let displays = (try? onlineDisplays()) ?? []
        let isMirrored = mirrored(displays)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Mirror Toggle · \(isMirrored ? "Mirroring" : "Extended")", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(NSMenuItem(title: "\(displays.count) displays connected", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let toggleItem = NSMenuItem(title: isMirrored ? "Switch to Extended" : "Mirror Displays", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = displays.count >= 2
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem(title: "Left-click the icon to toggle", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let settings = NSMenuItem(title: "Display Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let help = NSMenuItem(title: "Help…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Mirror Toggle", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func showMenu() {
        let menu = makeMenu()
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func showHelp() {
        if let helpWindow {
            refresh()
            helpWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Mirror Toggle"
        window.isReleasedWhenClosed = false
        let content = NSView()
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 30)
        ])
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Two displays")
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        stack.addArrangedSubview(icon)
        let title = NSTextField(labelWithString: "One click. Same screen.")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        stack.addArrangedSubview(title)
        let subtitle = NSTextField(labelWithString: "Mirror or extend your displays from the menu bar.")
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(24, after: subtitle)
        let state = NSTextField(labelWithString: "")
        state.font = .systemFont(ofSize: 16, weight: .semibold)
        stateLabel = state
        stack.addArrangedSubview(state)
        let displays = NSTextField(wrappingLabelWithString: "")
        displays.alignment = .center
        displays.textColor = .secondaryLabelColor
        displayLabel = displays
        stack.addArrangedSubview(displays)
        stack.setCustomSpacing(24, after: displays)
        let instruction = NSTextField(labelWithString: "Left-click the menu bar icon to toggle.\nRight-click for options, login settings, and Quit.")
        instruction.alignment = .center
        instruction.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(instruction)
        let options = NSButton(title: "Options…", target: self, action: #selector(helpOptions))
        options.bezelStyle = .rounded
        stack.addArrangedSubview(options)
        let footnote = NSTextField(labelWithString: "Your display positions are remembered when you switch back.")
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(footnote)
        helpWindow = window
        refresh()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func helpOptions() {
        guard let view = helpWindow?.contentView else { return }
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 235, y: 395), in: view)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError(error) }
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn’t switch displays"
        alert.informativeText = error.localizedDescription + "\nYou can also change mirroring in System Settings → Displays."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

if CommandLine.arguments.contains("--self-test") {
    let layout = [Position(uuid: "a", x: 0, y: 0), Position(uuid: "b", x: -1920, y: 200)]
    precondition(canRestore(layout, identifiers: ["b", "a"]))
    precondition(!canRestore(layout, identifiers: ["a", "c"]))
    precondition(!canRestore(layout, identifiers: ["a"]))
    let roundTrip = try JSONDecoder().decode([Position].self, from: JSONEncoder().encode(layout))
    precondition(roundTrip[1].x == -1920 && roundTrip[1].y == 200)
    print("PASS: layout restoration, changed-monitor detection, layout persistence")
} else if CommandLine.arguments.contains("--diagnose") {
    let displays = try onlineDisplays()
    print("Online displays: \(displays.count); mirroring: \(mirrored(displays))")
    for display in displays {
        print("\(identifier(display)): main=\(display == CGMainDisplayID()) mirrorOf=\(CGDisplayMirrorsDisplay(display)) bounds=\(CGDisplayBounds(display))")
    }
} else {
    if NSRunningApplication.runningApplications(withBundleIdentifier: "local.weizhi.MirrorToggle")
        .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
