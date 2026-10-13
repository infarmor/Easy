import Foundation

/// A proxy server as the settings keep it.
struct ProxyServer: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case socks5, http, mtproto

        var id: String { rawValue }

        var title: String {
            switch self {
            case .socks5: "SOCKS5"
            case .http: "HTTP"
            case .mtproto: "MTProto"
            }
        }
    }

    var id = UUID()
    var kind = Kind.socks5
    var server = ""
    var port = 1080
    var username = ""
    var password = ""
    /// MTProto only: the secret the proxy's owner hands out, in hex or base64url as TDLib takes it.
    var secret = ""

    init() {}

    /// From TDLib's `proxy`, as a proxy link or `getProxies` describes it.
    init?(node: TDNode) {
        let type = node.tdNode("type") ?? [:]
        switch type.tdType {
        case "proxyTypeSocks5": kind = .socks5
        case "proxyTypeHttp": kind = .http
        case "proxyTypeMtproto": kind = .mtproto
        default: return nil
        }
        server = node.tdString("server")
        port = node.tdInt("port")
        username = type.tdString("username")
        password = type.tdString("password")
        secret = type.tdString("secret")
    }

    var title: String { "\(trimmedServer):\(port)" }

    private var trimmedServer: String { server.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isComplete: Bool {
        !trimmedServer.isEmpty && (1...65535).contains(port) && (kind != .mtproto || !secret.isEmpty)
    }

    /// TDLib's `proxy` object. Credentials of the other kinds are left out: a SOCKS5 server edited into an
    /// MTProto one keeps its old login in the form, not in what is sent.
    var node: TDNode {
        let type: TDNode
        switch kind {
        case .socks5: type = ["@type": "proxyTypeSocks5", "username": username, "password": password]
        case .http: type = ["@type": "proxyTypeHttp", "username": username, "password": password, "http_only": false]
        case .mtproto: type = ["@type": "proxyTypeMtproto", "secret": secret]
        }
        return ["@type": "proxy", "server": trimmedServer, "port": port, "type": type]
    }

    /// The same server with the same login, whatever id each copy was given.
    func sameEndpoint(as other: ProxyServer) -> Bool {
        guard kind == other.kind, trimmedServer.lowercased() == other.trimmedServer.lowercased(), port == other.port else {
            return false
        }
        switch kind {
        case .socks5, .http: return username == other.username && password == other.password
        case .mtproto: return secret == other.secret
        }
    }
}

/// The proxy every account connects through. TDLib keeps proxies inside each account's database, and Easy
/// has a database per account, so the list lives here and every session is handed the one that is on
/// (`AppModel.applyProxy`). Kept beside the API keys, with the same 600 permissions: a proxy's password and
/// secret are as private as they are.
@MainActor
@Observable
final class ProxyStore {
    static let shared = ProxyStore()

    private(set) var servers: [ProxyServer] = []
    /// nil connects directly.
    private(set) var enabledId: UUID?
    /// Told after every change; the account hub passes it on to each session.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    var enabled: ProxyServer? { servers.first { $0.id == enabledId } }

    private struct Saved: Codable {
        var servers: [ProxyServer]
        var enabledId: UUID?
    }

    private init() {
        guard let data = try? Data(contentsOf: ConfigStore.proxyFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        servers = saved.servers
        enabledId = saved.servers.contains { $0.id == saved.enabledId } ? saved.enabledId : nil
    }

    /// Adds a server, or finds the same one already on the list. Returns the id it is kept under.
    @discardableResult
    func add(_ server: ProxyServer) -> UUID {
        if let known = servers.first(where: { $0.sameEndpoint(as: server) }) { return known.id }
        servers.append(server)
        save()
        return server.id
    }

    func update(_ server: ProxyServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }), servers[index] != server else { return }
        servers[index] = server
        save()
    }

    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        if enabledId == id { enabledId = nil }
        save()
    }

    /// Turns one server on, and with it off every other; nil connects directly.
    func enable(_ id: UUID?) {
        guard id == nil || servers.contains(where: { $0.id == id }), id != enabledId else { return }
        enabledId = id
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(servers: servers, enabledId: enabledId)) {
            try? data.write(to: ConfigStore.proxyFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ConfigStore.proxyFile.path)
        }
        onChange?()
    }
}
