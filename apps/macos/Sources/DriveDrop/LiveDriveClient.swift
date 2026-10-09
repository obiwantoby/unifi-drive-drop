import Foundation

/// Real client against the console.
///
/// Every endpoint here is VERIFIED against 192.0.2.10 (Drive 4.4.9 / UniFi OS 4.0.4);
/// see spec/api.md. Anything still unproven is marked and fails loudly rather than
/// inventing a value.
final class LiveDriveClient: DriveClient, @unchecked Sendable {
    let session: DriveSession

    /// Visitor-facing share page. Verified: the URL carries the link **token**, not the id.
    static let shareWebBase = "https://drop.ui.com"

    init(session: DriveSession) { self.session = session }

    // MARK: - helpers

    private func requireOK(_ r: DriveSession.Response, _ what: String) throws -> Any? {
        guard (200...299).contains(r.status) else {
            if let j = r.json as? [String: Any] {
                if let err = j["err"] as? [String: Any], let m = err["msg"] as? String {
                    throw DriveError.status(r.status, "\(what): \(m)")
                }
                if let err = j["error"] as? [String: Any], let m = err["message"] as? String {
                    throw DriveError.status(r.status, "\(what): \(m)")
                }
            }
            let body = String(data: r.data, encoding: .utf8) ?? ""
            throw DriveError.status(r.status, "\(what): \(body.prefix(200))")
        }
        return r.json
    }

    /// Drive returns `{err,type,data}`; unwrap `data` when present.
    private func payload(_ json: Any?) -> Any? {
        (json as? [String: Any])?["data"] ?? json
    }

    private static let outFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let inFormatters: [ISO8601DateFormatter] = {
        let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
        return [a, b]
    }()

    /// Wire format accepted by POST/PATCH file-sharing/links.
    private static func wire(_ d: Date) -> String { outFormatter.string(from: d) }

    private static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        for f in inFormatters { if let x = f.date(from: s) { return x } }
        return nil
    }

    private static func int(_ s: Any?) -> Int64 {
        if let d = s as? Double { return Int64(d) }
        if let i = s as? Int { return Int64(i) }
        if let n = s as? NSNumber { return n.int64Value }
        if let t = s as? String { return Int64(t) ?? 0 }
        return 0
    }

    /// Percent-encode each path segment, leaving the separators intact.
    static func encodePath(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    /// Map a local drop target onto a Drive absolute path.
    static func drivePath(folder: String, name: String) -> String {
        let rel = folder.hasPrefix("/") ? String(folder.dropFirst()) : folder
        let parts = ([rel, name] as [String]).filter { !$0.isEmpty }
        return "/mydrive/" + parts.joined(separator: "/")
    }

    private func mapLink(_ l: [String: Any]) -> ShareItem? {
        guard let id = l["id"] as? String else { return nil }
        let token = l["token"] as? String
        let path = l["path"] as? String ?? ""
        let res = l["resource"] as? [String: Any] ?? [:]
        let name = (res["name"] as? String) ?? path.split(separator: "/").last.map(String.init) ?? id

        var item = ShareItem(
            id: id,
            fileId: path,
            name: name,
            size: Self.int(res["size"]),
            shareURL: token.flatMap { URL(string: "\(Self.shareWebBase)/\($0)") },
            directURL: nil,
            createdAt: Self.date(l["createdAt"] ?? l["createTime"] ?? l["addTime"]) ?? Date(),
            expiresAt: Self.date(l["expiresAt"]),
            phase: .ready,
            progress: 1
        )
        // Owner-side direct link. Needs our session cookie, so it is NOT a share URL.
        //
        // The trailing segment is the resource NAME, not the drive-qualified path. Sending
        // `/mydrive/Public/x.txt` here returns 403 ErrForbidden; `x.txt` returns the bytes.
        // Verified against the console: qualified -> 403, basename -> 200.
        if let rp = res["path"] as? String ?? path.components(separatedBy: "/").last {
            item.directURL = directLink(id: id, name: rp)
        }
        return item
    }

    // MARK: - DriveClient

    func login() async throws { try await session.login() }

    /// VERIFIED: GET /proxy/drive/api/v2/storage  (fields are `capacity` / `usage`)
    func usage() async throws -> Usage {
        let r = try await session.send("GET", "/proxy/drive/api/v2/storage")
        _ = try requireOK(r, "usage")
        guard let pools = payload(r.json) as? [String: Any],
              let arr = pools["pools"] as? [[String: Any]] else {
            throw DriveError.decoding("no pools in storage body")
        }
        var used: Int64 = 0, total: Int64 = 0
        for p in arr {
            total += Self.int(p["capacity"])
            used += Self.int(p["usage"])
        }
        return Usage(usedBytes: used, totalBytes: total)
    }

    /// VERIFIED: GET /proxy/drive/api/v1/file-sharing/links
    func list() async throws -> [ShareItem] {
        let r = try await session.send("GET", "/proxy/drive/api/v1/file-sharing/links")
        _ = try requireOK(r, "list")
        let rows = payload(r.json) as? [[String: Any]] ?? []
        return rows.compactMap(mapLink)
    }

    /// Contents of one folder. Verified: children arrive under `data.items`, each `path`
    /// already absolute (`/mydrive/Public/foo.zip`), which is the same form `link.path`
    /// uses — so entries and links join on `path` with no translation.
    func browse(_ dir: String) async throws -> [FileEntry] {
        let r = try await session.send("GET", Self.encodePath(DrivePath.listingPath(dir)))
        _ = try requireOK(r, "browse")
        guard let obj = payload(r.json) as? [String: Any] else { return [] }
        let rows = obj["items"] as? [[String: Any]] ?? []
        let out = rows.compactMap { e -> FileEntry? in
            guard let p = e["path"] as? String else { return nil }
            return FileEntry(
                path: p,
                name: (e["name"] as? String) ?? p.split(separator: "/").last.map(String.init) ?? p,
                size: Self.int(e["size"]),
                isDir: e["isDir"] as? Bool ?? false,
                modifyTime: Self.date(e["modifyTime"])
            )
        }
        return out.sorted { a, b in
            a.isDir != b.isDir ? a.isDir : a.name.lowercased() < b.name.lowercased()
        }
    }

    /// VERIFIED: POST /proxy/drive/api/v1/file-sharing/links
    /// `fileId` is the Drive path, e.g. `/mydrive/report.pdf`.
    func createShare(for fileId: String, expiration: Expiration, password: String?) async throws -> ShareItem {
        var body: [String: Any] = ["type": "public", "path": fileId, "accessLimit": 0]
        if let d = expiration.date { body["expiresAt"] = Self.wire(d) }
        if let p = password, !p.isEmpty { body["password"] = p }   // password support unverified
        let data = try JSONSerialization.data(withJSONObject: body)

        let r = try await session.send("POST", "/proxy/drive/api/v1/file-sharing/links",
                                       body: data, contentType: "application/json")
        _ = try requireOK(r, "createShare")
        guard let j = payload(r.json) as? [String: Any],
              let id = j["id"] as? String,
              let token = j["token"] as? String else {
            throw DriveError.decoding("link created without id/token: "
                + String(data: r.data, encoding: .utf8)!.prefix(300))
        }
        let res = j["resource"] as? [String: Any] ?? [:]
        var item = ShareItem(
            id: id,
            fileId: j["path"] as? String ?? fileId,
            name: (res["name"] as? String) ?? fileId,
            size: Self.int(res["size"]),
            shareURL: URL(string: "\(Self.shareWebBase)/\(token)"),
            directURL: nil,
            createdAt: Date(),
            expiresAt: Self.date(j["expiresAt"]) ?? expiration.date,
            phase: .ready,
            progress: 1
        )
        if let rp = res["path"] as? String {
            item.directURL = directLink(id: id, name: rp)
        }
        return item
    }

    /// VERIFIED: PATCH /proxy/drive/api/v1/file-sharing/links/{id}  (PUT is not a route)
    func setExpiration(_ item: ShareItem, _ expiration: Expiration) async throws -> ShareItem {
        var body: [String: Any] = [:]
        if let d = expiration.date { body["expiresAt"] = Self.wire(d) }
        let data = try JSONSerialization.data(withJSONObject: body)
        let r = try await session.send("PATCH", "/proxy/drive/api/v1/file-sharing/links/\(item.id)",
                                       body: data, contentType: "application/json")
        _ = try requireOK(r, "setExpiration")
        var out = item
        out.expiresAt = expiration.date
        return out
    }

    /// VERIFIED: DELETE /proxy/drive/api/v1/file-sharing/links/{id} -> {"data":"OK"}
    func delete(_ item: ShareItem) async throws {
        let r = try await session.send("DELETE", "/proxy/drive/api/v1/file-sharing/links/\(item.id)")
        _ = try requireOK(r, "delete")
    }

    /// VERIFIED: DELETE /proxy/drive/api/v1/resources/{path} -> moves to /trash
    func deleteFile(path: String) async throws {
        let r = try await session.send("DELETE",
                    "/proxy/drive/api/v1/resources\(Self.encodePath(path))")
        _ = try requireOK(r, "deleteFile")
    }

    // MARK: - upload

    /// VERIFIED upload. The two things that are easy to get wrong:
    ///   1. `Location:` is relative to the *Drive service* root, so it must be prefixed
    ///      with `/proxy/drive` — PATCHing the bare path 404s.
    ///   2. `checksum` must be the file's real CRC32. Every PATCH answers 204 even when it
    ///      is wrong; the session is only discarded at finalize, so a bad checksum looks
    ///      like success until the object never appears.
    /// `dir` is relative to the **personal-drive root** and — verified — is created on
    /// demand by the upload itself, so no mkdir round-trip is needed for `/Public`.
    /// Normalized so "Public", "Public/" and "/Public/" all mean the same thing.
    /// Poll `GET /resources/<path>` until the object is queryable, or `timeout` elapses.
    static func waitForObject(_ path: String, session: DriveSession,
                              timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var delay: UInt64 = 250_000_000          // 0.25 s, backing off to 2 s
        while Date() < deadline {
            if let r = try? await session.send("GET",
                        "/proxy/drive/api/v1/resources\(Self.encodePath(path))"),
               (200...299).contains(r.status) {
                return true
            }
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 2_000_000_000)
        }
        return false
    }

    /// `GET /file-sharing/links/{id}/files/{resourceName}` — owner-side direct download.
    /// `resourceName` is the file's name; the drive-qualified path is rejected with 403.
    func directLink(id: String, name: String) -> URL? {
        let base = name.components(separatedBy: "/").filter { !$0.isEmpty }.last ?? name
        return URL(string: "\(session.host)/proxy/drive/api/v1/file-sharing/links/\(id)/files/\(Self.encodePath(base))")
    }

    static func normalizeDir(_ f: String) -> String {
        // Rebuild from the non-empty segments: one pass drops a trailing slash, a doubled
        // slash and a missing leading slash. The server trims none of these for you.
        let parts = f
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .filter { !$0.isEmpty && $0 != "." }
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    func upload(from url: URL, to folder: String,
                progress: @escaping @Sendable (Double) -> Void,
                note: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ShareItem {
        // mappedIfSafe keeps a 200 MB file out of RAM, but it fails on anything the kernel
        // will not mmap, so fall back to a plain read instead of erroring out.
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { data = try Data(contentsOf: url) }
        let size = Int64(data.count)
        let dir = Self.normalizeDir(folder)

        let meta: [String] = [
            "filename \(b64(url.lastPathComponent))",
            "dir \(b64(dir))",
            "task-id \(b64(UUID().uuidString.lowercased()))",
            "checksum \(b64(CRC32.hex(data)))",
        ]

        let create = try await session.send(
            "POST", "/proxy/drive/api/v1/files",
            extraHeaders: ["Upload-Length": String(size),
                           "Upload-Metadata": meta.joined(separator: ","),
                           "Tus-Resumable": "1.0.0"]
        )
        guard (200...299).contains(create.status), let loc = create.string("Location") else {
            throw DriveError.status(create.status, "upload create rejected: "
                + String(data: create.data, encoding: .utf8)!.prefix(200))
        }
        // "/api/v1/files/<id>" -> "/proxy/drive/api/v1/files/<id>"
        let uploadPath = loc.hasPrefix("/api/") ? "/proxy/drive" + loc : loc

        var pos = Int(create.string("Upload-Offset").flatMap(Int.init) ?? 0)
        let total = data.count
        while pos < total {
            let end = min(pos + Self.chunkSize, total)
            let buf = data.subdata(in: pos..<end)
            let r = try await session.send("PATCH", uploadPath, body: buf,
                                           contentType: "application/offset+octet-stream",
                                           extraHeaders: ["Upload-Offset": String(pos),
                                                          "Tus-Resumable": "1.0.0"])
            guard (200...299).contains(r.status) else {
                throw DriveError.status(r.status, "upload chunk rejected at offset \(pos)")
            }
            pos = r.string("Upload-Offset").flatMap(Int.init) ?? end
            progress(total > 0 ? Double(pos) / Double(total) : 1)
        }
        progress(1)

        // tus finalize is asynchronous: the last PATCH answers 204 but the object is not
        // queryable yet, and a share link created inside that window fails. Poll instead of
        // checking once (a single check spuriously fails on a busy console), and say what we
        // are waiting on — progress is already at 100% here, so silence reads as a hang.
        let target = Self.drivePath(folder: folder, name: url.lastPathComponent)
        note("Finalizing on the console\u{2026}")
        guard await Self.waitForObject(target, session: session, timeout: 60) else {
            throw DriveError.decoding(
                "upload finished but \(target) never appeared. A wrong CRC32 checksum looks "
              + "exactly like this: every chunk is accepted, then finalize discards the file.")
        }
        return ShareItem(id: target, fileId: target, name: url.lastPathComponent, size: size,
                         shareURL: nil, directURL: nil, createdAt: Date(), expiresAt: nil,
                         phase: .ready, progress: 1, localPath: url)
    }

    private static let chunkSize = 524_288   // 512 KiB, matches the Drive web UI
    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
}
