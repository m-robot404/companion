import AppKit

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
        } catch {
            return nil
        }
    }

    func snapshot() -> [Workspace]? {
        guard
            let workspaceText = run([
                "list-workspaces", "--all", "--format",
                "%{workspace}|%{workspace-is-focused}"
            ]),
            let windowText = run([
                "list-windows", "--all", "--format",
                "%{app-bundle-id}|%{workspace}"
            ])
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

    func focus(_ workspace: String) {
        _ = run(["workspace", workspace])
    }

    func subscribe(pipe: Pipe, onExit: @escaping () -> Void) throws -> Process {
        guard let executable else {
            throw NSError(
                domain: "Companion.AeroSpace",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AeroSpace CLI was not found"]
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "subscribe",
            "focus-changed",
            "focused-workspace-changed",
            "focused-monitor-changed",
            "window-detected"
        ]
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

    private init() {
        cache.countLimit = 64
    }

    func image(for bundleID: String) -> NSImage? {
        let key = bundleID as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        image.size = NSSize(width: 15, height: 15)
        cache.setObject(image, forKey: key)
        return image
    }
}

@MainActor
private final class WorkspaceContentView: NSView {
    let workspace: Workspace
    let onSelect: (String) -> Void
    private let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private let countFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private let iconSize: CGFloat = 15

    init(workspace: Workspace, frame: NSRect, onSelect: @escaping (String) -> Void) {
        self.workspace = workspace
        self.onSelect = onSelect
        super.init(frame: frame)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Workspace \(workspace.name), \(workspace.bundleIDs.count) applications")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let title = workspace.name as NSString
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.labelColor
        ]
        let titleSize = title.size(withAttributes: titleAttributes)
        let titleWidth = max(11, ceil(titleSize.width))
        let titleRect = NSRect(
            x: 7,
            y: floor((bounds.height - titleSize.height) / 2),
            width: titleWidth,
            height: titleSize.height
        )
        title.draw(in: titleRect, withAttributes: titleAttributes)

        var x = titleRect.maxX + (workspace.bundleIDs.isEmpty ? 0 : 5)
        for bundleID in workspace.bundleIDs.prefix(3) {
            if let icon = AppIconCache.shared.image(for: bundleID) {
                icon.draw(
                    in: NSRect(x: x, y: floor((bounds.height - iconSize) / 2),
                               width: iconSize, height: iconSize),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }
            x += iconSize + 3
        }

        if workspace.bundleIDs.count > 3 {
            x -= 3
            let more = "+\(workspace.bundleIDs.count - 3)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: countFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = more.size(withAttributes: attributes)
            more.draw(
                in: NSRect(x: x + 2, y: floor((bounds.height - size.height) / 2),
                           width: size.width, height: size.height),
                withAttributes: attributes
            )
        }

        if workspace.isFocused {
            let border = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 8.5,
                yRadius: 8.5
            )
            NSColor.controlAccentColor.withAlphaComponent(0.42).setStroke()
            border.lineWidth = 0.8
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect(workspace.name)
    }
}

@MainActor
private final class WorkspaceStripView: NSView {
    private var workspaces: [Workspace] = []
    private var glassContainer: NSGlassEffectContainerView?
    private let height: CGFloat = 22
    private let gap: CGFloat = 5

    override var intrinsicContentSize: NSSize {
        NSSize(width: measuredWidth, height: height)
    }

    private var measuredWidth: CGFloat {
        guard !workspaces.isEmpty else { return 1 }
        return workspaces.reduce(0) { $0 + compartmentWidth(for: $1) }
            + CGFloat(max(0, workspaces.count - 1)) * gap + 4
    }

    private func compartmentWidth(for workspace: Workspace) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let labelWidth = max(11, ceil((workspace.name as NSString).size(
            withAttributes: [.font: font]
        ).width))
        let visibleIcons = min(3, workspace.bundleIDs.count)
        var width: CGFloat = 14 + labelWidth
        if visibleIcons > 0 {
            width += 5 + CGFloat(visibleIcons) * 15 + CGFloat(visibleIcons - 1) * 3
        }
        if workspace.bundleIDs.count > 3 {
            let more = "+\(workspace.bundleIDs.count - 3)" as NSString
            let moreWidth = ceil(more.size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)]
            ).width)
            width += 5 + moreWidth
        }
        if !workspace.bundleIDs.isEmpty { width = max(width, 44) }
        return ceil(width)
    }

    func update(workspaces: [Workspace], onSelect: @escaping (String) -> Void) {
        self.workspaces = workspaces
        glassContainer?.removeFromSuperview()

        let contentHost = NSView(frame: bounds)
        contentHost.autoresizingMask = [.width, .height]
        var x: CGFloat = 2

        for workspace in workspaces {
            let width = compartmentWidth(for: workspace)
            let frame = NSRect(x: x, y: 0, width: width, height: height)
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = 9
            if workspace.isFocused {
                glass.tintColor = NSColor.controlAccentColor.withAlphaComponent(0.20)
            }

            let content = WorkspaceContentView(
                workspace: workspace,
                frame: NSRect(origin: .zero, size: frame.size),
                onSelect: onSelect
            )
            glass.contentView = content
            contentHost.addSubview(glass)
            x += width + gap
        }

        let container = NSGlassEffectContainerView(frame: bounds)
        container.spacing = gap
        container.autoresizingMask = [.width, .height]
        container.contentView = contentHost
        addSubview(container)
        glassContainer = container

        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = AeroSpaceClient()
    private var statusItem: NSStatusItem?
    private var strip: WorkspaceStripView?
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

        let strip = WorkspaceStripView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
        strip.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            strip.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            strip.heightAnchor.constraint(equalToConstant: 22)
        ])
        self.strip = strip

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(applicationLifecycleChanged(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationLifecycleChanged(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        refresh()
        startEventStream()
    }

    @objc private func applicationLifecycleChanged(_ notification: Notification) {
        scheduleRefresh()
    }

    private func refresh() {
        guard let latest = client.snapshot() else { return }
        guard latest != currentWorkspaces else { return }
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
        } catch {
            scheduleReconnect()
        }
    }

    private func consumeEvents(_ text: String) {
        eventBuffer += text
        while let newline = eventBuffer.firstIndex(of: "\n") {
            let line = String(eventBuffer[..<newline])
            eventBuffer.removeSubrange(...newline)
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let event = object["_event"] as? String
            else { continue }

            if [
                "focus-changed",
                "focused-workspace-changed",
                "focused-monitor-changed",
                "window-detected"
            ].contains(event) {
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
