import SwiftUI
import AppKit

/// Menu bar ("taskbar at the top") presence.
///
/// The window stays available too — the menu bar item is an additional home, not a
/// replacement, so drag-and-drop into the window still works.
///
/// Layout notes, because an earlier version of this file had five different horizontal insets
/// and three dividers banding a background that was already uniform:
///   - one inset constant, `pad`, used by every section;
///   - no dividers at all. The glass card is what separates the list from the chrome, and
///     hairlines across a uniform material only read as banding;
///   - the usage bar lives inside the header block instead of being its own full-bleed strip
///     touching a divider;
///   - Quit is a quiet text button sharing the session row, not a default button floating
///     alone at the bottom.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private let pad: CGFloat = 12

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
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, pad)
                    .padding(.top, pad)
                    .padding(.bottom, 10)

                linksCard
                    .padding(.horizontal, pad)

                if elsewhere > 0 {
                    Text("\(elsewhere) other link\(elsewhere == 1 ? "" : "s") outside this folder")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(.horizontal, pad + 2)
                        .padding(.top, 6)
                }

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow")
                        Text("Open Window")
                    }
                    .frame(maxWidth: .infinity)
                }
                .glassButton()
                .padding(.horizontal, pad)
                .padding(.top, 12)

                HStack(spacing: 6) {
                    Image(systemName: model.sessionExpires?.timeIntervalSinceNow ?? 0 > 0
                          ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(model.sessionExpires == nil ? Color.secondary : Color.green)
                    Text(model.sessionLabel)
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut("q")
                }
                .padding(.horizontal, pad + 2)
                .padding(.top, 10)
                .padding(.bottom, pad)
            }

            // Floating so a copy never resizes the popover or makes the rows jump.
            // `.id(toastID)` is what lets a repeat of the same message re-fire the transition.
            if let toast = model.toast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(toast).font(.callout.weight(.medium))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassCapsule()
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.bottom, 16)
                .id(model.toastID)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.25), value: model.toastID)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.up.forward.square.fill")
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("DriveDrop").font(.headline)
                    if !model.ready {
                        badge("LOADING", .secondary)
                    } else if model.usingMock {
                        badge("DEMO", .orange)
                    }
                }
                Text(DrivePath.display(model.currentDir))
                    .font(.caption).foregroundStyle(.secondary)
                if let u = model.usage {
                    Text("\(Fmt.bytes(u.freeBytes)) free of \(Fmt.bytes(u.totalBytes))")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(.top, 1)
                    ProgressView(value: Double(u.usedBytes),
                                 total: Double(max(1, u.totalBytes)))
                        .controlSize(.mini)
                        .padding(.top, 3)
                } else {
                    Text(model.status.isEmpty ? "…" : model.status)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
    }

    // MARK: - Links

    @ViewBuilder
    private var linksCard: some View {
        VStack(spacing: 2) {
            if shown.isEmpty {
                Text(model.usingMock
                     ? "Demo data — sign in to see your links."
                     : "No share links in this folder yet.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 12)
            } else {
                ForEach(ordered) { item in MenuBarRow(item: item) }
            }
        }
        .padding(4)
        .glassSurface(cornerRadius: 12)
    }
}

/// One link row. A view of its own so hover can be local state instead of forcing the whole
/// popover to re-render on every pointer move.
private struct MenuBarRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let item: ShareItem
    @State private var hovering = false

    /// Render-time decision, refreshed by the 60 s tick.
    ///
    /// Computed here rather than inline because a `switch` with assignments is not a View, and
    /// the click path makes its own decision with a fresh `Date()` — so a row that expired
    /// since the last render still refuses correctly instead of copying a dead URL.
    private var state: (live: Bool, why: String, offer: RowUnavailable?) {
        switch RowTapPolicy.decide(item, now: Date(), demo: model.usingMock) {
        case .copy:            return (true, "Copy the share URL", nil)
        case .offer(let rest): return (false, rest.why, rest)
        }
    }

    var body: some View {
        let st = state
        VStack(spacing: 0) {
            Button { model.tap(item) } label: {
                HStack(spacing: 9) {
                    Image(systemName: st.live ? "link" : "link.badge.questionmark")
                        .font(.system(size: 12))
                        .foregroundStyle(st.live ? Color.secondary : Color.orange)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .lineLimit(1).font(.callout)
                            .foregroundStyle(st.live ? Color.primary : Color.secondary)
                        if let c = Fmt.countdown(to: item.expiresAt) {
                            Text(c).font(.caption2)
                                .foregroundStyle(st.live ? Color.secondary : Color.orange)
                        } else {
                            Text(st.why).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 6)
                    if st.live {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .opacity(hovering ? 1 : 0)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.07) : .clear)
            )
            .opacity(st.live ? 1 : 0.72)
            // Not `.disabled` — that would hide the refusal from VoiceOver and leave the click
            // doing nothing at all, which is the bug this replaces.
            .accessibilityLabel("\(item.name), \(st.why). \(st.live ? "Copies the link" : "Offers actions")")
            .onHover { hovering = $0 }

            if let rest = st.offer, model.openRowID == item.id {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(RowTapPolicy.actions(for: rest), id: \.self) { action in
                        Button { run(action) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: icon(action)).font(.system(size: 11))
                                Text(action.title)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }
                }
                .padding(.leading, 25)
                .padding(.top, 2)
            }
        }
    }

    private func run(_ action: RowAction) {
        switch action {
        case .reShare:
            Task { await model.reShare(item) }
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
    }

    private func icon(_ a: RowAction) -> String {
        switch a {
        case .reShare:    return "arrow.clockwise"
        case .retry:      return "arrow.triangle.2.circlepath"
        case .dismiss:    return "xmark"
        case .openWindow: return "macwindow"
        }
    }
}
