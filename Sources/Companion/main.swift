import AppKit
import CoreGraphics
import Darwin
import ScreenCaptureKit

// MARK: - Preferences

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
    static var currentDisplayOnly: Bool { defaults.object(forKey: "currentDisplayOnly") as? Bool ?? false }
    static var showModeBadge: Bool { defaults.object(forKey: "showModeBadge") as? Bool ?? true }
    static var workspaceSpacing: CGFloat {
        CGFloat(defaults.object(forKey: "workspaceSpacing") as? Double ?? 5)
    }
    static var iconSpacing: CGFloat {
        CGFloat(defaults.object(forKey: "iconSpacing") as? Double ?? 3)
    }
    static var inactiveIconOpacity: CGFloat {
        CGFloat(defaults.object(forKey: "inactiveIconOpacity") as? Double ?? 0.82)
    }
    static var backgroundOpacity: CGFloat {
        CGFloat(defaults.object(forKey: "backgroundOpacity") as? Double ?? 0.92)
    }

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

// MARK: - Models

private struct WorkspaceWindow: Equatable, Sendable {
    let id: String
    let bundleID: String
    let appName: String
    let title: String
}

private struct AppGroup: Equatable, Sendable {
    let bundleID: String
    let appName: String
    let windows: [WorkspaceWindow]
}

private struct Workspace: Equatable, Sendable {
    let name: String
    let isFocused: Bool
    let windows: [WorkspaceWindow]

    var appGroups: [AppGroup] {
        var order: [String] = []
        var grouped: [String: [WorkspaceWindow]] = [:]
        for window in windows {
            if grouped[window.bundleID] == nil { order.append(window.bundleID) }
            grouped[window.bundleID, default: []].append(window)
        }
        return order.compactMap { id in
            guard let items = grouped[id], let first = items.first else { return nil }
            return AppGroup(bundleID: id, appName: first.appName, windows: items)
        }
    }
}

// MARK: - High Performance AeroSpace Socket / CLI Client

private final class AeroSpaceClient: @unchecked Sendable {
    private let candidates = [
        NSString(string: "~/.local/bin/aerospace").expandingTildeInPath,
        "/opt/homebrew/bin/aerospace",
        "/usr/local/bin/aerospace"
    ]

    private var socketPath: String {
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        return "/tmp/bobko.aerospace-\(user).sock"
    }

    init() {
        signal(SIGPIPE, SIG_IGN)
    }

    private var executable: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// High performance direct UNIX Domain Socket query.
    /// Eliminates process forking and brings latency down to < 2ms.
    private func querySocket(args: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = pathBytes.withUnsafeBufferPointer { buf in
                memcpy(ptr, buf.baseAddress!, buf.count)
            }
        }

        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectRes == 0 else { return nil }

        // 1. Handshake: Send protocol version 1 (uint32 little endian)
        var clientVer = UInt32(1).littleEndian
        guard write(fd, &clientVer, 4) == 4 else { return nil }

        // 2. Read server protocol version
        var serverVer: UInt32 = 0
        guard read(fd, &serverVer, 4) == 4, serverVer == 1 else { return nil }

        // 3. Send ClientRequest JSON with 4-byte length prefix
        let requestPayload: [String: Any] = [
            "args": args,
            "stdin": "",
            "windowId": NSNull(),
            "workspace": NSNull()
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestPayload) else { return nil }
        var reqLen = UInt32(jsonData.count).littleEndian
        guard write(fd, &reqLen, 4) == 4 else { return nil }
        let writtenBytes = jsonData.withUnsafeBytes { write(fd, $0.baseAddress!, jsonData.count) }
        guard writtenBytes == jsonData.count else { return nil }

        // 4. Read ServerAnswer length prefix
        var ansLen: UInt32 = 0
        guard read(fd, &ansLen, 4) == 4 else { return nil }
        let expectedBytes = Int(UInt32(littleEndian: ansLen))
        guard expectedBytes > 0, expectedBytes < 10_000_000 else { return nil }

        // Read payload
        var responseData = Data()
        var buffer = [UInt8](<repeating: 0, count: min(expectedBytes, 16384>))
        while responseData.count < expectedBytes {
            let toRead = min(buffer.count, expectedBytes - responseData.count)
            let n = read(fd, &buffer, toRead)
            if n <= 0 { break }
            responseData.append(buffer, count: n)
        }

        guard let jsonResponse = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let stdout = jsonResponse["stdout"] as? String else { return nil }
        return stdout
    }

    /// Fallback execution via CLI process if the direct socket is unavailable.
    private func runCLI(_ arguments: [String]) -> String? {
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

    func execute(_ arguments: [String]) -> String? {
        if let fastResult = querySocket(args: arguments) {
            return fastResult
        }
        return runCLI(arguments)
    }

    func snapshot(currentDisplayOnly: Bool) -> [Workspace]? {
        var wsArgs = ["list-workspaces", "--all", "--format", "%{workspace}|%{workspace-is-focused}"]
        if currentDisplayOnly {
            wsArgs = ["list-workspaces", "--monitor", "focused", "--format", "%{workspace}|%{workspace-is-focused}"]
        }
        guard
            let workspaceText = execute(wsArgs),
            let windowText = execute(["list-windows", "--all", "--format",
                                      "%{window-id}%{tab}%{app-bundle-id}%{tab}%{app-name}%{tab}%{window-title}%{tab}%{workspace}"])
        else { return nil }

        var windows: [String: [WorkspaceWindow]] = [:]
        for line in windowText.split(whereSeparator: \.isNewline) {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 5, !fields[0].isEmpty, !fields[1].isEmpty, !fields[4].isEmpty else { continue }
            let item = WorkspaceWindow(id: fields[0], bundleID: fields[1],
                                       appName: fields[2].isEmpty ? fields[1] : fields[2],
                                       title: fields[3].isEmpty ? (fields[2].isEmpty ? fields[1] : fields[2]) : fields[3])
            windows[fields[4], default: []].append(item)
        }

        return workspaceText.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let name = fields.first, !name.isEmpty else { return nil }
            return Workspace(
                name: name,
                isFocused: fields.count > 1 && fields[1].trimmingCharacters(in: .whitespaces) == "true",
                windows: windows[name, default: []]
            )
        }
    }

    func focus(_ workspace: String) { _ = execute(["workspace", workspace]) }
    func focusWindow(_ id: String) { _ = execute(["focus", "--window-id", id]) }
    func closeWindow(_ id: String) { _ = execute(["close", "--window-id", id]) }
    func moveWindow(_ id: String, toWorkspace ws: String) { _ = execute(["move-node-to-workspace", "--window-id", id, ws]) }
    func toggleFloating(windowId: String) { _ = execute(["layout", "--window-id", windowId, "floating", "tiling"]) }
    func toggleWorkspaceLayout(workspace: String) { _ = execute(["layout", "--workspace", workspace, "accordion", "tiles"]) }
    func resetMode() { _ = execute(["mode", "main"]) }

    func subscribe(pipe: Pipe, onExit: @escaping @Sendable () -> Void) throws -> Process {
        guard let executable else {
            throw NSError(domain: "Companion.AeroSpace", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AeroSpace CLI was not found"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "subscribe",
            "focus-changed",
            "focused-workspace-changed",
            "focused-monitor-changed",
            "window-detected",
            "mode-changed"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in onExit() }
        try process.run()
        return process
    }
}

// MARK: - App Icon Cache

@MainActor
private final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 48 }

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

// MARK: - Interactive View Targets

@MainActor
private final class WorkspaceIconHitView: NSView {
    var onEnter: ((NSView) -> Void)?
    var onExit: (() -> Void)?
    var onPress: ((NSEvent) -> Void)?
    var onRightPress: ((NSEvent) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?(self) }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) { onPress?(event) }
    override func rightMouseDown(with event: NSEvent) { onRightPress?(event) }
}

// MARK: - Throttled ScreenCaptureKit Preview

private actor WindowPreviewSource {
    static let shared = WindowPreviewSource()
    private var windowsByID: [CGWindowID: SCWindow] = [:]
    private var refreshedAt = Date.distantPast
    private var thumbnails: [CGWindowID: CGImage] = [:]
    private var thumbnailOrder: [CGWindowID] = []
    private let cacheLimit = 8

    private func refreshWindowMap() async {
        guard Date().timeIntervalSince(refreshedAt) >= 1.5 || windowsByID.isEmpty else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        ) else { return }
        windowsByID = Dictionary(content.windows.map { ($0.windowID, $0) },
                                 uniquingKeysWith: { _, latest in latest })
        refreshedAt = Date()
    }

    func capture(_ window: WorkspaceWindow) async -> CGImage? {
        let rawValue = window.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedID = rawValue.hasPrefix("0x")
            ? UInt32(rawValue.dropFirst(2), radix: 16)
            : UInt32(rawValue)
        guard let rawID = parsedID else { return nil }
        let id = CGWindowID(rawID)

        if let cached = thumbnails[id] { return cached }
        await refreshWindowMap()

        var target = windowsByID[id]
        if target == nil {
            let candidates = windowsByID.values.filter {
                $0.owningApplication?.bundleIdentifier == window.bundleID
            }
            if !window.title.isEmpty {
                let titleMatches = candidates.filter { $0.title == window.title }
                if titleMatches.count == 1 { target = titleMatches[0] }
            }
            if target == nil && candidates.count == 1 { target = candidates[0] }
        }
        guard let target else { return nil }

        // Scaled to 240x135 to strictly minimize RAM usage
        let sourceWidth = max(1, target.frame.width)
        let sourceHeight = max(1, target.frame.height)
        let scale = min(1, min(240 / sourceWidth, 135 / sourceHeight))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(sourceWidth * scale))
        configuration.height = max(1, Int(sourceHeight * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target),
                configuration: configuration
            )
            thumbnails[id] = image
            thumbnailOrder.removeAll { $0 == id }
            thumbnailOrder.append(id)
            while thumbnailOrder.count > cacheLimit {
                thumbnails[thumbnailOrder.removeFirst()] = nil
            }
            return image
        } catch {
            return nil
        }
    }
}

// MARK: - Workspace Content View

@MainActor
private final class WorkspaceContentView: NSView {
    private(set) var workspace: Workspace
    let onSelect: (String) -> Void
    let onFocusWindow: (String) -> Void
    let onAction: (String, String, WorkspaceWindow) -> Void
    let allWorkspaceNamesProvider: () -> [String]

    private var previewPopover: NSPopover?
    private weak var previewAnchor: NSView?
    private var previewDismissWorkItem: DispatchWorkItem?
    private var activePreviewTask: Task<Void, Never>?
    private var iconHitViews: [WorkspaceIconHitView] = []

    init(workspace: Workspace, frame: NSRect,
         onSelect: @escaping (String) -> Void,
         onFocusWindow: @escaping (String) -> Void,
         allWorkspaceNamesProvider: @escaping () -> [String],
         onAction: @escaping (String, String, WorkspaceWindow) -> Void) {
        self.workspace = workspace
        self.onSelect = onSelect
        self.onFocusWindow = onFocusWindow
        self.allWorkspaceNamesProvider = allWorkspaceNamesProvider
        self.onAction = onAction
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Workspace \(workspace.name), \(workspace.windows.count) windows")
        installIconHitTargets()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func updateWorkspace(_ newWorkspace: Workspace) {
        guard self.workspace != newWorkspace else { return }
        self.workspace = newWorkspace
        setAccessibilityLabel("Workspace \(newWorkspace.name), \(newWorkspace.windows.count) windows")
        installIconHitTargets()
        needsDisplay = true
    }

    private var scale: CGFloat { CompanionPreferences.size / 22 }
    private var visibleGroups: [AppGroup] { Array(workspace.appGroups.prefix(3)) }

    private func iconFrames() -> [(NSRect, AppGroup)] {
        let label = CompanionPreferences.showLabels ? workspace.name : ""
        let titleFont = NSFont.systemFont(ofSize: 11 * scale, weight: .semibold)
        let titleSize = (label as NSString).size(withAttributes: [.font: titleFont])
        let labelWidth = label.isEmpty ? 0 : max(11 * scale, ceil(titleSize.width))
        var x = 7 * scale + labelWidth
        if !label.isEmpty && !visibleGroups.isEmpty { x += 5 * scale }
        var result: [(NSRect, AppGroup)] = []
        guard CompanionPreferences.showIcons else { return result }
        let iconSize = 15 * scale
        for group in visibleGroups {
            let badgeExtra: CGFloat = group.windows.count > 1 ? 5 * scale : 0
            let frame = NSRect(x: x, y: floor((bounds.height - iconSize) / 2),
                               width: iconSize + badgeExtra, height: iconSize)
            result.append((frame, group))
            x += iconSize + CompanionPreferences.iconSpacing * scale + badgeExtra
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
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

        for (frame, group) in iconFrames() {
            if let icon = AppIconCache.shared.image(for: group.bundleID, size: 15 * scale) {
                icon.draw(in: NSRect(x: frame.minX, y: frame.minY, width: 15 * scale, height: 15 * scale),
                          from: .zero, operation: .sourceOver,
                          fraction: workspace.isFocused ? 1 : CompanionPreferences.inactiveIconOpacity)
            }
            if group.windows.count > 1 {
                let badge = "\(group.windows.count)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7 * scale, weight: .bold),
                    .foregroundColor: NSColor.white
                ]
                let badgeSize = badge.size(withAttributes: attrs)
                let badgeRect = NSRect(x: frame.maxX - badgeSize.width - 1 * scale,
                                       y: frame.minY - 1 * scale,
                                       width: badgeSize.width + 2 * scale,
                                       height: badgeSize.height + 1 * scale)
                CompanionPreferences.accentColor.setFill()
                NSBezierPath(roundedRect: badgeRect, xRadius: 4 * scale, yRadius: 4 * scale).fill()
                badge.draw(in: badgeRect.insetBy(dx: 1 * scale, dy: 0), withAttributes: attrs)
            }
        }

        if workspace.appGroups.count > 3 {
            let more = "+\(workspace.appGroups.count - 3)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9 * scale, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = more.size(withAttributes: attrs)
            more.draw(in: NSRect(x: iconFrames().last?.0.maxX ?? titleRect.maxX,
                                 y: floor((bounds.height - size.height) / 2),
                                 width: size.width + 3 * scale, height: size.height),
                      withAttributes: attrs)
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

    private func installIconHitTargets() {
        iconHitViews.forEach { $0.removeFromSuperview() }
        iconHitViews.removeAll()
        for (frame, group) in iconFrames() {
            let target = WorkspaceIconHitView(frame: frame)
            target.onEnter = { [weak self] anchor in
                self?.previewDismissWorkItem?.cancel()
                self?.previewDismissWorkItem = nil
                self?.showPreview(for: group, anchoredTo: anchor)
            }
            target.onExit = { [weak self, weak target] in
                guard let self, self.previewAnchor === target else { return }
                self.schedulePreviewDismissal()
            }
            target.onPress = { [weak self] event in
                self?.activate(group, event: event)
            }
            target.onRightPress = { [weak self] event in
                self?.showWindowContextMenu(for: group, event: event)
            }
            target.setAccessibilityRole(.button)
            target.setAccessibilityLabel(group.windows.count == 1
                ? group.appName : "\(group.appName), \(group.windows.count) windows")
            addSubview(target)
            iconHitViews.append(target)
        }
    }

    private func activate(_ group: AppGroup, event: NSEvent) {
        closePreview()
        if group.windows.count == 1, let window = group.windows.first {
            onFocusWindow(window.id)
            return
        }
        let menu = NSMenu()
        for window in group.windows {
            let title = window.title.isEmpty ? group.appName : window.title
            let item = NSMenuItem(title: title, action: #selector(selectWindowFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = window.id
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showWindowContextMenu(for group: AppGroup, event: NSEvent) {
        closePreview()
        guard let window = group.windows.first else { return }
        let menu = NSMenu()

        let focusItem = NSMenuItem(title: "Focus '\(group.appName)'", action: #selector(contextFocusWindow(_:)), keyEquivalent: "")
        focusItem.target = self
        focusItem.representedObject = window.id
        menu.addItem(focusItem)

        let floatItem = NSMenuItem(title: "Toggle Floating / Tiling", action: #selector(contextToggleFloating(_:)), keyEquivalent: "")
        floatItem.target = self
        floatItem.representedObject = window.id
        menu.addItem(floatItem)

        // Submenu: Move to Workspace
        let moveMenu = NSMenu()
        for targetWS in allWorkspaceNamesProvider() where targetWS != workspace.name {
            let item = NSMenuItem(title: "Workspace \(targetWS)", action: #selector(contextMoveWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [window.id, targetWS]
            moveMenu.addItem(item)
        }
        let moveItem = NSMenuItem(title: "Move to Workspace", action: nil, keyEquivalent: "")
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)

        menu.addItem(NSMenuItem.separator())
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(contextCloseWindow(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = window.id
        menu.addItem(closeItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextFocusWindow(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { onFocusWindow(id) }
    }
    @objc private func contextToggleFloating(_ item: NSMenuItem) {
        if let id = item.representedObject as? String {
            onAction("toggleFloating", id, workspace.windows.first(where: { $0.id == id }) ?? workspace.windows[0])
        }
    }
    @objc private func contextMoveWindow(_ item: NSMenuItem) {
        if let pair = item.representedObject as? [String], pair.count == 2 {
            let (windowId, targetWS) = (pair[0], pair[1])
            onAction("move", targetWS, workspace.windows.first(where: { $0.id == windowId }) ?? workspace.windows[0])
        }
    }
    @objc private func contextCloseWindow(_ item: NSMenuItem) {
        if let id = item.representedObject as? String {
            onAction("close", id, workspace.windows.first(where: { $0.id == id }) ?? workspace.windows[0])
        }
    }

    func closePreview() {
        activePreviewTask?.cancel()
        activePreviewTask = nil
        previewDismissWorkItem?.cancel()
        previewDismissWorkItem = nil
        previewPopover?.close()
        previewPopover = nil
        previewAnchor = nil
    }

    private func schedulePreviewDismissal() {
        previewDismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewDismissWorkItem = nil
            let pointer = NSEvent.mouseLocation
            if let popWindow = self.previewPopover?.contentViewController?.view.window,
               popWindow.frame.contains(pointer) {
                return
            }
            self.closePreview()
        }
        previewDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func showPreview(for group: AppGroup, anchoredTo anchor: NSView) {
        closePreview()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        let controller = NSViewController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 156))
        host.wantsLayer = true
        host.layer?.cornerRadius = 10

        let imageView = NSImageView(frame: NSRect(x: 12, y: 38, width: 208, height: 106))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = AppIconCache.shared.image(for: group.bundleID, size: 48)
        host.addSubview(imageView)

        let title = NSTextField(labelWithString: group.windows[0].title)
        title.frame = NSRect(x: 12, y: 10, width: 208, height: 20)
        title.lineBreakMode = .byTruncatingMiddle
        title.font = .systemFont(ofSize: 11, weight: .medium)
        host.addSubview(title)

        if group.windows.count > 1 {
            let count = NSTextField(labelWithString: "\(group.windows.count) windows — click to choose")
            count.frame = NSRect(x: 12, y: 26, width: 208, height: 12)
            count.font = .systemFont(ofSize: 9)
            count.textColor = .secondaryLabelColor
            host.addSubview(count)
        }

        controller.view = host
        popover.contentViewController = controller
        popover.show(relativeTo: NSRect(x: anchor.bounds.midX - 2, y: anchor.bounds.midY, width: 4, height: 2),
                     of: anchor, preferredEdge: .maxY)
        previewAnchor = anchor
        previewPopover = popover

        // Asynchronously capture thumbnail with strict Task cancellation
        activePreviewTask = Task { @MainActor [weak imageView] in
            guard let imageView else { return }
            let window = group.windows[0]
            guard let image = await WindowPreviewSource.shared.capture(window),
                  !Task.isCancelled else { return }
            imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        closePreview()
        onSelect(workspace.name)
    }

    @objc private func selectWindowFromMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        onFocusWindow(id)
    }
}

// MARK: - Reusable Background Views

@MainActor
private final class PassthroughGlassEffectView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class CompartmentBackgroundView: NSView {
    private var focusedState: Bool
    private var backgroundStyle: CompanionPreferences.Background

    init(frame: NSRect, focused: Bool, style: CompanionPreferences.Background) {
        self.focusedState = focused
        self.backgroundStyle = style
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(focused: Bool, style: CompanionPreferences.Background) {
        guard self.focusedState != focused || self.backgroundStyle != style else { return }
        self.focusedState = focused
        self.backgroundStyle = style
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 9 * CompanionPreferences.size / 22,
                                yRadius: 9 * CompanionPreferences.size / 22)
        if backgroundStyle == .solid {
            (focusedState ? CompanionPreferences.accentColor.withAlphaComponent(min(1, CompanionPreferences.backgroundOpacity + 0.08))
                          : NSColor.controlBackgroundColor.withAlphaComponent(CompanionPreferences.backgroundOpacity)).setFill()
            path.fill()
        }
        if focusedState {
            CompanionPreferences.accentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - Workspace Strip View (Diff-based, Zero-flicker View Pool)

@MainActor
private final class WorkspaceStripView: NSView {
    private var workspaces: [Workspace] = []
    private var activeMode: String = "main"
    var contextMenu: NSMenu?

    private var contentHost: NSView
    private var compartmentViews: [String: WorkspaceContentView] = [:]
    private var backgroundViews: [String: NSView] = [:]
    private var modeBadgeButton: NSButton?

    override init(frame frameRect: NSRect) {
        contentHost = NSView(frame: frameRect)
        super.init(frame: frameRect)
        addSubview(contentHost)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: measuredWidth, height: CompanionPreferences.size)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenu else { return }
        NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
    }

    private var gap: CGFloat { CompanionPreferences.workspaceSpacing * CompanionPreferences.size / 22 }

    private var modeBadgeWidth: CGFloat {
        guard CompanionPreferences.showModeBadge, activeMode != "main", !activeMode.isEmpty else { return 0 }
        return 65 * (CompanionPreferences.size / 22)
    }

    private var measuredWidth: CGFloat {
        let base = workspaces.reduce(0) { $0 + compartmentWidth(for: $1) }
            + CGFloat(max(0, workspaces.count - 1)) * gap + 4
        return base + (modeBadgeWidth > 0 ? modeBadgeWidth + gap : 0)
    }

    func compartmentWidth(for workspace: Workspace) -> CGFloat {
        let scale = CompanionPreferences.size / 22
        let label = CompanionPreferences.showLabels ? workspace.name : ""
        let font = NSFont.systemFont(ofSize: 11 * scale, weight: .semibold)
        let labelWidth = label.isEmpty ? 0 : max(11 * scale, ceil((label as NSString).size(withAttributes: [.font: font]).width))
        var width = 14 * scale + labelWidth
        if CompanionPreferences.showIcons && !workspace.appGroups.isEmpty {
            let visible = min(3, workspace.appGroups.count)
            width += 5 * scale + CGFloat(visible) * 15 * scale
                + CGFloat(max(0, visible - 1)) * CompanionPreferences.iconSpacing * scale
                + CGFloat(workspace.appGroups.prefix(visible).filter { $0.windows.count > 1 }.count) * 5 * scale
            if workspace.appGroups.count > 3 {
                let more = "+\(workspace.appGroups.count - 3)" as NSString
                width += 5 * scale + ceil(more.size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9 * scale, weight: .medium)
                ]).width)
            }
        }
        if !workspace.windows.isEmpty { width = max(width, 44 * scale) }
        return ceil(max(24 * scale, width))
    }

    func update(workspaces: [Workspace],
                mode: String,
                onSelect: @escaping (String) -> Void,
                onFocusWindow: @escaping (String) -> Void,
                onAction: @escaping (String, String, WorkspaceWindow) -> Void,
                onResetMode: @escaping () -> Void) {
        self.workspaces = CompanionPreferences.occupiedOnly
            ? workspaces.filter { !$0.windows.isEmpty || $0.isFocused }
            : workspaces
        self.activeMode = mode

        let height = CompanionPreferences.size
        let scale = height / 22
        var x: CGFloat = 2

        // Optional Mode Badge (Feature 1: Visual Mode Indicator)
        if modeBadgeWidth > 0 {
            let badgeFrame = NSRect(x: x, y: 0, width: modeBadgeWidth, height: height)
            if modeBadgeButton == nil {
                let btn = NSButton(frame: badgeFrame)
                btn.bezelStyle = .inline
                btn.isBordered = false
                btn.wantsLayer = true
                btn.layer?.cornerRadius = 6 * scale
                btn.target = self
                btn.action = #selector(modeBadgeClicked)
                contentHost.addSubview(btn)
                modeBadgeButton = btn
            }
            modeBadgeButton?.frame = badgeFrame
            modeBadgeButton?.title = activeMode.uppercased()
            modeBadgeButton?.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.85).cgColor
            modeBadgeButton?.attributedTitle = NSAttributedString(
                string: activeMode.uppercased(),
                attributes: [.foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 9 * scale)]
            )
            modeBadgeButton?.isHidden = false
            x += modeBadgeWidth + gap
        } else {
            modeBadgeButton?.isHidden = true
        }

        // View Diffing & Recycling: Update existing views in place
        let currentKeys = Set(self.workspaces.map { $0.name })
        for (name, view) in compartmentViews where !currentKeys.contains(name) {
            view.closePreview()
            view.removeFromSuperview()
            compartmentViews.removeValue(forKey: name)
            backgroundViews[name]?.removeFromSuperview()
            backgroundViews.removeValue(forKey: name)
        }

        let allNames = self.workspaces.map { $0.name }

        for ws in self.workspaces {
            let width = compartmentWidth(for: ws)
            let frame = NSRect(x: x, y: 0, width: width, height: height)

            // Update or create Background
            let bg: NSView
            if let existingBg = backgroundViews[ws.name] {
                existingBg.frame = frame
                if let glass = existingBg as? PassthroughGlassEffectView {
                    glass.cornerRadius = 9 * scale
                    glass.tintColor = ws.isFocused
                        ? CompanionPreferences.accentColor.withAlphaComponent(0.22 * CompanionPreferences.backgroundOpacity)
                        : NSColor.controlBackgroundColor.withAlphaComponent(0.08 * CompanionPreferences.backgroundOpacity)
                } else if let solid = existingBg as? CompartmentBackgroundView {
                    solid.update(focused: ws.isFocused, style: CompanionPreferences.background)
                }
                bg = existingBg
            } else {
                if CompanionPreferences.background == .glass {
                    let glass = PassthroughGlassEffectView(frame: frame)
                    glass.cornerRadius = 9 * scale
                    glass.tintColor = ws.isFocused
                        ? CompanionPreferences.accentColor.withAlphaComponent(0.22 * CompanionPreferences.backgroundOpacity)
                        : NSColor.controlBackgroundColor.withAlphaComponent(0.08 * CompanionPreferences.backgroundOpacity)
                    bg = glass
                } else {
                    bg = CompartmentBackgroundView(frame: frame, focused: ws.isFocused, style: CompanionPreferences.background)
                }
                contentHost.addSubview(bg)
                backgroundViews[ws.name] = bg
            }

            // Update or create Content View
            if let existingContent = compartmentViews[ws.name] {
                existingContent.frame = frame
                existingContent.updateWorkspace(ws)
            } else {
                let content = WorkspaceContentView(
                    workspace: ws,
                    frame: frame,
                    onSelect: onSelect,
                    onFocusWindow: onFocusWindow,
                    allWorkspaceNamesProvider: { allNames },
                    onAction: onAction
                )
                contentHost.addSubview(content)
                compartmentViews[ws.name] = content
            }

            x += width + gap
        }

        contentHost.frame = NSRect(x: 0, y: 0, width: measuredWidth, height: height)
        invalidateIntrinsicContentSize()
    }

    @objc private func modeBadgeClicked() {
        NotificationCenter.default.post(name: .resetAeroSpaceMode, object: nil)
    }
}

private extension Notification.Name {
    static let resetAeroSpaceMode = Notification.Name("ResetAeroSpaceMode")
}

// MARK: - System Stats Popover Controller

@MainActor
private final class SystemStatsPopoverController: NSObject {
    private let popover = NSPopover()
    private let cpuLabel = NSTextField(labelWithString: "CPU: measuring…")
    private let memoryLabel = NSTextField(labelWithString: "Memory: measuring…")
    private let footprintLabel = NSTextField(labelWithString: "Companion: measuring…")

    func show(from anchor: NSView?) {
        guard let anchor else { return }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 100))
        for (label, y) in [(cpuLabel, 66.0), (memoryLabel, 40.0), (footprintLabel, 14.0)] {
            label.frame = NSRect(x: 14, y: y, width: 192, height: 18)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            host.addSubview(label)
        }
        let content = NSViewController()
        content.view = host
        popover.contentViewController = content
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        refreshMemory()
        measureCPU()
        measureFootprint()
    }

    private func refreshMemory() {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { memoryLabel.stringValue = "Memory: unavailable"; return }
        let page = UInt64(vm_kernel_page_size)
        let usedPages = UInt64(stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count)
        let used = min(total, usedPages * page)
        memoryLabel.stringValue = String(format: "Memory: %.1f / %.1f GB", Double(used) / 1_073_741_824,
                                         Double(total) / 1_073_741_824)
    }

    private func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    private func measureCPU() {
        guard let first = cpuTicks() else { cpuLabel.stringValue = "CPU: unavailable"; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let second = self.cpuTicks() else { return }
            let deltas = zip(first, second).map { Double($1 &- $0) }
            let total = deltas.reduce(0, +)
            let idle = deltas[3]
            let usage = total > 0 ? (total - idle) / total * 100 : 0
            self.cpuLabel.stringValue = String(format: "CPU: %.1f%% system", usage)
        }
    }

    private func measureFootprint() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            footprintLabel.stringValue = String(format: "Companion: %.1f MB", Double(info.phys_footprint) / 1_048_576)
        } else {
            footprintLabel.stringValue = "Companion: unavailable"
        }
    }
}

// MARK: - App Delegate & Coordinator

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = AeroSpaceClient()
    private var statusItem: NSStatusItem?
    private var strip: WorkspaceStripView?
    private var statsPopoverController: SystemStatsPopoverController?
    private var stripHeightConstraint: NSLayoutConstraint?
    private var eventProcess: Process?
    private var eventPipe: Pipe?
    private var eventBuffer = ""
    private var reconnectWorkItem: DispatchWorkItem?
    private var refreshWorkItem: DispatchWorkItem?
    private var currentWorkspaces: [Workspace] = []
    private var currentMode: String = "main"
    private var isRefreshing = false
    private var refreshPending = false
    private var isStopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: 1)
        item.autosaveName = "com.m-robot404.Companion.workspaceStrip"
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
        NotificationCenter.default.addObserver(self, selector: #selector(resetModeNotification),
                                               name: .resetAeroSpaceMode, object: nil)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationLifecycleChanged(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationLifecycleChanged(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        refresh()
        startEventStream()
    }

    @objc private func resetModeNotification() {
        let client = self.client
        DispatchQueue.global(qos: .userInteractive).async { client.resetMode() }
        currentMode = "main"
        renderWorkspaces()
    }

    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func showSystemStats() {
        let controller = SystemStatsPopoverController()
        statsPopoverController = controller
        controller.show(from: statusItem?.button)
    }
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

        let spacingMenu = NSMenu()
        for value in [2, 3, 4, 5, 6, 8, 10] {
            addChoice("\(value) pt", key: "workspaceSpacing", value: "\(value)",
                      selected: Int(CompanionPreferences.workspaceSpacing) == value, to: spacingMenu)
        }
        let spacingItem = NSMenuItem(title: "Workspace Spacing", action: nil, keyEquivalent: "")
        spacingItem.submenu = spacingMenu
        menu.addItem(spacingItem)

        let iconSpacingMenu = NSMenu()
        for value in [1, 2, 3, 4, 5, 6, 8] {
            addChoice("\(value) pt", key: "iconSpacing", value: "\(value)",
                      selected: Int(CompanionPreferences.iconSpacing) == value, to: iconSpacingMenu)
        }
        let iconSpacingItem = NSMenuItem(title: "App Icon Spacing", action: nil, keyEquivalent: "")
        iconSpacingItem.submenu = iconSpacingMenu
        menu.addItem(iconSpacingItem)

        let opacityMenu = NSMenu()
        for value in [45, 60, 75, 82, 90, 100] {
            addChoice("\(value)%", key: "inactiveIconOpacity", value: String(Double(value) / 100),
                      selected: Int(CompanionPreferences.inactiveIconOpacity * 100) == value, to: opacityMenu)
        }
        let opacityItem = NSMenuItem(title: "Inactive Icon Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        let backgroundOpacityMenu = NSMenu()
        for value in [10, 20, 35, 50, 65, 80, 92, 100] {
            addChoice("\(value)%", key: "backgroundOpacity", value: String(Double(value) / 100),
                      selected: Int(CompanionPreferences.backgroundOpacity * 100) == value, to: backgroundOpacityMenu)
        }
        let backgroundOpacityItem = NSMenuItem(title: "Background Opacity", action: nil, keyEquivalent: "")
        backgroundOpacityItem.submenu = backgroundOpacityMenu
        menu.addItem(backgroundOpacityItem)

        menu.addItem(NSMenuItem.separator())
        let statsItem = NSMenuItem(title: "System Stats…", action: #selector(showSystemStats), keyEquivalent: "")
        statsItem.target = self
        menu.addItem(statsItem)

        let toggleLayoutItem = NSMenuItem(title: "Toggle Layout (Tiles / Accordion)", action: #selector(toggleFocusedWorkspaceLayout), keyEquivalent: "")
        toggleLayoutItem.target = self
        menu.addItem(toggleLayoutItem)

        let notchInfo = NSMenuItem(title: "Engine: Unix Domain Socket (Zero-Fork)", action: nil, keyEquivalent: "")
        notchInfo.isEnabled = false
        menu.addItem(notchInfo)
        menu.addItem(NSMenuItem.separator())

        func addToggle(_ title: String, key: String, value: Bool) {
            let item = NSMenuItem(title: title, action: #selector(menuToggleChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = value ? .on : .off
            menu.addItem(item)
        }

        addToggle("Show only occupied workspaces", key: "occupiedOnly", value: CompanionPreferences.occupiedOnly)
        addToggle("Show only current display's workspaces", key: "currentDisplayOnly", value: CompanionPreferences.currentDisplayOnly)
        addToggle("Show binding mode badge", key: "showModeBadge", value: CompanionPreferences.showModeBadge)
        addToggle("Show app icons", key: "showIcons", value: CompanionPreferences.showIcons)
        addToggle("Show workspace labels", key: "showLabels", value: CompanionPreferences.showLabels)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "About Companion", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Companion", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func toggleFocusedWorkspaceLayout() {
        guard let focusedWS = currentWorkspaces.first(where: { $0.isFocused }) else { return }
        let client = self.client
        DispatchQueue.global(qos: .userInteractive).async { client.toggleWorkspaceLayout(workspace: focusedWS.name) }
    }

    @objc private func menuChoiceChanged(_ item: NSMenuItem) {
        guard let values = item.representedObject as? [String], values.count == 2 else { return }
        let value: Any
        if ["stripSize", "workspaceSpacing", "iconSpacing", "inactiveIconOpacity", "backgroundOpacity"].contains(values[0]) {
            value = Double(values[1]) ?? 22
        } else { value = values[1] }
        CompanionPreferences.save(values[0], value)
        strip?.contextMenu = makeContextMenu()
    }

    @objc private func menuToggleChanged(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        CompanionPreferences.save(key, item.state != .on)
        strip?.contextMenu = makeContextMenu()
        scheduleRefresh()
    }

    @objc private func preferencesChanged() {
        stripHeightConstraint?.constant = CompanionPreferences.size
        renderWorkspaces()
    }

    @objc private func applicationLifecycleChanged(_ notification: Notification) { scheduleRefresh() }

    private func renderWorkspaces() {
        let client = self.client
        strip?.update(
            workspaces: currentWorkspaces,
            mode: currentMode,
            onSelect: { [weak self] name in
                guard let self else { return }
                DispatchQueue.global(qos: .userInteractive).async { client.focus(name) }
                self.scheduleRefresh()
            },
            onFocusWindow: { [weak self] id in
                guard let self else { return }
                DispatchQueue.global(qos: .userInteractive).async { client.focusWindow(id) }
                self.scheduleRefresh()
            },
            onAction: { [weak self] action, target, window in
                guard let self else { return }
                DispatchQueue.global(qos: .userInteractive).async {
                    switch action {
                    case "close": client.closeWindow(window.id)
                    case "move": client.moveWindow(window.id, toWorkspace: target)
                    case "toggleFloating": client.toggleFloating(windowId: window.id)
                    default: break
                    }
                }
                self.scheduleRefresh()
            },
            onResetMode: { [weak self] in
                self?.resetModeNotification()
            }
        )
        statusItem?.length = max(1, ceil(strip?.intrinsicContentSize.width ?? 1))
    }

    private func refresh() {
        guard !isRefreshing else { refreshPending = true; return }
        isRefreshing = true
        let currentDisplayOnly = CompanionPreferences.currentDisplayOnly
        let client = self.client

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let latest = client.snapshot(currentDisplayOnly: currentDisplayOnly)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
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

            if event == "mode-changed" {
                if let mode = object["mode"] as? String {
                    self.currentMode = mode
                    self.renderWorkspaces()
                }
            } else if ["focus-changed", "focused-workspace-changed", "focused-monitor-changed", "window-detected"].contains(event) {
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

// MARK: - Entry Point

@main
private enum CompanionApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
