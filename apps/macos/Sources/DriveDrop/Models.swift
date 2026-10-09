import Foundation

// MARK: - Domain model shared with the Windows client (see docs/design.md)

enum Expiration: Hashable, Identifiable, Codable {
    case oneHour, oneDay, sevenDays, thirtyDays, never, custom(Date)

    var id: String {
        switch self {
        case .oneHour: "1h"
        case .oneDay: "1d"
        case .sevenDays: "7d"
        case .thirtyDays: "30d"
        case .never: "never"
        case .custom(let d): "custom:\(d.timeIntervalSince1970)"
        }
    }

    var label: String {
        switch self {
        case .oneHour: "1 hour"
        case .oneDay: "1 day"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .never: "Never"
        case .custom(let d): "Until \(d.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .oneHour: 3_600
        case .oneDay: 86_400
        case .sevenDays: 604_800
        case .thirtyDays: 2_592_000
        case .never: nil
        case .custom(let d): max(0, d.timeIntervalSinceNow)
        }
    }

    var date: Date? {
        guard let s = seconds else { return nil }
        return Date().addingTimeInterval(s)
    }

    static let menuOrder: [Expiration] = [.oneHour, .oneDay, .sevenDays, .thirtyDays, .never]
}

enum UploadPhase: Hashable {
    case queued
    case uploading(Double)      // 0...1
    case sharing
    case ready
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .ready, .failed: true
        default: false
        }
    }
}

struct ShareItem: Identifiable, Hashable {
    let id: String              // share id
    var fileId: String
    var name: String
    var size: Int64
    var shareURL: URL?
    var directURL: URL?
    var createdAt: Date
    var expiresAt: Date?
    var phase: UploadPhase = .queued
    var progress: Double = 0
    var localPath: URL?
}

struct Usage: Hashable {
    var usedBytes: Int64
    var totalBytes: Int64
    var freeBytes: Int64 { max(0, totalBytes - usedBytes) }
}

/// One row of a directory listing, from `GET /proxy/drive/api/v1/resources/{path}/`.
/// Kept separate from `ShareItem` on purpose: entries are scoped to one folder while links
/// are global and can outlive the file or point outside the folder. They are joined at
/// render time, never fused into a stored row.
struct FileEntry: Identifiable, Hashable {
    /// Absolute API path as returned by the server, e.g. `/mydrive/Public/foo.zip`.
    var path: String
    var name: String
    var size: Int64
    var isDir: Bool
    var modifyTime: Date?

    var id: String { path }
}

/// Personal-drive path helpers. Everything the app stores about a destination is
/// **personal-drive relative** with a leading slash and no trailing slash, which is exactly
/// what the tus `dir` metadata wants, and one canonicalisation away from a listing URL.
enum DrivePath {
    /// `Public`, `/Public/`, `  /Public  `, `/mydrive/Public` all become `/Public`.
    /// `.` and `..` are **resolved**, and `..` is clamped at the personal-drive root so a
    /// path can never escape upward. Silently dropping `..` would turn `/a/../b` into
    /// `/a/b`, which uploads to somewhere nobody asked for.
    static func canonical(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for strip in ["/mydrive", "/shared"] where s.hasPrefix(strip) {
            s.removeFirst(strip.count)
        }
        var out: [String] = []
        for part in s.split(separator: "/") {
            switch part {
            case ".":  continue
            case "..": if !out.isEmpty { out.removeLast() }
            default:   out.append(String(part))
            }
        }
        return out.isEmpty ? "/" : "/" + out.joined(separator: "/")
    }

    /// Listing endpoint. The trailing slash is load-bearing — `/resources/mydrive` 404s.
    static func listingPath(_ dir: String) -> String {
        let d = canonical(dir)
        return "/proxy/drive/api/v1/resources/mydrive" + (d == "/" ? "/" : "\(d)/")
    }

    /// Absolute path prefix used to join against `link.path`.
    static func absolutePrefix(_ dir: String) -> String {
        let d = canonical(dir)
        return d == "/" ? "/mydrive" : "/mydrive\(d)"
    }

    /// Parent, clamped at the personal-drive root.
    static func parent(_ dir: String) -> String {
        let d = canonical(dir)
        if d == "/" { return "/" }
        return canonical(String(d.dropLast(d.split(separator: "/").last.map { $0.count + 1 } ?? 1)))
    }

    /// Display form for the header.
    static func display(_ dir: String) -> String {
        canonical(dir) == "/" ? "Personal drive" : canonical(dir)
    }
}

enum DriveError: LocalizedError {
    case notAuthenticated
    case transport(String)
    case status(Int, String)
    case decoding(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Not signed in to the console."
        case .transport(let m): "Could not reach the console. \(m)"
        case .status(let code, let m): "Console returned \(code): \(m)"
        case .decoding(let m): "Unexpected response from console (\(m))."
        case .unsupported(let m): "Not supported by this console build: \(m)"
        }
    }
}

// MARK: - Client contract (mirror of spec/api.md)

protocol DriveClient: AnyObject {
    func login() async throws
    func usage() async throws -> Usage
    func list() async throws -> [ShareItem]
    /// Contents of one personal-drive folder. `dir` is personal-relative (`/Public`).
    func browse(_ dir: String) async throws -> [FileEntry]
    func upload(from url: URL, to folder: String, progress: @escaping @Sendable (Double) -> Void) async throws -> ShareItem
    func createShare(for fileId: String, expiration: Expiration, password: String?) async throws -> ShareItem
    func setExpiration(_ item: ShareItem, _ expiration: Expiration) async throws -> ShareItem
    func delete(_ item: ShareItem) async throws
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    static func countdown(to date: Date?) -> String? {
        guard let date else { return nil }
        let iv = date.timeIntervalSinceNow
        if iv <= 0 { return "expired" }
        let d = Int(iv / 86_400), h = Int(iv.truncatingRemainder(dividingBy: 86_400) / 3_600)
        let m = Int(iv.truncatingRemainder(dividingBy: 3_600) / 60)
        if d > 0 { return "expires in \(d)d \(h)h" }
        if h > 0 { return "expires in \(h)h \(m)m" }
        return "expires in \(m)m"
    }
}
