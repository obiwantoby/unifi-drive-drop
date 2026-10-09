import SwiftUI
import AppKit

/// Menu bar ("taskbar at the top") presence.
///
/// The window stays available too — the menu bar item is an additional home, not a
/// replacement, so drag-and-drop into the window still works.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// `SettingsLink` silently does nothing inside a `.window`-style `MenuBarExtra`, so drive
    /// the Settings scene through the responder chain instead. The app must be active first,
    /// otherwise the action has no responder to land on.
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // sendAction returns false when nothing in the responder chain handles it, so we can
        // probe both spellings: SwiftUI renamed it to showSettingsWindow: on macOS 14.
        DispatchQueue.main.async {
            for name in ["showSettingsWindow:", "orderFrontPreferencesAlert:"]
            where NSApp.sendAction(Selector((name)), to: nil, from: nil) { return }
            model.status = "Could not open Settings"
        }
    }

    private var recent: [ShareItem] {
        Array(model.items.prefix(6))
    }

    var body: some View {
        // Header -------------------------------------------------------------
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.forward.square.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("DriveDrop").font(.headline)
                if let u = model.usage {
                    Text("\(Fmt.bytes(u.freeBytes)) free of \(Fmt.bytes(u.totalBytes))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(model.status.isEmpty ? "…" : model.status)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)

        if let u = model.usage {
            ProgressView(value: Double(u.usedBytes), total: Double(max(1, u.totalBytes)))
                .controlSize(.mini).padding(.horizontal, 10)
        }

        Divider()

        // Recent links -------------------------------------------------------
        if recent.isEmpty {
            Text("No share links yet")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.vertical, 6)
        } else {
            ForEach(recent) { item in
                Button {
                    if let s = item.shareURL?.absoluteString { model.copy(s, label: "Link copied") }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name).lineLimit(1).font(.callout)
                            if let c = Fmt.countdown(to: item.expiresAt) {
                                Text(c).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 3)
            }
        }

        Divider()

        // Actions ------------------------------------------------------------
        Button("Upload Files…") {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .drivedropPickFiles, object: nil)
        }
        .keyboardShortcut("o")

        Button("Open Window") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Button("Refresh") { Task { await model.refresh() } }
            .keyboardShortcut("r")
            .disabled(model.isBusy)

        Button("Settings…") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)

        Divider()

        // Session lifetime, so "will it die?" is answerable at a glance.
        HStack {
            Image(systemName: model.sessionExpires?.timeIntervalSinceNow ?? 0 > 0
                  ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(model.sessionExpires == nil ? Color.secondary : Color.green)
            Text(model.sessionLabel)
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)

        Button("Quit DriveDrop") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .padding(.bottom, 6)
    }
}
