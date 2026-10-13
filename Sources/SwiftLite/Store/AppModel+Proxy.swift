import Foundation

extension AppModel {
    // MARK: - proxy

    /// Makes this session connect the way the settings say: through the proxy that is on, or directly.
    /// Calls queue behind each other, so two quick changes in the settings cannot add a server twice.
    func applyProxy() {
        let previous = proxySync
        proxySync = Task { [weak self] in
            await previous?.value
            await self?.syncProxy()
        }
    }

    /// TDLib remembers proxies in the account's own database. Whatever is there that the settings do not
    /// name is taken out, so an account never goes on using a proxy turned off while it was closed.
    private func syncProxy() async {
        guard bridge != nil, let current = try? await request(["@type": "getProxies"]) else { return }
        let wanted = ProxyStore.shared.enabled
        let added = current.tdNodes("proxies")
        if let wanted, added.count == 1, added[0].tdBool("is_enabled"),
           let proxy = added[0].tdNode("proxy").flatMap(ProxyServer.init(node:)), proxy.sameEndpoint(as: wanted) {
            return
        }
        if wanted == nil, added.isEmpty { return }
        for proxy in added {
            _ = try? await request(["@type": "removeProxy", "proxy_id": proxy.tdInt("id")])
        }
        guard let wanted else { return }
        do {
            _ = try await request(["@type": "addProxy", "proxy": wanted.node, "enable": true, "comment": ""])
        } catch {
            fail(error)
        }
    }

    /// Time to reach Telegram through `server`, in seconds; nil when it does not answer.
    func ping(_ server: ProxyServer) async -> Double? {
        guard let result = try? await request(["@type": "pingProxy", "proxy": server.node]) else { return nil }
        return result.tdDouble("seconds")
    }

    /// A tg://proxy or t.me/socks link: asked about first, since every account would then go through it.
    func offerProxy(_ node: TDNode) {
        guard let server = ProxyServer(node: node) else { return }
        guard BotDialogs.ask(L("Подключаться через прокси \(server.title)?"),
                             L("Тип: \(server.kind.title). Через него будут подключаться все аккаунты; выключить его можно в Настройках → Прокси."),
                             action: L("Подключить")) else { return }
        let store = ProxyStore.shared
        store.enable(store.add(server))
        showToast(L("Прокси включён"))
    }
}
