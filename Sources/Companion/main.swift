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

@MainActor
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: measuredWidth, height: CompanionPreferences.size)
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
private final class PreferencesWindowController: NSObject {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 390),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Companion Preferences"
        window.center()
        window.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)

        let sizeLabel = NSTextField(labelWithString: "Size")
        let sizeSlider = NSSlider(value: Double(CompanionPreferences.size), minValue: 18, maxValue: 30,
                                  target: self, action: #selector(sizeChanged(_:)))
        sizeSlider.isContinuous = true
        let sizeValue = NSTextField(labelWithString: "\(Int(CompanionPreferences.size)) pt")
        sizeSlider.tag = 100
        sizeValue.tag = 101
        let sizeRow = NSStackView(views: [sizeLabel, sizeSlider, sizeValue])
        sizeRow.orientation = .horizontal
        sizeRow.alignment = .centerY
        sizeRow.distribution = .fill
        sizeSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        stack.addArrangedSubview(sizeRow)

        let backgroundLabel = NSTextField(labelWithString: "Background")
        let background = NSPopUpButton()
        CompanionPreferences.Background.allCases.forEach { background.addItem(withTitle: $0.rawValue) }
        background.selectItem(withTitle: CompanionPreferences.background.rawValue)
        background.target = self
        background.action = #selector(backgroundChanged(_:))
        stack.addArrangedSubview(backgroundLabel)
        stack.addArrangedSubview(background)

        let accentLabel = NSTextField(labelWithString: "Accent color")
        let accent = NSPopUpButton()
        ["Purple", "Blue", "Pink", "Orange", "Green", "System"].forEach { accent.addItem(withTitle: $0) }
        accent.selectItem(withTitle: CompanionPreferences.accent)
        accent.target = self
        accent.action = #selector(accentChanged(_:))
        stack.addArrangedSubview(accentLabel)
        stack.addArrangedSubview(accent)

        stack.addArrangedSubview(NSBox.separator())
        stack.addArrangedSubview(makeToggle("Show only occupied workspaces", key: "occupiedOnly", value: CompanionPreferences.occupiedOnly))
        stack.addArrangedSubview(makeToggle("Show app icons", key: "showIcons", value: CompanionPreferences.showIcons))
        stack.addArrangedSubview(makeToggle("Show workspace labels", key: "showLabels", value: CompanionPreferences.showLabels))

        let note = NSTextField(wrappingLabelWithString: "Changes are saved automatically.")
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)

        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        window.contentView = container
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeToggle(_ title: String, key: String, value: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleChanged(_:)))
        button.state = value ? .on : .off
        button.identifier = NSUserInterfaceItemIdentifier(key)
        return button
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        CompanionPreferences.save("stripSize", sender.doubleValue)
        if let value = sender.superview?.viewWithTag(101) as? NSTextField {
            value.stringValue = "\(Int(sender.doubleValue)) pt"
        }
    }
    @objc private func backgroundChanged(_ sender: NSPopUpButton) {
        CompanionPreferences.save("backgroundStyle", sender.titleOfSelectedItem ?? "Glass")
    }
    @objc private func accentChanged(_ sender: NSPopUpButton) {
        CompanionPreferences.save("accentColor", sender.titleOfSelectedItem ?? "Purple")
    }
    @objc private func toggleChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        CompanionPreferences.save(key, sender.state == .on)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = AeroSpaceClient()
    private let preferencesController = PreferencesWindowController()
    private var statusItem: NSStatusItem?
    private var controlsItem: NSStatusItem?
    private var strip: WorkspaceStripView?
    private var stripHeightConstraint: NSLayoutConstraint?
    private var eventProcess: Process?
    private var eventPipe: Pipe?
    private var eventBuffer = ""
    private var reconnectWorkItem: DispatchWorkItem?
    private var refreshWorkItem: DispatchWorkItem?
    private var currentWorkspaces: [Workspace] = []
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

        let controls = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        controlsItem = controls
        controls.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Companion menu")
        controls.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.addItem(withTitle: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "About Companion", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Companion", action: #selector(quit), keyEquivalent: "q").target = self
        controls.menu = menu

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

    @objc private func showPreferences() { preferencesController.show() }
    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func preferencesChanged() {
        stripHeightConstraint?.constant = CompanionPreferences.size
        strip?.update(workspaces: currentWorkspaces) { [weak self] name in
            self?.client.focus(name)
            self?.scheduleRefresh()
        }
        statusItem?.length = max(1, ceil(strip?.intrinsicContentSize.width ?? 1))
        refresh()
    }

    @objc private func applicationLifecycleChanged(_ notification: Notification) { scheduleRefresh() }

    private func refresh() {
        guard let latest = client.snapshot() else { return }
        guard latest != currentWorkspaces else {
            strip?.update(workspaces: latest) { [weak self] name in
                self?.client.focus(name)
                self?.scheduleRefresh()
            }
            statusItem?.length = max(1, ceil(strip?.intrinsicContentSize.width ?? 1))
            return
        }
        currentWorkspaces = latest
        strip?.update(workspaces: latest) { [weak self] name in
            self?.client.focus(name)
            self?.scheduleRefresh()
        }
        statusItem?.length = max(1, ceil(strip?.intrinsicContentSize.width ?? 1))
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
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
