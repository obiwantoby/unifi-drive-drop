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

    /// Bumped whenever the credential set changes. In-flight credential work carrying an
    /// older epoch is discarded, so a slow Keychain read cannot resurrect a session the user
    /// just removed, nor overwrite a password they just saved.
    private var credGen = 0

    /// Bumped on every refresh. Results are dropped unless the epoch is still current —
    /// overlapping refreshes (upload finishing, navigation, manual retry) otherwise finish in
    /// arbitrary order and last writer wins on data that has nothing to do with ordering.
    private var refreshGen = 0

    /// Overlapping refreshes are normal, so this is a counter: a bool would let the first
    /// finisher hide the spinner while others are still in flight.
    private var busyCount = 0

    /// The credential store is swappable so the races around it can be driven from a test
    /// without touching the real Keychain. Production behaviour is unchanged.
    nonisolated(unsafe) static var keychainRead: @Sendable (String) -> String? = { Keychain.password(for: $0) }
    nonisolated(unsafe) static var keychainWrite: @Sendable (String, String) -> Void = { Keychain.setPassword($0, for: $1) }

    /// Serialises credential-store access.
    ///
    /// Epochs alone are not enough. `Task.detached` gives no ordering guarantee, so a clear
    /// can be overtaken by an older save and leave the Keychain holding something different
    /// from the in-memory client. Every op carries the epoch it was issued under; the actor
    /// drops anything older, and it is the only thing that touches the store.
    ///
    /// The methods are synchronous on purpose: synchronous actor methods cannot interleave
    /// with each other, which is what makes the sequence atomic.
    private actor CredentialStore {
        private var latest = 0

        private func accepts(_ epoch: Int) -> Bool {
            if epoch < latest { return false }
            latest = epoch
            return true
        }

        func read(_ epoch: Int, _ host: String) -> String? {
            guard accepts(epoch) else { return nil }
            return AppModel.keychainRead(host)
        }

        func write(_ epoch: Int, _ password: String, _ host: String) {
            guard accepts(epoch) else { return }
            AppModel.keychainWrite(password, host)
        }
    }

    private let store = CredentialStore()

    init() {
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        Task { await bootstrap() }
    }

    /// Test seam: inject a client and skip the Keychain bootstrap entirely.
    init(forTesting injected: DriveClient) {
        client = injected
        ready = true
    }

    /// Re-read the Keychain and rebuild the client.
    func reload() {
        ready = false
        Task { await bootstrap() }
    }

    /// Keychain writes can block for the same reason reads can, so this stays off-main too.
    func clearSavedPassword() {
        credGen += 1
        let gen = credGen
        refreshGen += 1        // also retire any refresh still in flight
        let h = host
        ready = false
        status = "Removing saved password…"
        Task {
            await store.write(gen, "", h)
            applyClient(password: "", cred: gen)
        }
    }

    private func bootstrap() async {
        credGen += 1
        let gen = credGen
        refreshGen += 1
        let h = host
        status = "Unlocking saved sign-in…"
        // The read can stall indefinitely behind macOS's "app wants to use your
        // confidential information" dialog. Without this the app just looks broken.
        // It checks the epoch too: if this bootstrap has already been superseded, the newer
        // operation owns the status line and this one must not stamp on it.
        let warn = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.credGen == gen else { return }
            self.status = "Waiting for macOS Keychain approval…"
        }
        // Awaited directly on the actor, which runs it off the main thread and keeps the
        // credential ops ordered.
        let pw = await store.read(gen, h)
        warn.cancel()
        applyClient(password: pw ?? "", cred: gen)
    }

    /// `cred` is the credential epoch this work started under. If the user saved or cleared
    /// credentials while the Keychain call was blocked, applying the stale result would undo
    /// them — and `ready` would flip back on over their newer intent.
    private func applyClient(password: String, cred: Int) {
        guard cred == credGen else { return }
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
        credGen += 1
        let gen = credGen
        refreshGen += 1
        Task {
            if !pass.isEmpty { await store.write(gen, pass, h) }
            applyClient(password: pass, cred: gen)
        }
    }

    // MARK: actions

    /// Fetched independently rather than as one `try await (u, l, e)`: an empty or missing
    /// folder must not take the global link list down with it.
    func refresh() async {
        busyCount += 1
        // Must be set here as well as recomputed in the defer: with only the defer, a single
        // refresh never shows the spinner at all (busyCount goes 0->1, then 1->0).
        isBusy = true
        defer { busyCount -= 1; isBusy = busyCount > 0 }
        refreshGen += 1
        let gen = refreshGen
        let dir = DrivePath.canonical(currentDir)
        // Pin the client: a credential change swaps it mid-flight, and mixing responses from
        // two different sessions into one snapshot is worse than showing nothing.
        let c = client

        async let u = c.usage()
        async let l = c.list()
        async let e = c.browse(dir)

        // Every write is guarded. An older refresh that finishes last must not clobber a
        // newer one's data — checking only at the end (as this used to) still let the stale
        // usage/items/linksByPath assignments through.
        if let uu = try? await u, gen == refreshGen { usage = uu }
        if let ll = try? await l, gen == refreshGen {
            // Rows that only exist locally — an upload in flight, or one that failed — are not
            // in the server's list, so a refresh that replaces `items` wholesale would make
            // the progress bar vanish mid-transfer. Carry them over.
            let localOnly = items.filter { $0.phase != .ready }
            items = localOnly + ll
            // Two links can point at the same path; first one wins deterministically.
            linksByPath = Dictionary(ll.compactMap { s -> (String, ShareItem)? in
                s.fileId.isEmpty ? nil : (s.fileId, s)
            }, uniquingKeysWith: { a, _ in a })
        }
        do {
            let ee = try await e
            if gen == refreshGen { entries = ee }
        } catch is CancellationError {
            // A superseded navigation, not a folder problem. Leave entries alone.
        } catch {
            if gen == refreshGen { entries = [] }
        }
        guard gen == refreshGen else { return }
        status = ""
    }

    func navigate(to dir: String) {
        let d = DrivePath.canonical(dir)
        guard d != DrivePath.canonical(currentDir) else { return }
        currentDir = d
        scope = .folder
        Task { await refresh() }
    }

    func goUp() { navigate(to: DrivePath.parent(currentDir)) }

    func handleDrop(_ providers: [NSItemProvider]) {
        // Filter first and say so. Swallowing the whole drop with `try?` meant dropping a
        // folder, a URL, or text looked exactly like nothing happening.
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else {
            status = "That drop had no files in it — folders and links are not accepted."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var unread = 0
            for provider in files {
                guard let url = await Self.fileURL(from: provider) else { unread += 1; continue }
                await self.upload(url)
            }
            if unread > 0 { self.status = "\(unread) dropped item(s) could not be read." }
        }
    }

    /// Resolve a dropped item to a readable file URL.
    ///
    /// Three shapes show up in practice and the old code handled only two:
    ///   * `URL` — a plain drop from Finder
    ///   * `Data` holding the path — what `loadItem` returns for many sources
    ///   * a **file promise** — iCloud Drive and sandboxed apps hand back a promise, which is
    ///     neither, so the drop silently produced nothing
    /// For promises the file is copied to our own temp location first, because the one
    /// `loadFileRepresentation` hands us is deleted as soon as its completion returns.
    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        if let obj = try? await provider.loadItem(
            forTypeIdentifier: UTType.fileURL.identifier) {
            switch obj {
            case let u as URL where u.isFileURL: return u
            case let d as Data:
                if let u = URL(dataRepresentation: d, relativeTo: nil), u.isFileURL { return u }
            default: break
            }
        }
        // Ask unconditionally: if the provider cannot vend file data the completion just
        // hands back nil, which is the answer we wanted anyway.
        return await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { tmp, _ in
                guard let tmp else { cont.resume(returning: nil); return }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("drivedrop-\(UUID().uuidString.prefix(8))")
                    .appendingPathExtension(tmp.pathExtension)
                do {
                    try FileManager.default.copyItem(at: tmp, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    // If the copy fails, hand back the original anyway; it may still be live.
                    cont.resume(returning: tmp)
                }
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
