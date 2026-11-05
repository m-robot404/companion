import AppKit
import SwiftUI

private struct Workspace: Identifiable, Equatable {
    let id: String
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
                id: name,
                isFocused: fields.count > 1 && fields[1].trimmingCharacters(in: .whitespaces) == "true",
                bundleIDs: apps[name, default: []]
            )
        }
    }

    func focus(_ name: String) {
        _ = run(["workspace", name])
    }

    func subscribe(pipe: Pipe, onExit: @escaping () -> Void) throws -> Process {
        guard let executable else {
            throw NSError(domain: "Companion.AeroSpace", code: 1)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "subscribe", "focus-changed", "focused-workspace-changed",
            "focused-monitor-changed", "window-detected"
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

    private init() { cache.countLimit = 64 }

    func image(for bundleID: String) -> NSImage? {
        let key = bundleID as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 15, height: 15)
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        Group {
            if let image = AppIconCache.shared.image(for: bundleID) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "app").resizable().scaledToFit()
                    .foregroundStyle(.secondary).padding(2)
            }
        }
        .frame(width: 15, height: 15)
        .help(bundleID)
    }
}

private struct WorkspaceCompartment: View {
    let workspace: Workspace
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(workspace.id)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospaced()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(minWidth: 11)
            HStack(spacing: 3) {
                ForEach(workspace.bundleIDs.prefix(3), id: \.self) { AppIcon(bundleID: $0) }
                if workspace.bundleIDs.count > 3 {
                    Text("+\(workspace.bundleIDs.count - 3)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background {
            shape.fill(workspace.isFocused
                ? Color.accentColor.opacity(0.17)
                : Color.primary.opacity(0.065))
        }
        .glassEffect(.regular, in: shape)
        .overlay {
            shape.strokeBorder(
                workspace.isFocused ? Color.accentColor.opacity(0.52) : Color.primary.opacity(0.09),
                lineWidth: 0.7
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace \(workspace.id), \(workspace.bundleIDs.count) applications")
    }
}

private struct WorkspaceStrip: View {
    let workspaces: [Workspace]
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(workspaces) { workspace in
                Button { onSelect(workspace.id) } label: {
                    WorkspaceCompartment(workspace: workspace)
                }
                .buttonStyle(.plain)
                .help("Switch to workspace \(workspace.id)")
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 22)
        .fixedSize(horizontal: true, vertical: true)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = AeroSpaceClient()
    private var statusItem: NSStatusItem?
    private var host: NSHostingView<WorkspaceStrip>?
    private var stream: Process?
    private var streamPipe: Pipe?
    private var buffer = ""
    private var reconnect: DispatchWorkItem?
    private var refreshTask: DispatchWorkItem?
    private var workspaces: [Workspace] = []
    private var stopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let view = NSHostingView(rootView: WorkspaceStrip(workspaces: []) { [weak self] name in
            self?.client.focus(name)
            self?.scheduleRefresh()
        })
        view.frame = NSRect(x: 0, y: 0, width: 30, height: 22)
        host = view
        item.view = view

        refresh()
        startStream()
    }

    private func refresh() {
        guard let latest = client.snapshot(), latest != workspaces else { return }
        workspaces = latest
        host?.rootView = WorkspaceStrip(workspaces: latest) { [weak self] name in
            self?.client.focus(name)
            self?.scheduleRefresh()
        }
        guard let host, let statusItem else { return }
        let width = max(1, ceil(host.fittingSize.width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 22)
        statusItem.length = width
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }

    private func startStream() {
        guard !stopping, stream == nil else { return }
        let pipe = Pipe()
        do {
            let process = try client.subscribe(pipe: pipe) { [weak self] in
                DispatchQueue.main.async { self?.streamEnded() }
            }
            streamPipe = pipe
            stream = process
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.receive(text) }
            }
        } catch {
            scheduleReconnect()
        }
    }

    private func receive(_ text: String) {
        buffer += text
        while let end = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<end])
            buffer.removeSubrange(...end)
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let event = object["_event"] as? String
            else { continue }
            if ["focus-changed", "focused-workspace-changed",
                "focused-monitor-changed", "window-detected"].contains(event) {
                scheduleRefresh()
            }
        }
    }

    private func streamEnded() {
        streamPipe?.fileHandleForReading.readabilityHandler = nil
        streamPipe = nil
        stream = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopping, reconnect == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnect = nil
            self.refresh()
            self.startStream()
        }
        reconnect = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopping = true
        refreshTask?.cancel()
        reconnect?.cancel()
        streamPipe?.fileHandleForReading.readabilityHandler = nil
        stream?.terminate()
        stream = nil
        streamPipe = nil
    }
}

@main
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
