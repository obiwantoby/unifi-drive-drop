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
    /// Bumped on every toast, including a repeat of the same message.
    ///
    /// Animating on `toast` alone means a second "Link copied" is invisible: the text is
    /// already on screen, so nothing appears to happen — which reads as the copy having
    /// failed, and sends people clicking the row again and again.
    @Published private(set) var toastID = 0
    private var toastTask: Task<Void, Never>?
    @Published var isBusy = false

    // settings
    @AppStorage("host") var host: String = "192.0.2.10"
    @AppStorage("username") var username: String = ""
    /// The folder being shown **and** the drop target — one value on purpose, so what you
    /// look at is always what you upload into. Persisted under the original key.
    /// Drive creates missing folders on the first upload (verified), so no mkdir step.
    @AppStorage("uploadFolder") var currentDir: String = "/Public"
    /// Dock tile on or off. Menu-bar-only is the natural shape for this app, but hiding the
    /// tile also removes it from ⌘-Tab and Exposé — which is precisely what someone looking
    /// for the window in Exposé does not want. Opt-in, and default off-equivalent (tile shown).
    @AppStorage("showDockIcon") var showDockIcon: Bool = true {
        didSet { applyDockIcon() }
    }

    /// Applied from `init` as well as `didSet`: the stored choice has to survive relaunch,
    /// and a policy change only takes effect on the next activation otherwise.
    func applyDockIcon() {
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if showDockIcon { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    @AppStorage("defaultExpiration") var defaultExpirationRaw: String = "7d"
    @AppStorage("copyOnUpload") var copyOnUpload: Bool = true
    @AppStorage("allowInvalidCerts") var allowInvalidCerts: Bool = true

    private(set) var client: DriveClient = MockDriveClient()
    private var tick: Timer?

    enum Scope: Hashable { case folder, allLinks }

    var usingMock: Bool { client is MockDriveClient }

    /// Shared or not, one row per file in the folder being shown.
    func link(for path: String) -> ShareItem? { linksByPath[path] }

    /// Uploads in flight, and any that failed.
    ///
    /// These live only in `items` — the server listing cannot know about them — so the folder
    /// view has to render them explicitly. It used not to, which made a drop look like a no-op
    /// for the whole duration of the transfer.
    var inFlight: [ShareItem] { items.filter { $0.phase != .ready } }

    /// Only the ones actually moving. `.failed` is terminal, so it must not be counted here —
    /// a dead row sitting in the list used to keep saying "1 upload in progress" forever.
    var uploadingCount: Int { items.filter { !$0.phase.isTerminal }.count }

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
    /// without touching the real Keychain. Production behavior is unchanged.
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
        // Nothing in this app polls the console: refreshes happen on launch, on explicit
        // user action, and after a write. The only recurring work is this tick, which keeps
        // the "expires in 29d 14h" countdown honest — it touches no network.
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        // Let the OS slide the wake by up to a full interval so it can be coalesced with
        // other work. Without a tolerance the system must wake this process at an exact
        // minute boundary forever, which is the difference between a menu-bar utility and a
        // battery drain. The countdown it feeds is minute-granular, so nothing notices.
        tick?.tolerance = 60
        applyDockIcon()
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
            // Two links can point at the same path; first one wins deterministically.
            let byPath = Dictionary(ll.compactMap { s -> (String, ShareItem)? in
                s.fileId.isEmpty ? nil : (s.fileId, s)
            }, uniquingKeysWith: { a, _ in a })

            // Rows that only exist locally — an upload in flight, or one that failed — are not
            // in the server's list, so a refresh that replaces `items` wholesale would make
            // the progress bar vanish mid-transfer.
            //
            // The carry-over used to be unconditional on everything except `.ready`, which made
            // a single missed transition spin forever: the placeholder reappeared on every
            // refresh while the real link sat in `ll` beside it. Each phase now has its own
            // rule, and `.sharing` in particular is dropped the moment the server has a link for
            // that path, so the list self-heals instead of needing a relaunch.
            let localOnly = items.filter { row in
                switch row.phase {
                case .ready:                  return false
                case .failed:                 return true   // stays until dismissed
                case .sharing:                return byPath[row.fileId] == nil
                case .queued, .uploading, .finalizing: return true
                }
            }
            items = localOnly + ll
            linksByPath = byPath
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
            status = "That drop had no readable items in it."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var denied: [String] = []
            var unread = 0
            for provider in files {
                guard let url = await Self.fileURL(from: provider) else { unread += 1; continue }
                switch Self.classify(url) {
                case .upload(let target):
                    await self.upload(target)
                case .zip(let dir):
                    self.status = "Zipping \(dir.lastPathComponent)…"
                    if let zip = await Self.zip(dir) {
                        await self.upload(zip)
                        try? FileManager.default.removeItem(at: zip)
                    } else {
                        denied.append("\u{201c}\(dir.lastPathComponent)\u{201d} could not be zipped")
                    }
                case .deny(let reason):
                    denied.append(reason)
                }
            }
            if !denied.isEmpty {
                self.status = denied.joined(separator: " ")
            } else if unread > 0 {
                self.status = "\(unread) dropped item(s) could not be read."
            }
        }
    }

    enum DropDecision: Equatable {
        case upload(URL)
        case zip(URL)
        case deny(String)
    }

    /// Decide what to do with one dropped path. Every rejection names the item and the
    /// reason — "it failed" is what made this unusable: an .app bundle produced a yellow
    /// triangle and "96 bytes", which told you nothing.
    ///
    /// Measured behavior that drove these rules (`Data(contentsOf:)` result):
    ///   regular file     reads
    ///   0-byte file      reads, 0 B            -> allowed; the console accepts it
    ///   symlink -> file  **throws**            -> must resolve first; this was a real bug
    ///   broken symlink   throws               -> deny with a reason
    ///   directory        throws               -> zip it
    ///   unreadable file  throws               -> deny with a reason
    ///   fifo / socket    throws               -> deny; reading one would block forever
    nonisolated static func classify(_ url: URL) -> DropDecision { classify(url, depth: 0) }

    /// `URL.resolvingSymlinksInPath()` **segfaults** on a dangling symlink, so links are
    /// walked with `readlink` and a hard depth limit instead.
    nonisolated static func classify(_ url: URL, depth: Int) -> DropDecision {
        let name = url.lastPathComponent
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            return .deny("\u{201c}\(name)\u{201d} no longer exists.")
        }
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            guard depth < 8 else {
                return .deny("\u{201c}\(name)\u{201d} is an alias chain that never resolves.")
            }
            var buf = [CChar](repeating: 0, count: 4096)
            let n = readlink(url.path, &buf, buf.count - 1)
            guard n > 0 else {
                return .deny("\u{201c}\(name)\u{201d} is an alias that cannot be read.")
            }
            buf[Int(n)] = 0
            let dest = String(cString: buf)
            let target = dest.hasPrefix("/")
                ? URL(fileURLWithPath: dest)
                : url.deletingLastPathComponent().appendingPathComponent(dest)
            var tst = stat()
            guard lstat(target.path, &tst) == 0 else {
                return .deny("\u{201c}\(name)\u{201d} is an alias to something that is not there.")
            }
            return classify(target, depth: depth + 1)
        case S_IFDIR:
            return .zip(url)
        case S_IFREG:
            guard access(url.path, R_OK) == 0 else {
                return .deny("\u{201c}\(name)\u{201d} is not readable \u{2014} check its permissions.")
            }
            return .upload(url)
        default:
            return .deny("\u{201c}\(name)\u{201d} is a pipe, socket or device, not a file.")
        }
    }

    /// Zip a directory into a temp file and return it. `ditto -c -k --sequesterRsrc` is the
    /// macOS-native archiver: it preserves resource forks, symlinks, permissions and the
    /// code-signature layout that Info-ZIP would flatten — which is exactly what makes an
    /// unzipped .app still launchable.
    static func zip(_ dir: URL) async -> URL? {
        let base = dir.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).zip")
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", dir.path, dest.path]
            p.terminationHandler = { proc in
                let ok = proc.terminationStatus == 0
                    && FileManager.default.fileExists(atPath: dest.path)
                cont.resume(returning: ok ? dest : nil)
            }
            do { try p.run() } catch { cont.resume(returning: nil) }
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
        // Immediate text feedback. A large file can sit in CRC32 + the first few chunks
        // before the bar moves visibly, and "is it doing anything?" should never be a question.
        status = "Uploading \(url.lastPathComponent)…"

        let box = UploadBox()
        let pendingID = item.id
        let watcher = Task { @MainActor in
            for await sig in box.stream {
                guard let i = items.firstIndex(where: { $0.id == pendingID }) else { continue }
                switch sig {
                case .progress(let p):
                    items[i].phase = .uploading(p)
                    items[i].progress = p
                case .note(let n):
                    // The client knows which phase has no byte count; the view should not
                    // have to guess it from a progress value that has stopped moving.
                    items[i].phase = .finalizing
                    status = n
                }
            }
        }

        do {
            // Passing `note` is the whole point: the protocol has a default that swallows it,
            // so dropping the argument compiles fine and silently loses the only explanation
            // the user gets during the post-100% finalize wait.
            let done = try await client.upload(from: url, to: dir,
                                               progress: { box.send($0) },
                                               note: { box.note($0) })
            item = done
            if let i = items.firstIndex(where: { $0.id == pendingID }) {
                items[i] = done
            } else if let i = items.firstIndex(where: { $0.localPath == url && !$0.phase.isTerminal }) {
                items[i] = done
            } else {
                items.insert(done, at: 0)
            }
            // then create the share
            if let i = items.firstIndex(where: { $0.id == done.id }) {
                items[i].phase = .sharing
            }
            status = "Creating link for \(done.name)…"
            let shared = try await client.createShare(for: done.fileId,
                                                      expiration: defaultExpiration,
                                                      password: nil)
            if let i = items.firstIndex(where: { $0.fileId == done.fileId }) {
                items[i] = shared
            } else {
                items.insert(shared, at: 0)
            }
            status = ""
            toast = "Shared \(shared.name)"
            if copyOnUpload, let u = shared.shareURL { copy(u.absoluteString, label: "Link copied") }
        } catch {
            // Prefer the placeholder by localPath, but fall back to the id it was inserted
            // with. If a replacement dropped the localPath this is the only way the row gets
            // marked, and without it the spinner runs forever.
            let i = items.firstIndex(where: { $0.localPath == url && !$0.phase.isTerminal })
                    ?? items.firstIndex(where: { $0.id == pendingID })
            if let i { items[i].phase = .failed(error.localizedDescription) }
            status = error.localizedDescription
        }
        box.finish()
        watcher.cancel()
        // Re-read the folder we actually dropped into, so the new file shows up even if the
        // user moved on in the meantime.
        await refresh()
        // The server row now exists; drop the local placeholder so it is not shown twice.
        items.removeAll { $0.localPath == url && $0.phase != .ready && $0.id != "" &&
                         linksByPath[$0.fileId] != nil }
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

    /// The row whose actions are currently expanded in the menu bar.
    @Published var openRowID: String?

    /// One click on a menu-bar row.
    ///
    /// Live link → copy. Anything else → expand that row's own actions instead of refusing
    /// silently, because "not shared yet" and "this expired" want different next moves and a
    /// toast that vanishes in 1.8 s is not a conversation.
    func tap(_ item: ShareItem) {
        switch RowTapPolicy.decide(item, now: Date(), demo: usingMock) {
        case .copy(let url):
            copy(url.absoluteString, label: "Link copied")
            openRowID = nil
        case .offer:
            openRowID = (openRowID == item.id) ? nil : item.id
        }
    }

    /// Give a row a link, replacing one that is already dead.
    ///
    /// Only reachable from `RowAction.reShare`, which the policy offers solely for an expired
    /// link or an unshared file. That restriction is the whole safety argument: recreating a
    /// link rotates its token, so doing it to a **live** link would invalidate a URL the user
    /// may already have sent. An expired URL is failing anyway, so there is nothing to break.
    func reShare(_ item: ShareItem) async {
        guard !item.fileId.isEmpty else {
            status = "Nothing to share — the file is not on the Drive"
            return
        }
        do {
            // Best effort: an expired link may already be pruned server-side, and a row with
            // no link has nothing to delete. Neither should stop the new link being made.
            if item.phase == .ready, !item.id.isEmpty {
                _ = try? await client.delete(item)
            }
            let made = try await client.createShare(for: item.fileId,
                                                    expiration: defaultExpiration,
                                                    password: nil)
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i] = made
            } else {
                items.insert(made, at: 0)
            }
            openRowID = nil
            status = ""
            if let u = made.shareURL {
                copy(u.absoluteString, label: "New link copied")
            } else {
                toast = "Link created"
            }
        } catch {
            status = error.localizedDescription
        }
    }

    @discardableResult
    func copy(_ s: String, label: String = "Copied") -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        // setString returns false when the pasteboard refuses — secure input, or another
        // process holding it. Saying "Link copied" after that is a lie that only surfaces
        // when the paste comes up empty somewhere else.
        // Verify rather than assume. setString returns false under secure input or when
        // another process holds the pasteboard, and reading the value back also catches a
        // write that "succeeds" but is immediately overwritten.
        let ok = pb.setString(s, forType: .string)
        guard ok, pb.string(forType: .string) == s else {
            status = "Clipboard refused the write — copy it from the window"
            return false
        }
        showToast(label)
        return true
    }

    /// Show a transient confirmation, restarting the timer even if the text is unchanged.
    ///
    /// The previous version slept in a fresh Task and cleared on `toast == label`, so a second
    /// click within 1.8 s left the *first* task in charge of hiding a message the user had just
    /// re-triggered — the toast vanished early, right after the click that should have made it
    /// look most solid.
    func showToast(_ s: String) {
        toast = s
        toastID &+= 1
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.toast = nil }
        }
    }

    /// Drop a failed row out of the list without retrying it.
    func dismiss(_ item: ShareItem) {
        items.removeAll { $0.id == item.id }
        if uploadingCount == 0 { status = "" }
    }

    func setExpiration(_ item: ShareItem, _ exp: Expiration) async {
        do {
            let updated = try await client.setExpiration(item, exp)
            // Changing expiry recreates the link, so the id and token both change. Matching on
            // the old id would leave the stale row on screen.
            if let i = items.firstIndex(where: { $0.fileId == item.fileId }) {
                items[i] = updated
            } else {
                items.removeAll { $0.id == item.id }
                items.insert(updated, at: 0)
            }
            // The URL the user may already have pasted somewhere is now dead. Saying
            // "Expiry set" would be a lie by omission, and copying silently would be worse.
            toast = updated.shareURL == item.shareURL
                ? "Expiry set"
                : "New link created — the old URL no longer works"
            if copyOnUpload, let u = updated.shareURL { copy(u.absoluteString, label: "New link copied") }
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
private enum UploadSignal: Sendable {
    case progress(Double)
    case note(String)
}

/// Progress and phase notes travel down **one** stream so their order survives.
///
/// Separate streams would let "Finalizing on the console\u{2026}" overtake the final percentage
/// and then get overwritten by it — the exact confusion this channel exists to remove.
private final class UploadBox: @unchecked Sendable {
    private let made = AsyncStream<UploadSignal>.makeStream()
    var stream: AsyncStream<UploadSignal> { made.stream }
    func send(_ v: Double) { made.continuation.yield(.progress(v)) }
    func note(_ s: String) { made.continuation.yield(.note(s)) }
    func finish() { made.continuation.finish() }
}
