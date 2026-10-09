import Foundation

// Concurrency regression tests for AppModel. Run with scripts/test-races.sh.
//
// These exist because three real races shipped in the first cut of the folder-aware model:
//   1. refresh() wrote usage/items/linksByPath before its generation guard, so a slow older
//      fetch finishing last overwrote newer data.
//   2. isBusy was a bool, so the first finishing refresh hid the spinner while others were
//      still in flight.
//   3. bootstrap()'s Keychain read can block for seconds behind the macOS access prompt; if
//      the user saved new credentials meanwhile, the stale read applied afterwards and
//      silently restored the old session.
//
// Each test is written to FAIL against that original code — verified by patching the guards
// back out and re-running. A concurrency test that passes either way proves nothing.

final class FakeClient: DriveClient, @unchecked Sendable {
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
                progress: @escaping @Sendable (Double) -> Void) async throws -> ShareItem {
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

var failures = 0
func expect(_ ok: Bool, _ what: String, _ detail: String = "") {
    print("  \(ok ? "PASS" : "FAIL")  \(what)")
    if !detail.isEmpty { print("          \(detail)") }
    if !ok { failures += 1 }
}

Task { @MainActor in
    // 1 ------------------------------------------------------------------------------
    // Refresh A starts first but finishes last. Its data must be discarded.
    do {
        let f = FakeClient()
        f.behaviors = [.init(delay: 0.5, tag: "OLD"), .init(delay: 0.01, tag: "NEW")]
        let m = AppModel(forTesting: f)
        async let a = m.refresh()
        try? await Task.sleep(for: .milliseconds(80))
        async let b = m.refresh()
        _ = await (a, b)
        expect(m.items.first?.name == "NEW", "stale refresh does not clobber newer data",
               "final item = \(m.items.first?.name ?? "none")")
    }

    // 2 ------------------------------------------------------------------------------
    // The spinner must stay up until the *last* refresh finishes, not the first.
    do {
        let f = FakeClient()
        f.behaviors = [.init(delay: 0.5, tag: "A"), .init(delay: 0.05, tag: "B")]
        let m = AppModel(forTesting: f)
        async let a = m.refresh()
        try? await Task.sleep(for: .milliseconds(60))
        async let b = m.refresh()
        try? await Task.sleep(for: .milliseconds(250))   // B done, A still running
        let mid = m.isBusy
        _ = await (a, b)
        expect(mid == true, "isBusy still true while one refresh remains", "mid=\(mid)")
        expect(m.isBusy == false, "isBusy cleared once both finished", "after=\(m.isBusy)")
    }

    // 3 ------------------------------------------------------------------------------
    // A blocked Keychain read must lose to a save the user made while it was blocked.
    do {
        AppModel.keychainRead = { _ in
            Thread.sleep(forTimeInterval: 0.5)            // the securityd access prompt
            return "OLDPW"
        }
        AppModel.keychainWrite = { _, _ in }
        let m = AppModel(forTesting: MockDriveClient())
        m.reload()                                        // epoch 1, read blocks
        try? await Task.sleep(for: .milliseconds(100))
        m.saveCredentials(host: "192.0.2.10", user: "***REMOVED***", pass: "NEWPW")  // epoch 2
        try? await Task.sleep(for: .seconds(1.2))
        let pw = (m.client as? LiveDriveClient)?.session.password ?? "none"
        expect(pw == "NEWPW", "stale Keychain read does not undo a newer save",
               "live session password = \(pw)")
        expect(m.ready, "ready reflects the newest epoch")
    }

    print(failures == 0 ? "\nALL RACES PASSED" : "\n\(failures) RACE(S) FAILED")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
