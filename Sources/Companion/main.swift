import AppKit
import SwiftUI

private struct Workspace: Identifiable, Equatable {
    let id: String
    let name: String
    let isFocused: Bool
    let bundleIDs: [String]
}

@MainActor
private final class AeroSpaceClient {
    private let executableCandidates = [
        NSString(string: "~/.local/bin/aerospace").expandingTildeInPath,
        "/opt/homebrew/bin/aerospace",
        "/usr/local/bin/aerospace"
    ]

    private var executable: String? {
        executableCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(_ arguments: [String]) -> String? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    func workspaces() -> [Workspace] {
        guard let workspaceOutput = run(["list-workspaces", "--all", "--format", "%{workspace}|%{workspace-is-focused}"]),
              let windowOutput = run(["list-windows", "--all", "--format", "%{app-bundle-id}|%{workspace}"]) else {
            return []
        }

        var appsByWorkspace: [String: [String]] = [:]
        for line in windowOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            var ids = appsByWorkspace[fields[1], default: []]
            if !ids.contains(fields[0]) { ids.append(fields[0]) }
            appsByWorkspace[fields[1]] = ids
        }

        return workspaceOutput.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let name = fields.first, !name.isEmpty else { return nil }
            let focused = fields.count > 1 && fields[1].trimmingCharacters(in: .whitespaces) == "true"
            return Workspace(id: name, name: name, isFocused: focused,
                             bundleIDs: appsByWorkspace[name, default: []])
        }
    }

    func focus(_ workspace: String) {
        _ = run(["workspace", workspace])
    }
}

private struct WorkspaceCompartment: View {
    let workspace: Workspace
    private let iconSize: CGFloat = 15

    var body: some View {
        HStack(spacing: 5) {
            Text(workspace.name)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(minWidth: 11)

            HStack(spacing: 3) {
                ForEach(workspace.bundleIDs.prefix(3), id: \.self) { bundleID in
                    AppIcon(bundleID: bundleID)
                        .frame(width: iconSize, height: iconSize)
                }
                if workspace.bundleIDs.count > 3 {
                    Text("+\(workspace.bundleIDs.count - 3)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 23)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(workspace.isFocused ? Color.accentColor.opacity(0.23) : Color.primary.opacity(0.075))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(workspace.isFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.09), lineWidth: 0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace \(workspace.name), \(workspace.bundleIDs.count) apps")
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "app")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
        }
        .help(bundleID)
    }
}

private struct WorkspaceStrip: View {
    let workspaces: [Workspace]
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(workspaces) { workspace in
                Button {
                    onSelect(workspace.name)
                } label: {
                    WorkspaceCompartment(workspace: workspace)
                }
                .buttonStyle(.plain)
                .help("Switch to workspace \(workspace.name)")
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 26)
        .fixedSize()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = AeroSpaceClient()
    private var statusItem: NSStatusItem!
    private var hostingView: NSHostingView<WorkspaceStrip>!
    private var refreshTimer: Timer?
    private var currentWorkspaces: [Workspace] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil

        hostingView = NSHostingView(rootView: WorkspaceStrip(workspaces: []) { [weak self] in
            self?.client.focus($0)
            self?.refresh()
        })
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            hostingView.heightAnchor.constraint(equalToConstant: 26)
        ])

        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        let updated = client.workspaces()
        guard updated != currentWorkspaces else { return }
        currentWorkspaces = updated
        hostingView.rootView = WorkspaceStrip(workspaces: updated) { [weak self] in
            self?.client.focus($0)
            self?.refresh()
        }
        hostingView.invalidateIntrinsicContentSize()
        statusItem.length = hostingView.fittingSize.width
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }
}

@main
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
