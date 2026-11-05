import AppKit
import CoreGraphics
import IOKit
import MachO

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
        CGFloat(defaults.object(forKey: "backgroundOpacity") as? Double ?? 0.18)
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
        guard
            let workspaceText = run(["list-workspaces", "--all", "--format", "%{workspace}|%{workspace-is-focused}"]),
            let windowText = run(["list-windows", "--all", "--format",
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
    let onFocusWindow: (String) -> Void
    private var tracking: NSTrackingArea?
    private var previewPopover: NSPopover?
    private var hoveredGroupID: String?

    init(workspace: Workspace, frame: NSRect,
         onSelect: @escaping (String) -> Void,
         onFocusWindow: @escaping (String) -> Void) {
        self.workspace = workspace
        self.onSelect = onSelect
        self.onFocusWindow = onFocusWindow
        super.init(frame: frame)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Workspace \(workspace.name), \(workspace.windows.count) windows")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func group(at point: NSPoint) -> AppGroup? {
        iconFrames().first(where: { $0.0.insetBy(dx: -2, dy: -2).contains(point) })?.1
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let group = group(at: point) else {
            previewPopover?.close()
            previewPopover = nil
            hoveredGroupID = nil
            return
        }
        guard hoveredGroupID != group.bundleID else { return }
        hoveredGroupID = group.bundleID
        showPreview(for: group, at: point)
    }

    override func mouseExited(with event: NSEvent) {
        previewPopover?.close()
        previewPopover = nil
        hoveredGroupID = nil
    }

    private func showPreview(for group: AppGroup, at point: NSPoint) {
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSViewController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 156))
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        let imageView = NSImageView(frame: NSRect(x: 12, y: 38, width: 208, height: 106))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = previewImage(for: group.windows[0]) ??
            AppIconCache.shared.image(for: group.bundleID, size: 64)
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
        popover.show(relativeTo: NSRect(x: point.x - 2, y: point.y, width: 4, height: 2),
                     of: self, preferredEdge: .maxY)
        previewPopover = popover
    }

    private func previewImage(for window: WorkspaceWindow) -> NSImage? {
        guard CGPreflightScreenCaptureAccess(),
              let id = UInt32(window.id),
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(id), [.bestResolution])
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        previewPopover?.close()
        previewPopover = nil
        guard let group = group(at: point) else {
            onSelect(workspace.name)
            return
        }
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

    @objc private func selectWindowFromMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        onFocusWindow(id)
    }
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

    private var gap: CGFloat { CompanionPreferences.workspaceSpacing * CompanionPreferences.size / 22 }
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

    private var focusWindow: ((String) -> Void)?

    func update(workspaces: [Workspace], onSelect: @escaping (String) -> Void,
                onFocusWindow: @escaping (String) -> Void) {
        self.workspaces = CompanionPreferences.occupiedOnly
            ? workspaces.filter { !$0.windows.isEmpty || $0.isFocused }
            : workspaces
        selection = onSelect
        focusWindow = onFocusWindow
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
                                                onSelect: onSelect,
                                                onFocusWindow: { [weak self] id in self?.focusWindow?(id) })
            let background: NSView
            if CompanionPreferences.background == .glass {
                let glass = NSGlassEffectView(frame: frame)
                glass.cornerRadius = 9 * scale
                glass.tintColor = workspace.isFocused
                    ? CompanionPreferences.accentColor.withAlphaComponent(0.22)
                    : NSColor.controlBackgroundColor.withAlphaComponent(CompanionPreferences.backgroundOpacity)
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
            (focused ? CompanionPreferences.accentColor.withAlphaComponent(min(1, CompanionPreferences.backgroundOpacity + 0.2))
                     : NSColor.controlBackgroundColor.withAlphaComponent(CompanionPreferences.backgroundOpacity)).setFill()
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
        var count = mach_msg_type_number_t(HOST_CPU_LOAD_INFO_COUNT)
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
        for value in [5, 10, 18, 25, 35, 50, 70, 100] {
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
        let notchInfo = NSMenuItem(title: "Position & Notch: Managed by macOS", action: nil, keyEquivalent: "")
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
        if ["stripSize", "workspaceSpacing", "inactiveIconOpacity", "backgroundOpacity"].contains(values[0]) {
            value = Double(values[1]) ?? 22
        } else { value = values[1] }
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
        strip?.update(workspaces: currentWorkspaces, onSelect: { [weak self] name in
            guard let self else { return }
            DispatchQueue.global(qos: .userInteractive).async { [client = self.client] in client.focus(name) }
            self.scheduleRefresh()
        }, onFocusWindow: { [weak self] id in
            guard let self else { return }
            DispatchQueue.global(qos: .userInteractive).async { [client = self.client] in client.focusWindow(id) }
            self.scheduleRefresh()
        })
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
