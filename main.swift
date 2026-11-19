import AppKit
import Combine
import ApplicationServices
import SwiftUI

// MARK: - Preferences

final class Preferences: ObservableObject {
    @Published var mouseNaturalScrolling: Bool {
        didSet { defaults.set(mouseNaturalScrolling, forKey: Keys.mouse) }
    }

    @Published var trackpadNaturalScrolling: Bool {
        didSet { defaults.set(trackpadNaturalScrolling, forKey: Keys.trackpad) }
    }

    @Published var ctrlFixEnabled: Bool {
        didSet { defaults.set(ctrlFixEnabled, forKey: Keys.ctrlFix) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyScrollPreferences(defaults: defaults)
        self.mouseNaturalScrolling = defaults.object(forKey: Keys.mouse) as? Bool ?? true
        self.trackpadNaturalScrolling = defaults.object(forKey: Keys.trackpad) as? Bool ?? true
        self.ctrlFixEnabled = defaults.object(forKey: Keys.ctrlFix) as? Bool ?? true
    }

    func desiredNaturalScrolling(for device: ScrollDeviceKind) -> Bool {
        switch device {
        case .mouse: return mouseNaturalScrolling
        case .trackpad: return trackpadNaturalScrolling
        }
    }

    private static func migrateLegacyScrollPreferences(defaults: UserDefaults) {
        guard defaults.object(forKey: Keys.mouse) == nil,
              let legacy = defaults.persistentDomain(forName: "com.codespeaks.scrollsplit")
        else { return }

        if let mouse = legacy["mouseNaturalScrolling"] as? Bool {
            defaults.set(mouse, forKey: Keys.mouse)
        }
        if let trackpad = legacy["trackpadNaturalScrolling"] as? Bool {
            defaults.set(trackpad, forKey: Keys.trackpad)
        }
    }

    private enum Keys {
        static let mouse = "mouseNaturalScrolling"
        static let trackpad = "trackpadNaturalScrolling"
        static let ctrlFix = "ctrlFixEnabled"
    }
}

enum ScrollDeviceKind {
    case mouse
    case trackpad
}

enum EventTapState: Equatable {
    case active
    case unavailable(String)
}

enum PermissionRequirement: Equatable {
    case accessibility
    case eventTap
}

func permissionRequirement(accessibilityGranted: Bool, eventTapActive: Bool) -> PermissionRequirement? {
    if !accessibilityGranted { return .accessibility }
    if !eventTapActive { return .eventTap }
    return nil
}

// MARK: - Engine

final class PerfectMouseEngine: ObservableObject {
    private let preferences: Preferences
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tickTimer: Timer?

    @Published private(set) var state: EventTapState = .unavailable("Not started")
    @Published private(set) var fixCount = 0
    @Published private(set) var latched = false

    var onStateChange: ((EventTapState) -> Void)?

    private var ctrlSince: Date?
    private var lastKeyActivity = Date.distantPast
    private var injectedUntil = Date.distantPast
    private var lastInject = Date.distantPast

    private let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/PerfectMouse.log")

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: Lifecycle

    func start() {
        guard tap == nil else { return }

        let interest: [CGEventType] = [
            .scrollWheel,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .flagsChanged, .keyDown, .keyUp
        ]
        var mask: UInt64 = 0
        for type in interest { mask |= (UInt64(1) << UInt64(type.rawValue)) }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<PerfectMouseEngine>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                engine.reenable()
                return Unmanaged.passUnretained(event)
            }

            engine.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: refcon
        ) else {
            fail("Grant Accessibility")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            fail("Event tap source unavailable")
            return
        }

        tap = newTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        state = .active
        log("event tap active")

        startTicking()
    }

    private func fail(_ message: String) {
        tap = nil
        runLoopSource = nil
        state = .unavailable(message)
    }

    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        log("tap re-enabled")
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        tickTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.current.add(tickTimer!, forMode: .common)
    }

    // MARK: Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .keyDown || type == .keyUp {
            lastKeyActivity = Date()
            return
        }

        if type == .flagsChanged {
            guard Date() > injectedUntil else { return }
            if event.flags.contains(.maskControl) {
                if ctrlSince == nil { ctrlSince = Date() }
            } else {
                ctrlSince = nil
                if latched { setLatched(false) }
            }
            return
        }

        if type == .scrollWheel {
            processScroll(event)
        }

        guard latched, event.flags.contains(.maskControl) else { return }

        event.flags.remove(.maskControl)

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            if Date().timeIntervalSince(lastInject) > 1.0 {
                clearStuckControl()
            }
        }
    }

    private func processScroll(_ event: CGEvent) {
        let device = event.scrollDeviceKind()
        let systemNatural = systemNaturalScrollingEnabled()
        let desiredNatural = preferences.desiredNaturalScrolling(for: device)

        guard shouldInvertScroll(systemNatural: systemNatural, desiredNatural: desiredNatural) else {
            return
        }

        let fields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2]
        for field in fields {
            event.setIntegerValueField(field, value: -event.getIntegerValueField(field))
        }
    }

    // MARK: Latch watchdog

    private func tick() {
        guard preferences.ctrlFixEnabled else {
            ctrlSince = nil
            if latched { setLatched(false) }
            return
        }

        let ctrlFlag = CGEventSource.flagsState(.combinedSessionState).contains(.maskControl)

        if !ctrlFlag {
            ctrlSince = nil
            if latched { setLatched(false) }
            return
        }

        if ctrlSince == nil { ctrlSince = Date() }

        guard !latched, let since = ctrlSince else { return }
        guard Date().timeIntervalSince(since) > 2.5,
              Date().timeIntervalSince(lastKeyActivity) > 2.5,
              Date() > injectedUntil
        else { return }

        setLatched(true)
        fixCount += 1
        log("CTRL LATCH DETECTED after \(String(format: "%.1f", Date().timeIntervalSince(since)))s, cleaning")
        clearStuckControl()
    }

    private func setLatched(_ value: Bool) {
        guard latched != value else { return }
        latched = value
        if !value { log("latch cleared") }
    }

    private func clearStuckControl() {
        lastInject = Date()
        injectedUntil = Date().addingTimeInterval(0.4)

        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for key: CGKeyCode in [59, 62] {
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            up?.flags = []
            up?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Logging

    func log(_ text: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(fmt.string(from: Date())) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

private extension CGEvent {
    func scrollDeviceKind() -> ScrollDeviceKind {
        getIntegerValueField(.scrollWheelEventIsContinuous) != 0 ? .trackpad : .mouse
    }
}

// MARK: - Scroll helpers

struct SystemNaturalScrollingReader {
    let defaults: UserDefaults

    func isEnabled() -> Bool {
        defaults.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool ?? true
    }
}

func systemNaturalScrollingEnabled(defaults: UserDefaults = .standard) -> Bool {
    SystemNaturalScrollingReader(defaults: defaults).isEnabled()
}

func shouldInvertScroll(systemNatural: Bool, desiredNatural: Bool) -> Bool {
    systemNatural != desiredNatural
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var engine = PerfectMouseEngine(preferences: preferences)
    private var statusBarController: StatusBarController?
    private var retryTimer: Timer?
    private var lockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        acquireSingleInstanceLock()

        NSApp.setActivationPolicy(.accessory)

        statusBarController = StatusBarController(
            preferences: preferences,
            engine: engine,
            onQuit: { NSApp.terminate(nil) }
        )

        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as NSDictionary)
        }

        engine.start()
        statusBarController?.refresh()

        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.engine.start()
                self.statusBarController?.refresh()
            }
        }

        engine.log("started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.log("quit")
    }

    private func acquireSingleInstanceLock() {
        let dir = NSHomeDirectory() + "/Library/Application Support/PerfectMouse"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        lockFD = open(dir + "/lock", O_CREAT | O_RDWR, 0o644)
        if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            NSApp.terminate(nil)
        }
    }
}

@main
struct PerfectMouseMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - Status bar

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let preferences: Preferences
    private let engine: PerfectMouseEngine
    private let onQuit: () -> Void
    private var subscriptions = Set<AnyCancellable>()

    init(preferences: Preferences, engine: PerfectMouseEngine, onQuit: @escaping () -> Void) {
        self.preferences = preferences
        self.engine = engine
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover.behavior = .transient

        let content = ContentView(
            preferences: preferences,
            engine: engine,
            onQuit: onQuit,
            onOpenPrivacy: Self.openPrivacySettings(for:)
        )

        popover.contentViewController = NSHostingController(rootView: content)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            button.toolTip = "PerfectMouse"
        }

        engine.onStateChange = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }

        preferences.objectWillChange.sink { [weak self] _ in
            self?.refresh()
        }.store(in: &subscriptions)

        engine.objectWillChange.sink { [weak self] _ in
            self?.refresh()
        }.store(in: &subscriptions)

        refresh()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        guard let button = statusItem.button else { return }

        let symbol: String
        switch engine.state {
        case .active:
            symbol = engine.latched ? "checkmark.circle.fill" : "computermouse"
        case .unavailable:
            symbol = "exclamationmark.triangle.fill"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PerfectMouse")
            ?? NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "PerfectMouse")
        image?.isTemplate = true
        button.image = image
    }

    private static func openPrivacySettings(for requirement: PermissionRequirement) {
        switch requirement {
        case .accessibility, .eventTap:
            if !AXIsProcessTrusted() {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as NSDictionary)
            }

            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
                return
            }

            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var engine: PerfectMouseEngine
    let onQuit: () -> Void
    let onOpenPrivacy: (PermissionRequirement) -> Void

    var body: some View {
        let requirement = permissionRequirement(
            accessibilityGranted: AXIsProcessTrusted(),
            eventTapActive: engine.state == .active
        )

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("PerfectMouse")
                    .font(.title3.weight(.semibold))

                Spacer(minLength: 12)

                if requirement == nil {
                    StatusPill(state: engine.state)
                }
            }

            if let requirement {
                PermissionPrompt(requirement: requirement, onOpenPrivacy: onOpenPrivacy)
            } else {
                Text("Scrolling")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                DeviceToggleRow(
                    title: "Mouse",
                    subtitle: "Natural scrolling",
                    isOn: $preferences.mouseNaturalScrolling
                )

                DeviceToggleRow(
                    title: "Trackpad",
                    subtitle: "Natural scrolling",
                    isOn: $preferences.trackpadNaturalScrolling
                )

                Divider()

                Text("Stuck Ctrl fix")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                DeviceToggleRow(
                    title: "Enabled",
                    subtitle: "Fixes: \(engine.fixCount)",
                    isOn: $preferences.ctrlFixEnabled
                )
            }

            HStack {
                Button("Open log") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/PerfectMouse.log"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PermissionPrompt: View {
    let requirement: PermissionRequirement
    let onOpenPrivacy: (PermissionRequirement) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 8) {
                Text("Allow PerfectMouse in Accessibility")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Button("Open Settings") {
                    onOpenPrivacy(requirement)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.12), in: Capsule())
            }
        }
        .padding(12)
        .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DeviceToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }
}

private struct StatusPill: View {
    let state: EventTapState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch state {
        case .active: return .green
        case .unavailable: return .orange
        }
    }

    private var text: String {
        switch state {
        case .active: return "Running"
        case .unavailable: return "Needs permission"
        }
    }
}
