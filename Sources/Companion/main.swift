import AppKit

private enum CompanionPreferences {
    enum Background: String, CaseIterable {
        case glass = "Glass"
        case solid = "Solid"
        case transparent = "Transparent"
    }

    static let defaults = UserDefaults.standard
    static var size: CGFloat {
        let value = defaults.object(forKey: "stripSize") as? Double ?? 22
        return min(30, max(18, CGFloat(value)))
    }
    static var background: Background {
        Background(rawValue: defaults.string(forKey: "backgroundStyle") ?? "Glass") ?? .glass
    }
    static var accent: String { defaults.string(forKey: "accentColor") ?? "Purple" }
    static var occupiedOnly: Bool { defaults.object(forKey: "occupiedOnly") as? Bool ?? false }
    static var showIcons: Bool { defaults.object(forKey: "showIcons") as? Bool ?? true }
    static var showLabels: Bool { defaults.object(forKey: "showLabels") as? Bool ?? true }

    static var accentColor: NSColor {
        switch accent {
        case "Blue": return NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.98, alpha: 1)
        case "Pink": return NSColor(calibratedRed: 0.94, green: 0.40, blue: 0.65, alpha: 1)
        case "Orange": return NSColor(calibratedRed: 0.98, green: 0.59, blue: 0.25, alpha: 1)
        case "Green": return NSColor(calibratedRed: 0.22, green: 0.75, blue: 0.57, alpha: 1)
        case "System": return .controlAccentColor
        default: return NSColor(calibratedRed: 0.68, green: 0.55, blue: 0.98, alpha: 1)
        }
    }

    static func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .companionPreferencesChanged, object: nil)
    }
}

private extension Notification.Name {
    static let companionPreferencesChanged = Notification.Name("CompanionPreferencesChanged")
}

private struct Workspace: Equatable {
    let name: String
    let isFocused: Bool
    let bundleIDs: [String]
}

private final class AeroSpaceClient {
    private let candidates = [
        NSString(string: "~/.local/bin/aerospace").expandingTildeInPath,
        "/opt/homebrew/bin/aerospace",
        "/usr/local/bin/aerospace"
    ]

    private var executable: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(_ arguments: [String]) -> String? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    func snapshot() -> [Workspace]? {
        guard
            let workspaceText = run(["list-workspaces", "--all", "--format", "%{workspace}|%{workspace-is-focused}"]),
            let windowText = run(["list-windows", "--all", "--format", "%{app-bundle-id}|%{workspace}"])
        else { return nil }

        var apps: [String: [String]] = [:]
        for line in windowText.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            if !apps[fields[1], default: []].contains(fields[0]) {
                apps[fields[1], default: []].append(fields[0])
            }
        }

        return workspaceText.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let name = fields.first, !name.isEmpty else { return nil }
            return Workspace(
                name: name,
                isFocused: fields.count > 1 && fields[1].trimmingCharacters(in: .whitespaces) == "true",
                bundleIDs: apps[name, default: []]
            )
        }
    }

    func focus(_ workspace: String) { _ = run(["workspace", workspace]) }

    func subscribe(pipe: Pipe, onExit: @escaping () -> Void) throws -> Process {
        guard let executable else {
            throw NSError(domain: "Companion.AeroSpace", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AeroSpace CLI was not found"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["subscribe", "focus-changed", "focused-workspace-changed",
                             "focused-monitor-changed", "window-detected"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in onExit() }
        try process.run()
        return process
    }
}

@MainActor
private final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 64 }

    func image(for bundleID: String, size: CGFloat) -> NSImage? {
        let key = "\(bundleID)-\(Int(size))" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        image.size = NSSize(width: size, height: size)
        cache.setObject(image, forKey: key)
        return image
    }
}

@MainActor
private final class WorkspaceContentView: NSView {
    let workspace: Workspace
    let onSelect: (String) -> Void

    init(workspace: Workspace, frame: NSRect, onSelect: @escaping (String) -> Void) {
        self.workspace = workspace
        self.onSelect = onSelect
        super.init(frame: frame)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Workspace \(workspace.name), \(workspace.bundleIDs.count) applications")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let scale = CompanionPreferences.size / 22
        let label = CompanionPreferences.showLabels ? workspace.name : ""
        let titleFont = NSFont.systemFont(ofSize: 11 * scale, weight: .semibold)
        let title = label as NSString
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont, .foregroundColor: NSColor.labelColor
        ]
        let titleSize = title.size(withAttributes: titleAttributes)
        let titleWidth = label.isEmpty ? 0 : max(11 * scale, ceil(titleSize.width))
        let titleRect = NSRect(x: 7 * scale, y: floor((bounds.height - titleSize.height) / 2),
                               width: titleWidth, height: titleSize.height)
        if !label.isEmpty { title.draw(in: titleRect, withAttributes: titleAttributes) }

        var x = titleRect.maxX + ((CompanionPreferences.showIcons && !workspace.bundleIDs.isEmpty) ? 5 * scale : 0)
        if CompanionPreferences.showIcons {
            let iconSize = 15 * scale
            for bundleID in workspace.bundleIDs.prefix(3) {
                if let icon = AppIconCache.shared.image(for: bundleID, size: iconSize) {
                    icon.draw(in: NSRect(x: x, y: floor((bounds.height - iconSize) / 2),
                                         width: iconSize, height: iconSize),
                              from: .zero, operation: .sourceOver, fraction: 1)
                }
                x += iconSize + 3 * scale
            }
            if workspace.bundleIDs.count > 3 {
                x -= 3 * scale
                let more = "+\(workspace.bundleIDs.count - 3)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9 * scale, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                let size = more.size(withAttributes: attributes)
                more.draw(in: NSRect(x: x + 2 * scale, y: floor((bounds.height - size.height) / 2),
                                     width: size.width, height: size.height), withAttributes: attributes)
            }
        }

        if workspace.isFocused {
            let radius = 8.5 * scale
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: radius, yRadius: radius)
            CompanionPreferences.accentColor.withAlphaComponent(0.65).setStroke()
            border.lineWidth = 1
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onSelect(workspace.name) }
}

@MainActor
private final class WorkspaceStripView: NSView {
    private var workspaces: [Workspace] = []
    private var glassContainer: NSGlassEffectContainerView?
    private var selection: ((String) -> Void)?
    private var compartmentViews: [NSView] = []
    var contextMenu: NSMenu?

    override var intrinsicContentSize: NSSize {
        NSSize(width: measuredWidth, height: CompanionPreferences.size)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenu else { return }
        NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
    }

    private var gap: CGFloat { 5 * CompanionPreferences.size / 22 }
    private var measuredWidth: CGFloat {
        guard !workspaces.isEmpty else { return 1 }
        return workspaces.reduce(0) { $0 + compartmentWidth(for: $1) }
            + CGFloat(max(0, workspaces.count - 1)) * gap + 4
    }

    private func compartmentWidth(for workspace: Workspace) -> CGFloat {
        let scale = CompanionPreferences.size / 22
        let label = CompanionPreferences.showLabels ? workspace.name : ""
        let font = NSFont.systemFont(ofSize: 11 * scale, weight: .semibold)
        let labelWidth = label.isEmpty ? 0 : max(11 * scale, ceil((label as NSString).size(withAttributes: [.font: font]).width))
        var width = 14 * scale + labelWidth
        if CompanionPreferences.showIcons && !workspace.bundleIDs.isEmpty {
            let visible = min(3, workspace.bundleIDs.count)
            width += 5 * scale + CGFloat(visible) * 15 * scale + CGFloat(max(0, visible - 1)) * 3 * scale
            if workspace.bundleIDs.count > 3 {
                let more = "+\(workspace.bundleIDs.count - 3)" as NSString
                width += 5 * scale + ceil(more.size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9 * scale, weight: .medium)
                ]).width)
            }
        }
        if !workspace.bundleIDs.isEmpty { width = max(width, 44 * scale) }
        return ceil(max(24 * scale, width))
    }

    func update(workspaces: [Workspace], onSelect: @escaping (String) -> Void) {
        self.workspaces = CompanionPreferences.occupiedOnly
            ? workspaces.filter { !$0.bundleIDs.isEmpty || $0.isFocused }
            : workspaces
        selection = onSelect
        glassContainer?.removeFromSuperview()
        glassContainer = nil
        compartmentViews.forEach { $0.removeFromSuperview() }
        compartmentViews.removeAll()

        let height = CompanionPreferences.size
        let scale = height / 22
        let contentHost = NSView(frame: NSRect(x: 0, y: 0, width: measuredWidth, height: height))
        var x: CGFloat = 2

        for workspace in self.workspaces {
            let frame = NSRect(x: x, y: 0, width: compartmentWidth(for: workspace), height: height)
            let content = WorkspaceContentView(workspace: workspace, frame: NSRect(origin: .zero, size: frame.size),
                                                onSelect: onSelect)
            let background: NSView
            if CompanionPreferences.background == .glass {
                let glass = NSGlassEffectView(frame: frame)
                glass.cornerRadius = 9 * scale
                if workspace.isFocused { glass.tintColor = CompanionPreferences.accentColor.withAlphaComponent(0.22) }
                glass.contentView = content
                background = glass
            } else {
                let plain = CompartmentBackgroundView(frame: frame, focused: workspace.isFocused,
                                                      style: CompanionPreferences.background)
                plain.addSubview(content)
                content.frame = plain.bounds
                content.autoresizingMask = [.width, .height]
                background = plain
            }
            contentHost.addSubview(background)
            compartmentViews.append(background)
            x += frame.width + gap
        }

        if CompanionPreferences.background == .glass {
            let container = NSGlassEffectContainerView(frame: contentHost.frame)
            container.spacing = gap
            container.contentView = contentHost
            addSubview(container)
            glassContainer = container
        } else {
            addSubview(contentHost)
            compartmentViews = [contentHost]
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

@MainActor
private final class CompartmentBackgroundView: NSView {
    private let focused: Bool
    private let style: CompanionPreferences.Background
    init(frame: NSRect, focused: Bool, style: CompanionPreferences.Background) {
        self.focused = focused
        self.style = style
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 9 * CompanionPreferences.size / 22,
                                yRadius: 9 * CompanionPreferences.size / 22)
        if style == .solid {
            (focused ? CompanionPreferences.accentColor.withAlphaComponent(0.32) : NSColor.controlBackgroundColor.withAlphaComponent(0.92)).setFill()
            path.fill()
        }
        if focused {
            CompanionPreferences.accentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = AeroSpaceClient()
    private var statusItem: NSStatusItem?
    private var strip: WorkspaceStripView?
    private var stripHeightConstraint: NSLayoutConstraint?
    private var eventProcess: Process?
    private var eventPipe: Pipe?
    private var eventBuffer = ""
    private var reconnectWorkItem: DispatchWorkItem?
    private var refreshWorkItem: DispatchWorkItem?
    private var currentWorkspaces: [Workspace] = []
    private var isRefreshing = false
    private var refreshPending = false
    private var isStopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: 1)
        statusItem = item
        guard let button = item.button else { return }
        button.title = ""
        button.image = nil

        let strip = WorkspaceStripView(frame: NSRect(x: 0, y: 0, width: 1, height: CompanionPreferences.size))
        strip.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(strip)
        let heightConstraint = strip.heightAnchor.constraint(equalToConstant: CompanionPreferences.size)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            strip.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            heightConstraint
        ])
        stripHeightConstraint = heightConstraint
        self.strip = strip
        strip.contextMenu = makeContextMenu()

        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: .companionPreferencesChanged, object: nil)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationLifecycleChanged(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationLifecycleChanged(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        refresh()
        startEventStream()
    }

    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        func addChoice(_ title: String, key: String, value: String, selected: Bool, to parent: NSMenu) {
            let item = NSMenuItem(title: title, action: #selector(menuChoiceChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [key, value]
            item.state = selected ? .on : .off
            parent.addItem(item)
        }
        let sizeMenu = NSMenu()
        for size in [18, 20, 22, 24, 26, 28, 30] {
            addChoice("\(size) pt", key: "stripSize", value: "\(size)", selected: Int(CompanionPreferences.size) == size, to: sizeMenu)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let backgroundMenu = NSMenu()
        for option in CompanionPreferences.Background.allCases {
            addChoice(option.rawValue, key: "backgroundStyle", value: option.rawValue,
                      selected: CompanionPreferences.background == option, to: backgroundMenu)
        }
        let backgroundItem = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
        backgroundItem.submenu = backgroundMenu
        menu.addItem(backgroundItem)

        let accentMenu = NSMenu()
        for color in ["Purple", "Blue", "Pink", "Orange", "Green", "System"] {
            addChoice(color, key: "accentColor", value: color, selected: CompanionPreferences.accent == color, to: accentMenu)
        }
        let accentItem = NSMenuItem(title: "Accent", action: nil, keyEquivalent: "")
        accentItem.submenu = accentMenu
        menu.addItem(accentItem)
        menu.addItem(NSMenuItem.separator())

        func addToggle(_ title: String, key: String, value: Bool) {
            let item = NSMenuItem(title: title, action: #selector(menuToggleChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = value ? .on : .off
            menu.addItem(item)
        }
        addToggle("Show only occupied workspaces", key: "occupiedOnly", value: CompanionPreferences.occupiedOnly)
        addToggle("Show app icons", key: "showIcons", value: CompanionPreferences.showIcons)
        addToggle("Show workspace labels", key: "showLabels", value: CompanionPreferences.showLabels)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "About Companion", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Companion", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func menuChoiceChanged(_ item: NSMenuItem) {
        guard let values = item.representedObject as? [String], values.count == 2 else { return }
        let value: Any
        if values[0] == "stripSize" { value = Double(values[1]) ?? 22 }
        else { value = values[1] }
        CompanionPreferences.save(values[0], value)
        strip?.contextMenu = makeContextMenu()
    }

    @objc private func menuToggleChanged(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        CompanionPreferences.save(key, item.state != .on)
        strip?.contextMenu = makeContextMenu()
    }

    @objc private func preferencesChanged() {
        stripHeightConstraint?.constant = CompanionPreferences.size
        renderWorkspaces()
    }

    @objc private func applicationLifecycleChanged(_ notification: Notification) { scheduleRefresh() }

    private func renderWorkspaces() {
        strip?.update(workspaces: currentWorkspaces) { [weak self] name in
            guard let self else { return }
            DispatchQueue.global(qos: .userInteractive).async { [client = self.client] in client.focus(name) }
            self.scheduleRefresh()
        }
        statusItem?.length = max(1, ceil(strip?.intrinsicContentSize.width ?? 1))
    }

    private func refresh() {
        guard !isRefreshing else { refreshPending = true; return }
        isRefreshing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self, client = self.client] in
            let latest = client.snapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                if let latest, latest != self.currentWorkspaces {
                    self.currentWorkspaces = latest
                    self.renderWorkspaces()
                }
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func startEventStream() {
        guard !isStopping, eventProcess == nil else { return }
        let pipe = Pipe()
        do {
            let process = try client.subscribe(pipe: pipe) { [weak self] in
                DispatchQueue.main.async { self?.eventStreamDidEnd() }
            }
            eventPipe = pipe
            eventProcess = process
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.consumeEvents(text) }
            }
        } catch { scheduleReconnect() }
    }

    private func consumeEvents(_ text: String) {
        eventBuffer += text
        while let newline = eventBuffer.firstIndex(of: "\n") {
            let line = String(eventBuffer[..<newline])
            eventBuffer.removeSubrange(...newline)
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = object["_event"] as? String else { continue }
            if ["focus-changed", "focused-workspace-changed", "focused-monitor-changed", "window-detected"].contains(event) {
                scheduleRefresh()
            }
        }
    }

    private func eventStreamDidEnd() {
        eventPipe?.fileHandleForReading.readabilityHandler = nil
        eventPipe = nil
        eventProcess = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !isStopping, reconnectWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.refresh()
            self.startEventStream()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func applicationWillTerminate(_ notification: Notification) {
        isStopping = true
        refreshWorkItem?.cancel()
        reconnectWorkItem?.cancel()
        eventPipe?.fileHandleForReading.readabilityHandler = nil
        eventProcess?.terminate()
        eventProcess = nil
        eventPipe = nil
    }
}

@main
private enum CompanionApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
