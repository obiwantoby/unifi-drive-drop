import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Backdrop()

            VStack(spacing: 0) {
                header
                pathBar
                dropArea
                Divider().opacity(0.35)
                list
                footer
            }
            .padding(12)

            if let toast = model.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                    .padding(.bottom, 56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        // Accept the drop anywhere in the window, not only in the dashed box. `.data` is
        // deliberately omitted from the type list: offering it lets SwiftUI hand back a
        // provider that only vends bytes, and the file URL then resolves to nothing.
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
            model.handleDrop(providers)
            return true
        }
        .preferredColorScheme(.dark)
        .animation(.spring(duration: 0.3, bounce: 0.25), value: model.toast)
        .animation(.spring(duration: 0.3, bounce: 0.25), value: model.isDropTargeted)
        .confirmationDialog("Delete this share?", isPresented: .init(
            get: { model.pendingDelete != nil },
            set: { if !$0 { model.pendingDelete = nil } }),
            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = model.pendingDelete { Task { await model.delete(item) } }
                model.pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text(model.pendingDelete.map { "\($0.name)\n\nThe link stops working immediately. The file stays in Drive." } ?? "")
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.tint)
            Text("DriveDrop").font(.headline)
            if model.ready && model.usingMock {
                Text("DEMO")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.22), in: Capsule())
            }
            Spacer()
            Text(model.host)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
    }

    // MARK: path bar

    /// The folder being listed is also the drop target, so it gets its own bar rather than
    /// hiding in Settings.
    private var pathBar: some View {
        HStack(spacing: 8) {
            Button { model.goUp() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canGoUp ? Color.secondary : Color.secondary.opacity(0.3))
            .disabled(!model.canGoUp)
            .help("Up one folder")

            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(DrivePath.display(model.currentDir))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)

            Spacer()

            Picker("", selection: $model.scope) {
                Text("This folder").tag(AppModel.Scope.folder)
                Text("All links").tag(AppModel.Scope.allLinks)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("List this folder, or every share link on the drive")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    // MARK: drop area

    private var dropArea: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up.to.line.compact")
                .font(.system(size: 30, weight: .light))
                .symbolEffect(.bounce, value: model.isDropTargeted)
            Text("Drop files to get a link")
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Text(model.inFlight.isEmpty
                 ? "into \(DrivePath.display(model.currentDir)) · click to browse · right-click for options"
                 : "\(model.inFlight.count) upload\(model.inFlight.count == 1 ? "" : "s") in progress…")
                .font(.caption).foregroundStyle(model.inFlight.isEmpty ? Color.secondary : Color.accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { pickFiles() }
    }

    // MARK: list

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if !model.ready {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.status.isEmpty ? "Starting…" : model.status)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)
                } else if model.scope == .folder {
                    // In-flight uploads are not in the server listing, so they must be drawn
                    // here or a drop shows no progress at all.
                    ForEach(model.inFlight) { item in
                        ShareRow(item: item)
                            .environmentObject(model)
                            .contextMenu { menu(for: item) }
                    }
                    ForEach(model.entries) { entry in
                        EntryRow(entry: entry, link: model.link(for: entry.path))
                            .environmentObject(model)
                    }
                    if model.entries.isEmpty && !model.isBusy {
                        Text(model.status.isEmpty
                             ? "Empty — drop something in."
                             : "Could not list this folder.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                } else {
                    ForEach(model.items) { item in
                        ShareRow(item: item)
                            .environmentObject(model)
                            .contextMenu { menu(for: item) }
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func menu(for item: ShareItem) -> some View {
        Button("Copy share URL") { model.copy(item.shareURL?.absoluteString ?? "", label: "Link copied") }
            .keyboardShortcut("c")
            .disabled(item.shareURL == nil || model.usingMock)
        Button("Copy direct download URL") {
            model.copy(item.directURL?.absoluteString ?? item.shareURL?.absoluteString ?? "", label: "Direct link copied")
        }
        .keyboardShortcut("c", modifiers: [.shift, .command])
        .disabled(item.shareURL == nil)

        Button("Open in Browser") {
            if let u = item.shareURL { NSWorkspace.shared.open(u) }
        }
        .disabled(item.shareURL == nil)

        Divider()

        Menu("Set expiration") {
            ForEach(Expiration.menuOrder) { exp in
                Button {
                    Task { await model.setExpiration(item, exp) }
                } label: {
                    HStack {
                        Text(exp.label)
                        if isCurrent(item, exp) { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button("Never expires") { Task { await model.setExpiration(item, .never) } }
        }

        Divider()

        if case .failed = item.phase {
            Button("Retry upload") { Task { await model.retry(item) } }
            // A failed row may never have reached the server, so "Delete" can be meaningless.
            // Dismiss drops the local row and stops it cluttering the list.
            Button("Dismiss") { model.dismiss(item) }
        }
        Button("Delete", role: .destructive) { model.pendingDelete = item }
            .keyboardShortcut(.delete, modifiers: .command)
    }

    private func isCurrent(_ item: ShareItem, _ exp: Expiration) -> Bool {
        guard let e = item.expiresAt else { return exp == .never }
        return abs(e.timeIntervalSinceNow - (exp.seconds ?? -1)) < 120
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let u = model.usage, u.totalBytes > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Fmt.bytes(u.freeBytes)) free of \(Fmt.bytes(u.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(u.usedBytes), total: Double(u.totalBytes))
                        .controlSize(.mini).frame(width: 150)
                }
            }
            Spacer()
            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            for u in panel.urls { Task { await model.upload(u) } }
        }
    }
}

enum Icon {
    static func file(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["mov", "mp4", "m4v", "avi"].contains(ext) { return "film" }
        if ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext) { return "photo" }
        if ["mp3", "wav", "aac", "flac"].contains(ext) { return "waveform" }
        if ["zip", "tar", "gz", "dmg", "iso"].contains(ext) { return "archivebox" }
        if ["pdf"].contains(ext) { return "doc.richtext" }
        return "doc"
    }
}

/// One item inside the current folder, with its share link if it has one.
/// A directory is a row too — Drive lets you share folders, so the menu stays available.
struct EntryRow: View {
    @EnvironmentObject var model: AppModel
    let entry: FileEntry
    let link: ShareItem?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDir ? "folder" : Icon.file(entry.name))
                .foregroundStyle(link == nil ? Color.secondary : Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    if entry.isDir {
                        Text("folder")
                    } else {
                        Text(Fmt.bytes(entry.size))
                    }
                    if let l = link {
                        Text("·")
                        if let cd = Fmt.countdown(to: l.expiresAt) {
                            Text(cd).foregroundStyle(expiryColor(l))
                        } else {
                            Text("shared · no expiry")
                        }
                    } else {
                        Text("·")
                        Text("not shared").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            if let l = link {
                Button { model.copy(l.shareURL?.absoluteString ?? "", label: "Link copied") } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .help("Copy link")
            } else if !entry.isDir {
                Button { Task { await model.share(entry) } } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .help("Create share link")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hovering ? Color.white.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Primary click: folders navigate, files copy (or create) their link.
        .onTapGesture {
            if entry.isDir {
                model.navigate(to: childOfCurrent())
            } else if let l = link, let u = l.shareURL {
                model.copy(u.absoluteString, label: "Link copied")
            } else {
                Task { await model.share(entry) }
            }
        }
        .contextMenu {
            if entry.isDir {
                Button("Open folder") { model.navigate(to: childOfCurrent()) }
                Divider()
            }
            if let l = link {
                Button("Copy share URL") {
                    model.copy(l.shareURL?.absoluteString ?? "", label: "Link copied")
                }
                .disabled(l.shareURL == nil)
                Button("Open in Browser") {
                    if let u = l.shareURL { NSWorkspace.shared.open(u) }
                }
                .disabled(l.shareURL == nil)
                Divider()
                Menu("Set expiration") {
                    ForEach(Expiration.menuOrder) { exp in
                        Button(exp.label) { Task { await model.setExpiration(l, exp) } }
                    }
                }
                Divider()
                Button("Delete link", role: .destructive) { model.pendingDelete = l }
            } else if !entry.isDir {
                Button("Create share link") { Task { await model.share(entry) } }
            }
        }
    }

    /// Entries carry absolute paths; navigation wants the personal-relative form.
    private func childOfCurrent() -> String {
        DrivePath.canonical(entry.path)
    }

    private func expiryColor(_ l: ShareItem) -> Color {
        guard let e = l.expiresAt else { return .secondary }
        let iv = e.timeIntervalSinceNow
        if iv <= 0 { return .red }
        if iv < 86_400 { return .orange }
        return .secondary
    }
}

struct ShareRow: View {
    @EnvironmentObject var model: AppModel
    let item: ShareItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Fmt.bytes(item.size))
                    if let cd = Fmt.countdown(to: item.expiresAt) {
                        Text("·")
                        Text(cd).foregroundStyle(expiryColor)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            if case .uploading(let p) = item.phase {
                ProgressView(value: p).controlSize(.small).frame(width: 70)
                Text("\(Int(p * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            } else if item.phase == .finalizing {
                // Bytes are all sent; the console is still making the object visible. Saying so
                // beats an unexplained pause at 100%, which reads as a hang.
                ProgressView().controlSize(.small)
                Text("Finalizing").font(.caption2).foregroundStyle(.secondary)
            } else if item.phase == .sharing {
                ProgressView().controlSize(.small)
                Text("Linking").font(.caption2).foregroundStyle(.secondary)
            } else if case .failed(let msg) = item.phase {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(msg)
            } else {
                Button { model.copy(item.shareURL?.absoluteString ?? "") } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .disabled(model.usingMock)
                .help(model.usingMock ? "Demo data — sign in first" : "Copy link")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hovering ? Color.white.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if let u = item.shareURL { NSWorkspace.shared.open(u) }
        }
    }

    private var icon: String {
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ["mov", "mp4", "m4v", "avi"].contains(ext) { return "film" }
        if ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext) { return "photo" }
        if ["mp3", "wav", "aac", "flac"].contains(ext) { return "waveform" }
        if ["zip", "tar", "gz", "dmg", "iso"].contains(ext) { return "archivebox" }
        if ["pdf"].contains(ext) { return "doc.richtext" }
        return "doc"
    }

    private var iconColor: Color {
        if case .failed = item.phase { return .orange }
        return .secondary
    }

    private var expiryColor: Color {
        guard let e = item.expiresAt else { return .secondary }
        let iv = e.timeIntervalSinceNow
        if iv <= 0 { return .red }
        if iv < 86_400 { return .orange }
        return .secondary
    }
}
