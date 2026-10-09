import Foundation
import Security

/// Session + transport plumbing shared by every Drive call.
///
/// Implements the auth contract in spec/api.md:
///   POST /api/auth/login  -> TOKEN cookie
///   X-Csrf-Token mirrored from X-Updated-Csrf-Token
///   one transparent re-login + retry on 401
final class DriveSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    let host: String
    var username: String
    var password: String
    let allowInvalidCerts: Bool

    private(set) var csrfToken: String?
    private(set) var tokenExpire: Date?
    private var loggedIn = false

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 60
        // X-Connection-Type: local is sent by the Drive web UI on every call.
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
            "X-Connection-Type": "local",
        ]
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    init(host: String, username: String, password: String, allowInvalidCerts: Bool = true) {
        self.host = host.hasPrefix("http") ? host : "https://\(host)"
        self.username = username
        self.password = password
        self.allowInvalidCerts = allowInvalidCerts
    }

    var baseURL: URL { URL(string: host)! }
    private var hostURL: URL { URL(string: host)! }

    // MARK: trust

    func urlSession(_ s: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if allowInvalidCerts {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: core request

    struct Response {
        let status: Int
        let headers: [String: String]
        let data: Data
        var json: Any? {
            guard !data.isEmpty else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        func string(_ key: String) -> String? {
            headers.first { $0.key.lowercased() == key.lowercased() }?.value
        }
    }

    @discardableResult
    func send(_ method: String, _ path: String,
              body: Data? = nil,
              contentType: String? = nil,
              extraHeaders: [String: String] = [:],
              retry: Bool = true) async throws -> Response {
        if !loggedIn && path.contains("/proxy/drive/") { try await login() }

        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DriveError.transport("bad path \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        if let csrf = csrfToken { req.setValue(csrf, forHTTPHeaderField: "X-Csrf-Token") }
        req.setValue(hostURL.absoluteString, forHTTPHeaderField: "Origin")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw DriveError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw DriveError.transport("non-HTTP response")
        }
        var hdrs: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { hdrs[ks] = vs }
        }
        let out = Response(status: http.statusCode, headers: hdrs, data: data)

        if let fresh = out.string("X-Csrf-Token"), csrfToken == nil { csrfToken = fresh }
        if let updated = out.string("X-Updated-Csrf-Token") { csrfToken = updated }
        if let exp = out.string("X-Token-Expire-Time"), let t = Double(exp) {
            tokenExpire = Date(timeIntervalSince1970: t / 1000)
        }

        // One transparent re-auth.
        if out.status == 401, retry {
            loggedIn = false
            try await login()
            return try await send(method, path, body: body, contentType: contentType,
                                  extraHeaders: extraHeaders, retry: false)
        }
        return out
    }

    // MARK: auth

    /// The gateway answers **403 Forbidden** to `POST /api/auth/login` if a TOKEN cookie is
    /// already attached to the request. URLSession's shared jar survives between launches, so
    /// without this a second run of the app cannot sign in at all.
    func clearCookies() {
        guard let store = session.configuration.httpCookieStorage else { return }
        for c in store.cookies ?? [] { store.deleteCookie(c) }
    }

    func login() async throws {
        clearCookies()
        // rememberMe extends the TOKEN JWT from 2 h to 30 d (verified: exp-iat 7200 -> 2592000,
        // isRemembered true). Without it the console drops the session mid-day and every
        // call needs the silent re-login path below.
        let payload = try JSONSerialization.data(withJSONObject: [
            "username": username, "password": password, "rememberMe": true
        ])
        let r = try await sendRaw("POST", "/api/auth/login", body: payload,
                                  contentType: "application/json")
        switch r.status {
        case 200...299:
            loggedIn = true
            if let csrf = r.string("X-Csrf-Token") { csrfToken = csrf }
            // Epoch **milliseconds**; verified to match the JWT `exp` claim to the second.
            if let s = r.string("X-Token-Expire-Time"), let ms = Double(s) {
                tokenExpire = Date(timeIntervalSince1970: ms / 1000)
            }
            return
        case 400:
            // zod-style validation body -> surface the real reason
            let msg = (r.json as? [String: Any])?["message"] as? String ?? "invalid request"
            throw DriveError.status(400, "Login rejected: \(msg)")
        default:
            let text = String(data: r.data, encoding: .utf8) ?? ""
            throw DriveError.status(r.status, text.isEmpty ? "login failed" : text)
        }
    }

    /// send() without the implicit drive-login (avoids recursion)
    private func sendRaw(_ method: String, _ path: String, body: Data?,
                         contentType: String?) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DriveError.transport("bad path \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw DriveError.transport(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else {
            throw DriveError.transport("non-HTTP response")
        }
        var hdrs: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { hdrs[ks] = vs }
        }
        return Response(status: http.statusCode, headers: hdrs, data: data)
    }

    func logout() async {
        _ = try? await sendRaw("POST", "/api/auth/logout", body: Data("{}".utf8),
                               contentType: "application/json")
        loggedIn = false
    }
}

// MARK: - Keychain

enum Keychain {
    static let service = "com.drivedrop.session"

    static func password(for account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ pw: String, for account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(pw.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
