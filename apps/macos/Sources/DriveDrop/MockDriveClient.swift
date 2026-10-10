import Foundation

/// Offline stand-in so the UI is fully usable before the console payloads are pinned down.
/// Selected automatically when no credentials are configured.
/// An actor rather than a lock-guarded class: every DriveClient method is already `async`,
/// so isolation is free, and `NSLock.lock()` is unavailable from async contexts (a warning
/// today, a hard error in Swift 6).
actor MockDriveClient: DriveClient {
    private var store: [ShareItem] = [
        // Deliberately NOT the real console host. Demo links that look like
        // get copied into Slack and then fail with no explanation.
        // .invalid is reserved by RFC 2606 and can never resolve.
        ShareItem(id: "sh_1", fileId: "/mydrive/Public/site-plan.pdf", name: "site-plan.pdf", size: 2_411_724,
                  shareURL: URL(string: "https://demo.invalid/8f2c1a9e"),
                  directURL: nil, createdAt: .now.addingTimeInterval(-7_200),
                  expiresAt: .now.addingTimeInterval(3*86_400), phase: .ready, progress: 1),
        ShareItem(id: "sh_2", fileId: "/mydrive/Public/garage-clip.mov", name: "garage-clip.mov", size: 92_274_688,
                  shareURL: URL(string: "https://demo.invalid/1be77d04"),
                  directURL: nil, createdAt: .now.addingTimeInterval(-86_400),
                  expiresAt: .now.addingTimeInterval(40*60), phase: .ready, progress: 1),
    ]

    func login() async throws { try await Task.sleep(for: .milliseconds(250)) }

    func usage() async throws -> Usage { Usage(usedBytes: 3_724_542_208, totalBytes: 15_999_766_528) }

    func list() async throws -> [ShareItem] {
        return store
    }

    /// Mirrors the real join key: absolute `/mydrive/...` paths.
    func browse(_ dir: String) async throws -> [FileEntry] {
        try await Task.sleep(for: .milliseconds(200))
        let d = DrivePath.canonical(dir)
        if d == "/" {
            return [FileEntry(path: "/mydrive/Public", name: "Public", size: 0, isDir: true, modifyTime: .now)]
        }
        guard d == "/Public" else { return [] }
        let items = store
        return items.map {
            FileEntry(path: $0.fileId, name: $0.name, size: $0.size, isDir: false, modifyTime: $0.createdAt)
        }
    }

    func upload(from url: URL, to folder: String,
                progress: @escaping @Sendable (Double) -> Void,
                note: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ShareItem {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        var p = 0.0
        while p < 1 {
            try await Task.sleep(for: .milliseconds(90))
            p = min(1, p + Double.random(in: 0.06...0.18))
            progress(p)
        }
        try await Task.sleep(for: .milliseconds(300))
        let id = DrivePath.absolutePrefix(folder) + "/" + url.lastPathComponent
        let item = ShareItem(id: "sh_\(UUID().uuidString.prefix(6))", fileId: id,
                             name: url.lastPathComponent, size: size,
                             shareURL: URL(string: "https://demo.invalid/\(UUID().uuidString.prefix(8).lowercased())"),
                             directURL: nil, createdAt: .now,
                             expiresAt: Date().addingTimeInterval(604_800),
                             phase: .ready, progress: 1, localPath: url)
        store.insert(item, at: 0)
        return item
    }

    func createShare(for fileId: String, expiration: Expiration, password: String?) async throws -> ShareItem {
        try await Task.sleep(for: .milliseconds(200))
        guard let i = store.firstIndex(where: { $0.fileId == fileId }) else {
            throw DriveError.transport("unknown file \(fileId)")
        }
        store[i].expiresAt = expiration.date
        return store[i]
    }

    func setExpiration(_ item: ShareItem, _ expiration: Expiration) async throws -> ShareItem {
        try await Task.sleep(for: .milliseconds(150))
        guard let i = store.firstIndex(where: { $0.id == item.id }) else { return item }
        store[i].expiresAt = expiration.date
        return store[i]
    }

    func delete(_ item: ShareItem) async throws {
        try await Task.sleep(for: .milliseconds(150))
        store.removeAll { $0.id == item.id }
    }
}
