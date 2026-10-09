import Foundation

// Concurrency regression tests for AppModel. Run with scripts/test-races.sh.
//
// Each test must FAIL against the code it replaced. That is not ceremony: the first version
// of the isBusy test passed while the code was still broken, because it sampled `isBusy`
// after the second refresh's `defer` had already run. Only a test aimed at a lone refresh
// exposed it. Prefer the narrowest observation that distinguishes the two.

// --------------------------------------------------------------------------- fakes

final class ScriptedClient: DriveClient, @unchecked Sendable {
    struct Behavior { let delay: Double; let tag: String }
    var behaviors: [Behavior] = []
    var n = 0

    func login() async throws {}
    func usage() async throws -> Usage { Usage(usedBytes: 1, totalBytes: 2) }

    func list() async throws -> [ShareItem] {
        n += 1
        let b = behaviors[min(n - 1, behaviors.count - 1)]
        if b.delay > 0 { try? await Task.sleep(for: .seconds(b.delay)) }
        return [ShareItem(id: b.tag, fileId: "/mydrive/\(b.tag).txt", name: b.tag, size: 1,
                          shareURL: nil, directURL: nil, createdAt: .now, expiresAt: nil,
                          phase: .ready, progress: 1)]
    }

    func browse(_ d: String) async throws -> [FileEntry] { [] }

    func upload(from url: URL, to folder: String,
                progress: @escaping @Sendable (Double) -> Void,
                note: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ShareItem {
        throw DriveError.unsupported("not used in race tests")
    }
    func createShare(for fileId: String, expiration: Expiration,
                     password: String?) async throws -> ShareItem {
        throw DriveError.unsupported("not used in race tests")
    }
    func setExpiration(_ i: ShareItem, _ e: Expiration) async throws -> ShareItem {
        throw DriveError.unsupported("not used in race tests")
    }
    func delete(_ i: ShareItem) async throws {}
}

/// A client whose every call takes the same fixed time, for single-refresh assertions.
final class UniformClient: DriveClient, @unchecked Sendable {
    let delay: Double
    init(delay: Double) { self.delay = delay }
    func login() async throws {}
    func usage() async throws -> Usage {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return Usage(usedBytes: 1, totalBytes: 2)
    }
    func list() async throws -> [ShareItem] {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return []
    }
    func browse(_ d: String) async throws -> [FileEntry] {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return []
    }
    func upload(from url: URL, to folder: String,
                progress: @escaping @Sendable (Double) -> Void,
                note: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ShareItem {
        throw DriveError.unsupported("not used in race tests")
    }
    func createShare(for fileId: String, expiration: Expiration,
                     password: String?) async throws -> ShareItem {
        throw DriveError.unsupported("not used in race tests")
    }
    func setExpiration(_ i: ShareItem, _ e: Expiration) async throws -> ShareItem {
        throw DriveError.unsupported("not used in race tests")
    }
    func delete(_ i: ShareItem) async throws {}
}

/// Stand-in for the Keychain: records what "disk" holds, can be made slow.
final class FakeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    var writeDelay: Double = 0

    init(_ initial: String) { value = initial }

    func read() -> String { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ pw: String) {
        if writeDelay > 0 { Thread.sleep(forTimeInterval: writeDelay) }
        lock.lock(); value = pw; lock.unlock()
    }
    var current: String { lock.lock(); defer { lock.unlock() }; return value }
}

var failures = 0
func expect(_ ok: Bool, _ what: String, _ detail: String = "") {
    print("  \(ok ? "PASS" : "FAIL")  \(what)")
    if !detail.isEmpty { print("          \(detail)") }
    if !ok { failures += 1 }
}

func pendingRow(_ tag: String) -> ShareItem {
    ShareItem(id: "pending-\(tag)", fileId: "", name: tag, size: 10, shareURL: nil,
              directURL: nil, createdAt: .now, expiresAt: nil, phase: .uploading(0.5),
              progress: 0.5)
}

Task { @MainActor in

    // 1 -- a slow refresh must not clobber a newer one ----------------------------------
    do {
        let f = ScriptedClient()
        f.behaviors = [.init(delay: 0.5, tag: "OLD"), .init(delay: 0.01, tag: "NEW")]
        let m = AppModel(forTesting: f)
        async let a = m.refresh()
        try? await Task.sleep(for: .milliseconds(80))
        async let b = m.refresh()
        _ = await (a, b)
        expect(m.items.first?.name == "NEW", "stale refresh does not clobber newer data",
               "final item = \(m.items.first?.name ?? "none")")
    }

    // 2 -- a LONE refresh must show the spinner -----------------------------------------
    // Sampling after a second refresh hides this; sample the single case directly.
    do {
        let m = AppModel(forTesting: UniformClient(delay: 0.3))
        async let r = m.refresh()
        try? await Task.sleep(for: .milliseconds(120))
        let mid = m.isBusy
        _ = await r
        expect(mid == true, "lone refresh shows the spinner while in flight", "mid=\(mid)")
        expect(m.isBusy == false, "spinner cleared once it finishes")
    }

    // 3 -- overlapping refreshes: spinner survives the first finisher -------------------
    do {
        let f = ScriptedClient()
        f.behaviors = [.init(delay: 0.5, tag: "A"), .init(delay: 0.05, tag: "B")]
        let m = AppModel(forTesting: f)
        async let a = m.refresh()
        try? await Task.sleep(for: .milliseconds(60))
        async let b = m.refresh()
        try? await Task.sleep(for: .milliseconds(250))   // B done, A still running
        let mid = m.isBusy
        _ = await (a, b)
        expect(mid == true, "spinner stays up while one refresh remains", "mid=\(mid)")
        expect(m.isBusy == false, "spinner cleared once both finished")
    }

    // 4 -- a blocked Keychain read must not undo a later save ----------------------------
    do {
        let store = FakeStore("OLDPW")
        AppModel.keychainRead = { _ in Thread.sleep(forTimeInterval: 0.5); return store.read() }
        AppModel.keychainWrite = { pw, _ in store.write(pw) }
        let m = AppModel(forTesting: MockDriveClient())
        m.reload()                                        // epoch 1, read blocks
        try? await Task.sleep(for: .milliseconds(100))
        m.saveCredentials(host: "192.0.2.10", user: "***REMOVED***", pass: "NEWPW")   // epoch 2
        try? await Task.sleep(for: .seconds(1.2))
        let pw = (m.client as? LiveDriveClient)?.session.password ?? "none"
        expect(pw == "NEWPW", "stale Keychain read does not undo a newer save",
               "session password = \(pw)")
        expect(m.ready, "ready reflects the newest epoch")
    }

    // 5 -- credential writes stay in epoch order -----------------------------------------
    // Without serialisation the older, slower write can land last and the Keychain ends up
    // holding a password the app no longer believes in.
    do {
        let store = FakeStore("SEED")
        AppModel.keychainRead = { _ in store.read() }
        AppModel.keychainWrite = { pw, _ in store.write(pw) }
        let m = AppModel(forTesting: MockDriveClient())
        store.writeDelay = 0.4
        m.saveCredentials(host: "h", user: "u", pass: "SLOW")     // epoch 1, slow write
        try? await Task.sleep(for: .milliseconds(60))
        store.writeDelay = 0
        m.clearSavedPassword()                                     // epoch 2, fast write
        try? await Task.sleep(for: .seconds(1.2))
        expect(store.current == "", "credential writes land in epoch order",
               "keychain holds \(store.current.debugDescription)")
    }

    // 6 -- a superseded bootstrap must not leave the prompt warning stuck ---------------
    do {
        let store = FakeStore("PW")
        AppModel.keychainRead = { _ in Thread.sleep(forTimeInterval: 0.6); return store.read() }
        AppModel.keychainWrite = { pw, _ in store.write(pw) }
        let m = AppModel(forTesting: MockDriveClient())
        m.reload()                                                 // epoch 1, slow
        try? await Task.sleep(for: .milliseconds(300))             // warn fires here
        m.saveCredentials(host: "h", user: "u", pass: "NEW")       // epoch 2 owns status
        try? await Task.sleep(for: .seconds(1.4))
        expect(m.status != "Waiting for macOS Keychain approval…",
               "superseded bootstrap does not strand the approval warning",
               "status = \(m.status.debugDescription)")
    }

    // 7 -- an in-flight upload row survives a refresh -----------------------------------
    do {
        let f = ScriptedClient()
        f.behaviors = [.init(delay: 0, tag: "SERVER")]
        let m = AppModel(forTesting: f)
        m.items = [pendingRow("big.mov")]
        await m.refresh()
        let survived = m.items.contains { $0.name == "big.mov" }
        expect(survived, "uploading row is not wiped by a refresh",
               "items = \(m.items.map(\.name))")
        expect(m.items.contains { $0.name == "SERVER" }, "server rows still present after merge")
        // The folder view renders entries, not items, so it reads inFlight explicitly.
        expect(m.inFlight.contains { $0.name == "big.mov" },
               "inFlight exposes the pending row for the folder view")
    }

    // 8 -- drop policy: allow gracefully, or deny with a reason -------------------------
    do {
        let base = NSTemporaryDirectory() + "dd-classify-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let good = base + "/good.txt"
        try "hi".data(using: .utf8)!.write(to: URL(fileURLWithPath: good))
        FileManager.default.createFile(atPath: base + "/empty.bin", contents: Data())
        try FileManager.default.createDirectory(atPath: base + "/afolder", withIntermediateDirectories: true)
        symlink("good.txt", base + "/link.txt")            // dangling-free link
        symlink("nowhere", base + "/dangling.txt")         // broken link: used to SIGSEGV
        symlink("loopb.txt", base + "/loopa.txt")
        symlink("loopa.txt", base + "/loopb.txt")
        mkfifo((base + "/pipe").cString(using: .utf8), 0o644)

        let cases: [(String, String)] = [
            ("good.txt", "upload"), ("empty.bin", "upload"), ("link.txt", "upload"),
            ("dangling.txt", "deny"), ("loopa.txt", "deny"), ("pipe", "deny"),
            ("afolder", "zip"), ("gone.txt", "deny"),
        ]
        var bad: [String] = []
        for (name, want) in cases {
            let d = AppModel.classify(URL(fileURLWithPath: base + "/" + name))
            let got: String
            switch d {
            case .upload: got = "upload"
            case .zip:    got = "zip"
            case .deny:   got = "deny"
            }
            if got != want { bad.append("\(name): got \(got) want \(want)") }
        }
        expect(bad.isEmpty, "drop policy classifies every shape correctly", bad.joined(separator: "; "))
        try? FileManager.default.removeItem(atPath: base)
    }

    print(failures == 0 ? "\nALL RACES PASSED" : "\n\(failures) RACE(S) FAILED")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
