import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    /// Every share link on the drive, regardless of folder.
    @Published var items: [ShareItem] = []
    /// Contents of `currentDir`, from `/resources/mydrive{dir}/`.
    @Published var entries: [FileEntry] = []
    /// Join index: absolute path (`/mydrive/Public/x.zip`) -> its link, if shared.
    @Published var linksByPath: [String: ShareItem] = [:]
    @Published var scope: Scope = .folder
    @Published var usage: Usage?
    @Published var isDropTargeted = false
    @Published var status: String = ""
    @Published var toast: String?
    @Published var isBusy = false

    // settings
    @AppStorage("host") var host: String = "192.0.2.10"
    @AppStorage("username") var username: String = ""
    /// The folder being shown **and** the drop target — one value on purpose, so what you
    /// look at is always what you upload into. Persisted under the original key.
    /// Drive creates missing folders on the first upload (verified), so no mkdir step.
    @AppStorage("uploadFolder") var currentDir: String = "/Public"
    @AppStorage("defaultExpiration") var defaultExpirationRaw: String = "7d"
    @AppStorage("copyOnUpload") var copyOnUpload: Bool = true
    @AppStorage("allowInvalidCerts") var allowInvalidCerts: Bool = true

    private(set) var client: DriveClient = MockDriveClient()
    private var tick: Timer?

    enum Scope: Hashable { case folder, allLinks }

    var usingMock: Bool { client is MockDriveClient }

    /// Shared or not, one row per file in the folder being shown.
    func link(for path: String) -> ShareItem? { linksByPath[path] }

    var canGoUp: Bool { DrivePath.canonical(currentDir) != "/" }

    /// When the console TOKEN expires (from X-Token-Expire-Time), if we are live.
    var sessionExpires: Date? {
        (client as? LiveDriveClient)?.session.tokenExpire
    }

    var sessionLabel: String {
        guard !usingMock else { return "Mock client — no session" }
        guard let d = sessionExpires else { return "No session yet" }
        let secs = d.timeIntervalSinceNow
        if secs <= 0 { return "Session expired — renews on next action" }
        let mins = Int(secs / 60)
        if mins >= 60 * 24 { return "Session valid ~\(mins / 1440) days" }
        if mins >= 60 { return "Session valid \(mins / 60)h \(mins % 60)m" }
        return "Session valid \(mins)m"
    }

    var defaultExpiration: Expiration {
        get {
            switch defaultExpirationRaw {
            case "1h": .oneHour
            case "1d": .oneDay
            case "30d": .thirtyDays
            case "never": .never
            default: .sevenDays
            }
        }
        set { defaultExpirationRaw = newValue.id }
    }

    /// False until the Keychain read has finished. A synchronous `SecItemCopyMatching` on
    /// the main thread during launch can block forever: if securityd wants to raise an
    /// access prompt (it does whenever the binary's code requirement changes, i.e. on every
    /// rebuild of an ad-hoc-signed app), the prompt cannot be shown because the app has not
    /// finished launching. That is a deadlocked process with no UI, not a slow one.
    @Published private(set) var ready = false

    init() {
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        Task { await bootstrap() }
    }

    /// Re-read the Keychain and rebuild the client.
    func reload() {
        ready = false
        Task { await bootstrap() }
    }

    /// Keychain writes can block for the same reason reads can, so this stays off-main too.
    func clearSavedPassword() {
        let h = host
        ready = false
        status = "Removing saved password…"
        Task {
            await Task.detached(priority: .userInitiated) { Keychain.setPassword("", for: h) }.value
            applyClient(password: "")
        }
    }

    private func bootstrap() async {
        status = "Unlocking saved sign-in…"
        let h = host
        // Off the main actor, so a Keychain prompt or a slow securityd never stalls launch.
        let read = Task.detached(priority: .userInitiated) { Keychain.password(for: h) }
        // The read can stall indefinitely behind macOS's "app wants to use your
        // confidential information" dialog. Without this the app just looks broken.
        let warn = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { status = "Waiting for macOS Keychain approval…" }
        }
        let pw = await read.value
        warn.cancel()
        applyClient(password: pw ?? "")
    }

    private func applyClient(password: String) {
        if username.isEmpty || password.isEmpty {
            client = MockDriveClient()
            status = "Demo data — open Settings and save your console sign-in."
        } else {
            client = LiveDriveClient(session: DriveSession(host: host, username: username,
                                                           password: password,
                                                           allowInvalidCerts: allowInvalidCerts))
            status = ""
        }
        ready = true
        Task { await refresh() }
    }

    /// Called from Settings after the fields change; the password write is also kept off-main.
    func saveCredentials(host h: String, user: String, pass: String) {
        host = h
        username = user
        ready = false
        status = "Saving…"
        Task {
            if !pass.isEmpty {
                await Task.detached(priority: .userInitiated) { Keychain.setPassword(pass, for: h) }.value
            }
            applyClient(password: pass)
        }
    }

    // MARK: actions

    /// Fetched independently rather than as one `try await (u, l, e)`: an empty or missing
    /// folder must not take the global link list down with it.
    func refresh() async {
        isBusy = true
        defer { isBusy = false }
        refreshGen += 1
        let gen = refreshGen
        let dir = DrivePath.canonical(currentDir)

        async let u = client.usage()
        async let l = client.list()
        async let e = client.browse(dir)

        if let uu = try? await u { usage = uu }
        if let ll = try? await l {
            items = ll
            // Two links can point at the same path; first one wins deterministically.
            linksByPath = Dictionary(ll.compactMap { s -> (String, ShareItem)? in
                s.fileId.isEmpty ? nil : (s.fileId, s)
            }, uniquingKeysWith: { a, _ in a })
        }
        do {
            let ee = try await e
            if DrivePath.canonical(currentDir) == dir { entries = ee }
        } catch {
            if DrivePath.canonical(currentDir) == dir { entries = [] }
        }
        // Drop results that a navigation already superseded.
        guard gen == refreshGen else { return }
        status = ""
    }

    private var refreshGen = 0

    func navigate(to dir: String) {
        let d = DrivePath.canonical(dir)
        guard d != DrivePath.canonical(currentDir) else { return }
        currentDir = d
        scope = .folder
        Task { await refresh() }
    }

    func goUp() { navigate(to: DrivePath.parent(currentDir)) }

    func handleDrop(_ providers: [NSItemProvider]) {
        Task { [weak self] in
            guard let self else { return }
            for provider in providers {
                guard let obj = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) else { continue }
                let url: URL?
                switch obj {
                case let u as URL: url = u
                case let d as Data: url = URL(dataRepresentation: d, relativeTo: nil)
                default: url = nil
                }
                if let url { await self.upload(url) }
            }
        }
    }

    func upload(_ url: URL) async {
        // Captured now: navigating mid-upload must not retarget an in-flight drop.
        let dir = DrivePath.canonical(currentDir)
        // security-scoped access for dragged-in file URLs
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var item = ShareItem(id: "pending-\(UUID().uuidString.prefix(6))", fileId: "",
                             name: url.lastPathComponent,
                             size: ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0,
                             shareURL: nil, directURL: nil, createdAt: .now, expiresAt: nil,
                             phase: .uploading(0), progress: 0, localPath: url)
        items.insert(item, at: 0)

        let box = ProgressBox()
        let pendingID = item.id
        let watcher = Task { @MainActor in
            for await p in box.stream {
                if let i = items.firstIndex(where: { $0.id == pendingID }) {
                    items[i].phase = .uploading(p)
                    items[i].progress = p
                }
            }
        }

        do {
            let done = try await client.upload(from: url, to: dir) { p in box.send(p) }
            item = done
            if let i = items.firstIndex(where: { $0.localPath == url && $0.phase.isTerminal == false }) {
                items[i] = done
            } else {
                items.insert(done, at: 0)
            }
            // then create the share
            items.removeAll { $0.id == "pending-\(item.id)" }
            let shared = try await client.createShare(for: done.fileId,
                                                      expiration: defaultExpiration,
                                                      password: nil)
            if let i = items.firstIndex(where: { $0.fileId == done.fileId }) {
                items[i] = shared
            } else {
                items.insert(shared, at: 0)
            }
            if copyOnUpload, let u = shared.shareURL { copy(u.absoluteString, label: "Link copied") }
        } catch {
            if let i = items.firstIndex(where: { $0.localPath == url && !$0.phase.isTerminal }) {
                items[i].phase = .failed(error.localizedDescription)
            }
            status = error.localizedDescription
        }
        box.finish()
        watcher.cancel()
        // Re-read the folder we actually dropped into, so the new file shows up even if the
        // user moved on in the meantime.
        await refresh()
    }

    /// Share a file that is already in Drive but has no link yet.
    func share(_ entry: FileEntry) async {
        do {
            let s = try await client.createShare(for: entry.path, expiration: defaultExpiration,
                                                 password: nil)
            if let i = items.firstIndex(where: { $0.id == s.id }) { items[i] = s } else { items.insert(s, at: 0) }
            linksByPath[entry.path] = s
            if copyOnUpload, let u = s.shareURL { copy(u.absoluteString, label: "Link copied") }
        } catch { status = error.localizedDescription }
    }

    func copy(_ s: String, label: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        toast = label
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if toast == label { toast = nil }
        }
    }

    func setExpiration(_ item: ShareItem, _ exp: Expiration) async {
        do {
            let updated = try await client.setExpiration(item, exp)
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = updated }
            toast = "Expiry set"
        } catch { status = error.localizedDescription }
    }

    /// Set to ask the user before a link is deleted.
    @Published var pendingDelete: ShareItem?

    func delete(_ item: ShareItem) async {
        do {
            try await client.delete(item)
            items.removeAll { $0.id == item.id }
            if linksByPath[item.fileId]?.id == item.id { linksByPath.removeValue(forKey: item.fileId) }
            toast = "Deleted"
        } catch { status = error.localizedDescription }
    }

    func retry(_ item: ShareItem) async {
        guard let url = item.localPath else { return }
        items.removeAll { $0.id == item.id }
        await upload(url)
    }
}

/// thread-safe progress fan-out
private final class ProgressBox: @unchecked Sendable {
    private let made = AsyncStream<Double>.makeStream()
    var stream: AsyncStream<Double> { made.stream }
    func send(_ v: Double) { made.continuation.yield(v) }
    func finish() { made.continuation.finish() }
}
