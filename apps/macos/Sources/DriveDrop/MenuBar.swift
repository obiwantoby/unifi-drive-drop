import SwiftUI
import AppKit

/// Menu bar ("taskbar at the top") presence.
///
/// The window stays available too — the menu bar item is an additional home, not a
/// replacement, so drag-and-drop into the window still works.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// Render-time decision, refreshed by the 60 s tick.
    ///
    /// Computed here rather than inline because a `switch` with assignments is not a View, and
    /// the click path makes its own decision with a fresh `Date()` — so a row that expired
    /// since the last render still refuses correctly instead of copying a dead URL.
    private func rowState(_ item: ShareItem) -> (live: Bool, why: String, offer: RowUnavailable?) {
        switch RowTapPolicy.decide(item, now: Date(), demo: model.usingMock) {
        case .copy:            return (true, "Copy the share URL", nil)
        case .offer(let rest): return (false, rest.why, rest)
        }
    }

    private func actionIcon(_ a: RowAction) -> String {
        switch a {
        case .reShare:    return "arrow.clockwise"
        case .retry:      return "arrow.triangle.2.circlepath"
        case .dismiss:    return "xmark"
        case .openWindow: return "macwindow"
        }
    }

    /// Links inside the folder the main window is showing.
    ///
    /// This used to be `model.items.prefix(6)` — every link on the whole drive — so the menu
    /// bar disagreed with the window right next to it, and a link copied from the menu bore no
    /// relation to the folder being browsed.
    private var shown: [ShareItem] {
        let prefix = DrivePath.absolutePrefix(model.currentDir)
        return model.items.filter { $0.fileId == prefix || $0.fileId.hasPrefix(prefix + "/") }
    }

    /// Links elsewhere on the drive, reported so they are not simply hidden.
    private var elsewhere: Int { model.items.count - shown.count }

    /// Newest first, so the file you just dropped is the one under the pointer.
    ///
    /// The id tie-break is not decoration: two rows created in the same second would otherwise
    /// swap places on a refresh and move a different row under the cursor mid-click.
    private var ordered: [ShareItem] {
        shown.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
            // Header -------------------------------------------------------------
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.square.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("DriveDrop").font(.headline)
                        if !model.ready {
                            Text("LOADING")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        } else if model.usingMock {
                            Text("DEMO")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.orange.opacity(0.28), in: Capsule())
                        }
                    }
                    Text(DrivePath.display(model.currentDir))
                        .font(.caption2).foregroundStyle(.secondary)
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

            // Links in this folder -----------------------------------------------
            if shown.isEmpty {
                Text(model.usingMock
                     ? "Demo data — sign in to see your links."
                     : "No share links in this folder yet.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            } else {
                ForEach(ordered) { item in
                  Group {
                    let st = rowState(item)

                    Button { model.tap(item) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: st.live ? "link" : "link.badge.questionmark")
                                .foregroundStyle(st.live ? Color.primary : Color.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name).lineLimit(1).font(.callout)
                                if let c = Fmt.countdown(to: item.expiresAt) {
                                    Text(c).font(.caption2)
                                        .foregroundStyle(st.live ? Color.secondary : Color.orange)
                                } else if !st.live {
                                    Text(st.why).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(st.live ? 1 : 0.62)
                    // Not `.disabled` — that would hide the refusal from VoiceOver and leave the
                    // click doing nothing at all, which is the bug this replaces.
                    .accessibilityLabel("\(item.name), \(st.why). \(st.live ? "Copies the link" : "Offers actions")")
                    .padding(.horizontal, 10).padding(.vertical, 3)

                    // Nothing to copy → ask what the user wants, right here.
                    if let rest = st.offer, model.openRowID == item.id {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(RowTapPolicy.actions(for: rest), id: \.self) { action in
                                Button {
                                    switch action {
                                    case .reShare:    Task { await model.reShare(item) }
                                    case .retry:
                                        if let u = item.localPath { Task { await model.upload(u) } }
                                        model.openRowID = nil
                                    case .dismiss:
                                        if case .failed = item.phase { model.dismiss(item) }
                                        model.openRowID = nil
                                    case .openWindow:
                                        NSApp.activate(ignoringOtherApps: true)
                                        openWindow(id: "main")
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: actionIcon(action))
                                        Text(action.title)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .padding(.horizontal, 26).padding(.vertical, 2)
                            }
                        }
                        .padding(.bottom, 3)
                    }
                  }
                }
            }

            if elsewhere > 0 {
                Text("\(elsewhere) other link\(elsewhere == 1 ? "" : "s") outside this folder")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.top, 2)
            }

            Divider()

            // One action, on purpose. This popover does a single job — hand back the link you
            // just made. Uploading, refreshing and settings belong to the window, and the three
            // buttons that used to sit here only crowded it: Upload had never worked (it posted
            // a notification nothing was listening for), and the other two duplicated the window.
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "macwindow")
                    Text("Open Window")
                    Spacer()
                    Text("upload · refresh · settings")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 4)

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

            // Same capsule the window uses, floating over the list rather than inserted into
            // it: an inline banner resized the popover on every copy and made the rows jump.
            // `.id(toastID)` is what lets a repeat of the same message re-fire the transition.
            if let toast = model.toast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(toast).font(.callout.weight(.medium))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.bottom, 18)
                .id(model.toastID)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.25), value: model.toastID)
}
}
