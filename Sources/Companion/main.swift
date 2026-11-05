import AppKit
import CoreGraphics
import Darwin
import ScreenCaptureKit
import ServiceManagement


// MARK: - Crash recording
// Writes a compact crash marker to ~/Library/Logs/Companion/crash.log.
// macOS DiagnosticReports remain the source for full native crash stacks.
private enum CrashRecorder {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Companion", isDirectory: true)
    static let logURL = directory.appendingPathComponent("crash.log")

    static func install() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
               let size = attributes[.size] as? NSNumber, size.intValue > 512 * 1024 {
                try FileManager.default.removeItem(at: logURL)
            }
            let descriptor = Darwin.open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return }
            crashLogDescriptor = descriptor
            append("Session started: \(ISO8601DateFormatter().string(from: Date()))\n")
            NSSetUncaughtExceptionHandler(companionExceptionHandler)
            signal(SIGABRT, companionSignalHandler)
            signal(SIGILL, companionSignalHandler)
            signal(SIGSEGV, companionSignalHandler)
            signal(SIGBUS, companionSignalHandler)
            signal(SIGFPE, companionSignalHandler)
            signal(SIGTRAP, companionSignalHandler)
        } catch {
            NSLog("Companion: could not initialize crash recording: %@", error.localizedDescription)
        }
    }

    static func append(_ message: String) {
        guard crashLogDescriptor >= 0 else { return }
        let data = Data(message.utf8)
        data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { _ = Darwin.write(crashLogDescriptor, base, bytes.count) }
        }
    }

    static func record(_ exception: NSException) {
        let stack = exception.callStackSymbols.joined(separator: "\n")
        append("\nUNCAUGHT EXCEPTION: \(exception.name.rawValue)\nReason: \(exception.reason ?? "unknown")\n\(stack)\n")
    }
}

private var crashLogDescriptor: Int32 = -1
private let sigabrtMessage = Array("FATAL SIGNAL: SIGABRT\n".utf8CString)
private let sigillMessage = Array("FATAL SIGNAL: SIGILL\n".utf8CString)
private let sigsegvMessage = Array("FATAL SIGNAL: SIGSEGV\n".utf8CString)
private let sigbusMessage = Array("FATAL SIGNAL: SIGBUS\n".utf8CString)
private let sigfpeMessage = Array("FATAL SIGNAL: SIGFPE\n".utf8CString)
private let sigtrapMessage = Array("FATAL SIGNAL: SIGTRAP\n".utf8CString)

private func companionExceptionHandler(_ exception: NSException) {
    CrashRecorder.record(exception)
}

private func companionSignalHandler(_ signalNumber: Int32) {
    let message: [CChar]
    switch signalNumber {
    case SIGABRT: message = sigabrtMessage
    case SIGILL: message = sigillMessage
    case SIGSEGV: message = sigsegvMessage
    case SIGBUS: message = sigbusMessage
    case SIGFPE: message = sigfpeMessage
    case SIGTRAP: message = sigtrapMessage
    default: message = sigabrtMessage
    }
    if crashLogDescriptor >= 0 {
        message.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                _ = Darwin.write(crashLogDescriptor, base, buffer.count - 1)
            }
        }
    }
    Darwin.signal(signalNumber, SIG_DFL)
    Darwin.raise(signalNumber)
}

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

private struct WorkspaceWindow: Equatable {
    let id: String
    let bundleID: String
    let appName: String
    let title: String
}

private struct AppGroup: Equatable {
    let bundleID: String
    let appName: String
    let windows: [WorkspaceWindow]
}

private struct Workspace: Equatable {
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
        let group = DispatchGroup()
        let resultLock = NSLock()
        var workspaceText: String?
        var windowText: String?
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let value = self.run(["list-workspaces", "--all", "--format", "%{workspace}|%{workspace-is-focused}"])
            resultLock.lock(); workspaceText = value; resultLock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let value = self.run(["list-windows", "--all", "--format",
                                  "%{window-id}%{tab}%{app-bundle-id}%{tab}%{app-name}%{tab}%{window-title}%{tab}%{workspace}"])
            resultLock.lock(); windowText = value; resultLock.unlock()
            group.leave()
        }
        group.wait()
        guard let workspaceText, let windowText else { return nil }

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

    func focus(_ workspace: String) { _ = run(["workspace", workspace]) }
    func focusWindow(_ id: String) { _ = run(["focus", "--window-id", id]) }

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
        // These icons belong to apps with live AeroSpace windows. Read the
        // already-running application's icon directly instead of performing a
        // synchronous LaunchServices URL lookup during menu-bar drawing.
        guard let image = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
        else { return nil }
        image.size = NSSize(width: size, height: size)
        cache.setObject(image, forKey: key)
        return image
    }
}


@MainActor
private final class WorkspaceIconHitView: NSView {
    var onEnter: ((NSView) -> Void)?
    var onExit: (() -> Void)?
    var onPress: ((NSEvent) -> Void)?
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
}

/// ScreenCaptureKit source modeled on the on-demand, cached capture pipeline used by
/// the open-source HoverDock project (MIT): reuse the shareable-window map briefly and
/// keep a small in-memory thumbnail cache instead of querying ScreenCaptureKit per hover.
private actor WindowPreviewSource {
    static let shared = WindowPreviewSource()
    private var windowsByID: [CGWindowID: SCWindow] = [:]
    private var refreshedAt = Date.distantPast
    private var thumbnails: [CGWindowID: CGImage] = [:]
    private var thumbnailDates: [CGWindowID: Date] = [:]
    private var thumbnailOrder: [CGWindowID] = []
    private let cacheLimit = 12
    private let thumbnailFreshness: TimeInterval = 2.5

    private func refreshWindowMap() async {
        guard Date().timeIntervalSince(refreshedAt) >= 1 || windowsByID.isEmpty else { return }
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
        await refreshWindowMap()

        // Prefer AeroSpace's exact CGWindowID. If ScreenCaptureKit's map is temporarily
        // out of sync, use a unique bundle-ID + title match; never guess between windows.
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
        if let cached = thumbnails[id],
           let capturedAt = thumbnailDates[id],
           Date().timeIntervalSince(capturedAt) < thumbnailFreshness {
            return cached
        }

        let sourceWidth = max(1, target.frame.width)
        let sourceHeight = max(1, target.frame.height)
        // Small menu-bar previews do not need retina-sized captures. A strict 240×135
        // cap and 12-entry LRU bound keep capture and retained image memory low.
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
            thumbnailDates[id] = Date()
            thumbnailOrder.removeAll { $0 == id }
            thumbnailOrder.append(id)
            while thumbnailOrder.count > cacheLimit {
                let evicted = thumbnailOrder.removeFirst()
                thumbnails[evicted] = nil
                thumbnailDates[evicted] = nil
            }
            return image
        } catch {
            return nil
        }
    }
}

@MainActor
private final class WorkspaceContentView: NSView {
    var workspace: Workspace
    let onSelect: (String) -> Void
    let onFocusWindow: (String) -> Void
    private var previewPanel: NSPanel?
    private weak var previewAnchor: NSView?
    private weak var previewImageView: NSImageView?
    private var previewTask: Task<Void, Never>?
    private var iconHitViews: [WorkspaceIconHitView] = []

    init(workspace: Workspace, frame: NSRect,
         onSelect: @escaping (String) -> Void,
         onFocusWindow: @escaping (String) -> Void) {
        self.workspace = workspace
        self.onSelect = onSelect
        self.onFocusWindow = onFocusWindow
        super.init(frame: frame)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Workspace \(workspace.name), \(workspace.windows.count) windows")
        refreshIconHitTargets()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateWorkspace(_ updated: Workspace) {
        workspace = updated
        refreshIconHitTargets()
        setAccessibilityLabel("Workspace \(updated.name), \(updated.windows.count) windows")
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

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

    private func refreshIconHitTargets() {
        let items = iconFrames()
        if iconHitViews.count > items.count {
            for target in iconHitViews.suffix(iconHitViews.count - items.count) {
                target.removeFromSuperview()
            }
            iconHitViews.removeLast(iconHitViews.count - items.count)
        }

        for (index, item) in items.enumerated() {
            let (frame, group) = item
            let target: WorkspaceIconHitView
            if index < iconHitViews.count {
                target = iconHitViews[index]
                target.frame = frame
            } else {
                target = WorkspaceIconHitView(frame: frame)
                addSubview(target)
                iconHitViews.append(target)
            }

            // Rebind the latest group data without replacing the tracking view.
            // Recreating a tracking view under a stationary pointer emits exit/enter
            // events and makes the preview repeatedly close and reopen.
            target.onEnter = { [weak self] anchor in
                self?.showPreview(for: group, anchoredTo: anchor)
            }
            target.onExit = { [weak self, weak target] in
                guard let self, self.previewAnchor === target else { return }
                self.hidePreview()
            }
            target.onPress = { [weak self] event in
                self?.activate(group, event: event)
            }
            target.setAccessibilityRole(.button)
            target.setAccessibilityLabel(group.windows.count == 1
                ? group.appName : "\(group.appName), \(group.windows.count) windows")
        }
    }

    private func activate(_ group: AppGroup, event: NSEvent) {
        hidePreview()
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

    private func showPreview(for group: AppGroup, anchoredTo anchor: NSView) {
        guard let window = group.windows.first else { return }
        if previewAnchor === anchor, previewPanel?.isVisible == true { return }
        hidePreview()

        // A mouse-transparent panel avoids NSPopover's tracking/close cycle at
        // the lower edge of the menu bar. It never participates in hover hit-testing.
        let width: CGFloat = 232
        let height: CGFloat = 156
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true

        let imageView = NSImageView(frame: NSRect(x: 12, y: 38, width: 208, height: 106))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = AppIconCache.shared.image(for: group.bundleID, size: 64)
        host.addSubview(imageView)

        let title = NSTextField(labelWithString: window.title.isEmpty ? group.appName : window.title)
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

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host

        if let window = anchor.window {
            let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            panel.setFrameOrigin(NSPoint(x: anchorRect.midX - width / 2,
                                         y: anchorRect.minY - height - 4))
        }

        previewAnchor = anchor
        previewImageView = imageView
        previewPanel = panel
        panel.orderFrontRegardless()

        // Show the cached app icon immediately; capture and replace it asynchronously.
        previewTask = Task { @MainActor [weak self, weak imageView, weak anchor] in
            guard let self, let imageView, let anchor,
                  let captured = await self.previewImage(for: window),
                  !Task.isCancelled, self.previewAnchor === anchor else { return }
            imageView.image = captured
        }
    }

    private func hidePreview() {
        previewTask?.cancel()
        previewTask = nil
        previewPanel?.orderOut(nil)
        previewPanel = nil
        previewImageView = nil
        previewAnchor = nil
    }

    private func previewImage(for window: WorkspaceWindow) async -> NSImage? {
        guard let image = await WindowPreviewSource.shared.capture(window) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    override func mouseDown(with event: NSEvent) {
        hidePreview()
        onSelect(workspace.name)
    }

    @objc private func selectWindowFromMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        onFocusWindow(id)
    }
}

@MainActor
private final class WorkspaceStripView: NSView {
    private var workspaces: [Workspace] = []
    private var selection: ((String) -> Void)?
    private var focusWindow: ((String) -> Void)?
    private var contentViews: [WorkspaceContentView] = []
    private var workspaceBackgrounds: [NSView] = []
    private var renderedWorkspaces: [Workspace] = []
    private var railBase: RailBaseView?
    private var forceLayoutRebuild = false
    var contextMenu: NSMenu?

    func invalidateWorkspaceLayout() { forceLayoutRebuild = true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: measuredWidth, height: CompanionPreferences.size)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenu else { return }
        NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
    }

    private var gap: CGFloat { max(5, CompanionPreferences.workspaceSpacing * CompanionPreferences.size / 22) }

    private var measuredWidth: CGFloat {
        guard !workspaces.isEmpty else { return 1 }
        return workspaces.reduce(0) { $0 + compartmentWidth(for: $1) }
            + CGFloat(max(0, workspaces.count - 1)) * gap + 12
    }

    private func compartmentWidth(for workspace: Workspace) -> CGFloat {
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
        if !workspace.windows.isEmpty { width = max(width, 36 * scale) }
        return ceil(max(22 * scale, width))
    }

    func update(workspaces: [Workspace], onSelect: @escaping (String) -> Void,
                onFocusWindow: @escaping (String) -> Void) {
        self.workspaces = CompanionPreferences.occupiedOnly
            ? workspaces.filter { !$0.windows.isEmpty || $0.isFocused }
            : workspaces
        selection = onSelect
        focusWindow = onFocusWindow

        let sameStructure = !forceLayoutRebuild &&
            renderedWorkspaces.count == self.workspaces.count &&
            renderedWorkspaces.map(\.name) == self.workspaces.map(\.name)
        if sameStructure && contentViews.count == self.workspaces.count {
            let height = CompanionPreferences.size
            let scale = height / 22
            var x: CGFloat = 6
            var geometryChanged = false
            for index in self.workspaces.indices {
                let workspace = self.workspaces[index]
                let frame = NSRect(x: x, y: 0, width: compartmentWidth(for: workspace), height: height)
                if contentViews[index].frame != frame {
                    contentViews[index].frame = frame
                    workspaceBackgrounds[index].frame = frame
                    geometryChanged = true
                }
                if renderedWorkspaces[index] != workspace {
                    contentViews[index].updateWorkspace(workspace)
                    if let background = workspaceBackgrounds[index] as? CompartmentBackgroundView {
                        background.updateFocus(workspace.isFocused)
                    }
                }
                x += frame.width + gap
            }
            let railFrame = NSRect(x: 0, y: 3 * scale,
                                   width: measuredWidth, height: height - 6 * scale)
            if let railBase, railBase.frame != railFrame {
                railBase.frame = railFrame
                geometryChanged = true
            }
            let widthChanged = renderedWorkspaces.isEmpty ||
                renderedWorkspaces.reduce(0) { $0 + compartmentWidth(for: $1) } !=
                self.workspaces.reduce(0) { $0 + compartmentWidth(for: $1) }
            renderedWorkspaces = self.workspaces
            forceLayoutRebuild = false
            if widthChanged { invalidateIntrinsicContentSize() }
            if geometryChanged { needsDisplay = true }
            return
        }

        forceLayoutRebuild = false
        subviews.forEach { $0.removeFromSuperview() }
        contentViews.removeAll()
        workspaceBackgrounds.removeAll()
        railBase = nil

        let height = CompanionPreferences.size
        let scale = height / 22
        let base = RailBaseView(frame: NSRect(x: 0, y: 3 * scale,
                                               width: measuredWidth, height: height - 6 * scale))
        addSubview(base, positioned: .below, relativeTo: nil)
        railBase = base

        var x: CGFloat = 6
        for workspace in self.workspaces {
            let frame = NSRect(x: x, y: 0, width: compartmentWidth(for: workspace), height: height)
            let content = WorkspaceContentView(workspace: workspace, frame: frame,
                                                onSelect: onSelect,
                                                onFocusWindow: { [weak self] id in self?.focusWindow?(id) })
            let background: NSView
            background = CompartmentBackgroundView(frame: frame, focused: workspace.isFocused,
                                                   style: CompanionPreferences.background)
            // Each island is an independent sibling over the continuous rail.
            // Its background never owns hit testing; only its own icon targets do.
            addSubview(background)
            addSubview(content)
            contentViews.append(content)
            workspaceBackgrounds.append(background)
            x += frame.width + gap
        }

        renderedWorkspaces = self.workspaces
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

@MainActor
private final class RailBaseView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.controlBackgroundColor.withAlphaComponent(0.18).setFill()
        path.fill()
    }
}

@MainActor
private final class PassthroughGlassEffectView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class CompartmentBackgroundView: NSView {
    private var focused: Bool
    private let style: CompanionPreferences.Background
    init(frame: NSRect, focused: Bool, style: CompanionPreferences.Background) {
        self.focused = focused
        self.style = style
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateFocus(_ value: Bool) {
        guard focused != value else { return }
        focused = value
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 9 * CompanionPreferences.size / 22,
                                yRadius: 9 * CompanionPreferences.size / 22)
        switch style {
        case .glass:
            (focused ? CompanionPreferences.accentColor.withAlphaComponent(0.22 * CompanionPreferences.backgroundOpacity)
                     : NSColor.controlBackgroundColor.withAlphaComponent(0.08 * CompanionPreferences.backgroundOpacity)).setFill()
            path.fill()
        case .solid:
            (focused ? CompanionPreferences.accentColor.withAlphaComponent(min(1, CompanionPreferences.backgroundOpacity + 0.08))
                     : NSColor.controlBackgroundColor.withAlphaComponent(CompanionPreferences.backgroundOpacity)).setFill()
            path.fill()
        case .transparent:
            break
        }
        if focused {
            CompanionPreferences.accentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}


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

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let client = AeroSpaceClient()
    private var statusItem: NSStatusItem?
    private weak var openAtLoginItem: NSMenuItem?
    private var strip: WorkspaceStripView?
    private var statsPopoverController: SystemStatsPopoverController?
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
        CrashRecorder.install()
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: 1)
        item.autosaveName = "com.m-robot404.Companion.workspaceStrip"
        statusItem = item
        guard let button = item.button else { return }
        button.title = ""
        button.image = nil
        button.isBordered = false
        button.focusRingType = .none
        (button.cell as? NSButtonCell)?.highlightsBy = []

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
    @objc private func showSystemStats() {
        let controller = SystemStatsPopoverController()
        statsPopoverController = controller
        controller.show(from: statusItem?.button)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        openAtLoginItem = loginItem
        menu.addItem(loginItem)

        let logsItem = NSMenuItem(title: "Open Crash Logs", action: #selector(openCrashLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Companion", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        openAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            openAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc private func openCrashLogs() {
        do {
            try FileManager.default.createDirectory(at: CrashRecorder.directory,
                                                    withIntermediateDirectories: true)
            NSWorkspace.shared.open(CrashRecorder.directory)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc private func preferencesChanged() {
        stripHeightConstraint?.constant = CompanionPreferences.size
        strip?.invalidateWorkspaceLayout()
        renderWorkspaces()
    }

    @objc private func applicationLifecycleChanged(_ notification: Notification) { scheduleRefresh() }

    private func renderWorkspaces() {
        strip?.update(workspaces: currentWorkspaces, onSelect: { [weak self] name in
            guard let self else { return }
            DispatchQueue.global(qos: .userInteractive).async { [client = self.client] in client.focus(name) }
            self.scheduleRefresh()
        }, onFocusWindow: { [weak self] id in
            guard let self else { return }
            DispatchQueue.global(qos: .userInteractive).async { [client = self.client] in client.focusWindow(id) }
            self.scheduleRefresh()
        })
        let desiredLength = max(1, ceil(strip?.intrinsicContentSize.width ?? 1))
        if statusItem?.length != desiredLength { statusItem?.length = desiredLength }
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
                // Closing a window can race AeroSpace's window-tree cleanup.
                // Re-read after the close settles so stale app icons disappear.
                if event == "focus-changed" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.scheduleRefresh()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                        self?.scheduleRefresh()
                    }
                }
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