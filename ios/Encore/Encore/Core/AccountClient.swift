// Stream ios-p2: the optional YouTube account (the desktop's `get_account` / `sign_out` /
// channel picker, and `account_sign_in`, which takes the cookies the app's own sign-in web view
// read: see Screens/YouTubeSignIn.swift and crates/ffi/src/account.rs). Its own protocol so the
// shared `CoreClient` stays as it is; both clients conform below.
import Foundation

/// api.ts `Account`.
struct YouTubeAccount: Codable, Hashable {
    var signedIn: Bool
    var name: String?
    var handle: String?
    var email: String?
    var thumbnail: String?
    var channelId: String?
    var canSwitch: Bool?
    /// The cookie authenticated, but a multi-channel login isn't complete until one is picked.
    var selectionRequired: Bool?

    static let signedOut = YouTubeAccount(signedIn: false)
    /// What Settings calls the account: the channel name, else the handle or email.
    var displayName: String? {
        guard signedIn else { return nil }
        return [name, handle, email].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

/// api.ts `AccountIdentity`: one channel of a multi-channel Google account.
struct AccountIdentity: Codable, Hashable, Identifiable {
    var selectionKey: String
    var name: String
    var handle: String?
    var email: String?
    var thumbnail: String?
    var channelId: String?
    var selected: Bool?
    var id: String { selectionKey }
}

protocol AccountClient: AnyObject, Sendable {
    func getAccount() async throws -> YouTubeAccount                                           // get_account
    /// The `Cookie` header of the youtube.com cookies the sign-in web view holds. `expectAccount`
    /// (a re-mint after `session-rejected`): only if it is still the same Google account.
    func accountSignIn(cookie: String, expectAccount: String?) async throws -> YouTubeAccount  // account_sign_in
    func signOut() async throws -> YouTubeAccount                                              // sign_out
    func accountIdentities() async throws -> [AccountIdentity]                                 // get_account_identities
    func switchAccount(selectionKey: String) async throws -> YouTubeAccount                    // switch_account
    /// Start the core's session upkeep (rotated cookies, keep-alive, `session-rejected`). Idempotent.
    func accountWatch() async throws                                                           // account_watch
}

extension RealCoreClient: AccountClient {
    func getAccount() async throws -> YouTubeAccount { try await call("get_account") }
    func accountSignIn(cookie: String, expectAccount: String?) async throws -> YouTubeAccount {
        try await call("account_sign_in", ["cookie": cookie, "expectAccount": expectAccount])
    }
    func signOut() async throws -> YouTubeAccount { try await call("sign_out") }
    func accountIdentities() async throws -> [AccountIdentity] { try await call("get_account_identities") }
    func switchAccount(selectionKey: String) async throws -> YouTubeAccount {
        try await call("switch_account", ["selectionKey": selectionKey])
    }
    func accountWatch() async throws { _ = try await call("account_watch") }
}

/// The mock's account, per client (an extension can't add stored properties). Weak keys: a
/// client's address can be reused by the next test's, and its account must not carry over.
final class MockAccounts: @unchecked Sendable {
    static let shared = MockAccounts()
    private final class Box { var v: (account: YouTubeAccount, cookie: String?); init(_ v: (YouTubeAccount, String?)) { self.v = v } }
    private let lock = NSLock()
    private let byClient = NSMapTable<AnyObject, Box>.weakToStrongObjects()
    func get(_ c: AnyObject) -> (account: YouTubeAccount, cookie: String?) {
        lock.withLock { byClient.object(forKey: c)?.v ?? (.signedOut, nil) }
    }
    func set(_ c: AnyObject, _ v: (account: YouTubeAccount, cookie: String?)) { lock.withLock { byClient.setObject(Box(v), forKey: c) } }
}

/// The mock signs in on any cookie header with a SAPISID (what the core's `sign_in` checks first),
/// as a fixed test channel; a `SAPISID` of `multi` asks for a channel pick, like a brand account.
extension MockCoreClient: AccountClient {
    /// The account the mock answers once signed in (UI tests can't type a password, and mustn't).
    static let mockAccount = YouTubeAccount(signedIn: true, name: "Test Listener", handle: "@testlistener",
                                            email: nil, thumbnail: nil, channelId: "UCmockchannel", canSwitch: false)

    func getAccount() async throws -> YouTubeAccount { MockAccounts.shared.get(self).account }

    func accountSignIn(cookie: String, expectAccount: String?) async throws -> YouTubeAccount {
        guard let sapisid = YouTubeCookies.sapisid(cookie) else { throw MockError.missing("SAPISID") }
        if let expectAccount, MockAccounts.shared.get(self).cookie.flatMap(YouTubeCookies.sapisid) != expectAccount {
            throw MockError.missing("account changed")
        }
        let account = sapisid == "multi"
            ? YouTubeAccount(signedIn: true, canSwitch: true, selectionRequired: true)
            : Self.mockAccount
        MockAccounts.shared.set(self, (account, cookie))
        emit("auth-changed", account)
        return account
    }

    func signOut() async throws -> YouTubeAccount {
        MockAccounts.shared.set(self, (.signedOut, nil))
        emit("auth-changed", YouTubeAccount.signedOut)
        return .signedOut
    }

    func accountIdentities() async throws -> [AccountIdentity] {
        [AccountIdentity(selectionKey: "k1", name: "Test Listener", handle: "@testlistener", selected: false),
         AccountIdentity(selectionKey: "k2", name: "Test Listener Music", handle: "@testlistenermusic", selected: false)]
    }

    func switchAccount(selectionKey: String) async throws -> YouTubeAccount {
        let pick = try await accountIdentities().first { $0.selectionKey == selectionKey }
        guard let pick else { throw MockError.missing(selectionKey) }
        var a = Self.mockAccount
        a.name = pick.name; a.handle = pick.handle; a.canSwitch = true
        MockAccounts.shared.set(self, (a, MockAccounts.shared.get(self).cookie))
        emit("auth-changed", a)
        return a
    }

    func accountWatch() async throws {}
}

/// The desktop's `youtube_cookie_header` (src-tauri/src/session.rs), over `HTTPCookie`s: only
/// youtube.com cookies (google.com ones included in the store never ride along), and the most
/// specific domain wins a name clash, the way a browser resolves one.
enum YouTubeCookies {
    static func header(_ cookies: [HTTPCookie]) -> String {
        var jar: [String: String] = [:]
        let sorted = cookies.sorted { bare($0.domain).count < bare($1.domain).count }
        for c in sorted {
            let d = bare(c.domain)
            if d == "youtube.com" || d.hasSuffix(".youtube.com") { jar[c.name] = c.value }
        }
        return jar.keys.sorted().map { "\($0)=\(jar[$0]!)" }.joined(separator: "; ")
    }

    /// `innertube::cookie_sapisid`: the first SAPISID or `__Secure-3PAPISID` value, nil when signed out.
    static func sapisid(_ header: String) -> String? {
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == "SAPISID" || kv[0] == "__Secure-3PAPISID", !kv[1].isEmpty { return kv[1] }
        }
        return nil
    }

    private static func bare(_ domain: String) -> String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }
}
