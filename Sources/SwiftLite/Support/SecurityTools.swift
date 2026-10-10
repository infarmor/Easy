import CryptoKit
import Foundation

/// Tools for people who look at suspicious messages for a living: indicators, link and file checks, hashes.
/// Everything here works on what is already on screen or on disk; nothing is sent anywhere.
enum SecurityTools {
    // MARK: - indicators of compromise

    struct Indicators: Equatable {
        var urls: [String] = []
        var domains: [String] = []
        var ipv4: [String] = []
        var emails: [String] = []
        var md5: [String] = []
        var sha1: [String] = []
        var sha256: [String] = []
        var cves: [String] = []
        var ipv6: [String] = []
        var sha512: [String] = []
        /// Cryptocurrency addresses, each with the network it belongs to: "BTC bc1q…".
        var wallets: [String] = []
        /// MITRE ATT&CK technique ids, as analysts cite them: T1059, T1566.001.
        var techniques: [String] = []

        var isEmpty: Bool { count == 0 }
        var count: Int {
            urls.count + domains.count + ipv4.count + emails.count + md5.count + sha1.count + sha256.count + cves.count
                + ipv6.count + sha512.count + wallets.count + techniques.count
        }

        /// Every indicator with its type, in the order of the report. The names are the ones tools expect in a
        /// "type" column, so an export can be loaded into a spreadsheet or a TIP without renaming.
        var rows: [(type: String, value: String, kind: IndicatorKind)] {
            urls.map { ("url", $0, .url) } + domains.map { ("domain", $0, .domain) }
                + ipv4.map { ("ipv4", $0, .ip) } + ipv6.map { ("ipv6", $0, .ip) }
                + emails.map { ("email", $0, .other) }
                + sha512.map { ("sha512", $0, .hash) } + sha256.map { ("sha256", $0, .hash) }
                + sha1.map { ("sha1", $0, .hash) } + md5.map { ("md5", $0, .hash) }
                + cves.map { ("cve", $0, .cve) } + techniques.map { ("attack-technique", $0, .technique) }
                + wallets.map { ("wallet", $0, .other) }
        }

        /// Live values, not defanged: this is for machines.
        func json() -> String {
            let list = rows.map { ["type": $0.type, "value": $0.value] }
            guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "[]" }
            return String(decoding: data, as: UTF8.self)
        }

        func csv() -> String {
            func cell(_ text: String) -> String {
                // A value that starts like a formula would run in a spreadsheet; the quote makes it text.
                let safe = "=+-@".contains(text.first ?? " ") ? "'" + text : text
                return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return (["type,value"] + rows.map { cell($0.type) + "," + cell($0.value) }).joined(separator: "\n") + "\n"
        }

        /// A report to paste into a ticket. Links, domains, addresses and mail are defanged so nothing in it is clickable.
        func report(defanged: Bool = true) -> String {
            let fix: (String) -> String = defanged ? SecurityTools.defang : { $0 }
            var sections: [String] = []
            func add(_ title: String, _ values: [String], _ transform: (String) -> String = { $0 }) {
                guard !values.isEmpty else { return }
                sections.append("# \(title) (\(values.count))\n" + values.map(transform).joined(separator: "\n"))
            }
            add("URL", urls, fix)
            add("Домены", domains, fix)
            add("IPv4", ipv4, fix)
            add("IPv6", ipv6)
            add("Почта", emails, fix)
            add("SHA-512", sha512)
            add("SHA-256", sha256)
            add("SHA-1", sha1)
            add("MD5", md5)
            add("CVE", cves)
            add("MITRE ATT&CK", techniques)
            add("Кошельки", wallets)
            return sections.isEmpty ? "Индикаторы не найдены." : sections.joined(separator: "\n\n")
        }
    }

    /// A place to look an indicator up. Opening one sends that indicator, and nothing else, to the service.
    struct Lookup: Identifiable {
        let service: String
        let url: URL
        var id: String { service + url.absoluteString }
    }

    /// Where analysts usually take each kind of indicator first.
    static func lookups(for value: String, kind: IndicatorKind) -> [Lookup] {
        func link(_ service: String, _ address: String) -> Lookup? {
            URL(string: address).map { Lookup(service: service, url: $0) }
        }
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
        switch kind {
        case .hash:
            return [link("VirusTotal", "https://www.virustotal.com/gui/file/\(encoded)"),
                    link("MalwareBazaar", "https://bazaar.abuse.ch/browse.php?search=\(encoded)")].compactMap { $0 }
        case .domain:
            return [link("VirusTotal", "https://www.virustotal.com/gui/domain/\(encoded)"),
                    link("urlscan.io", "https://urlscan.io/search/#domain%3A\(encoded)"),
                    link("crt.sh", "https://crt.sh/?q=\(encoded)")].compactMap { $0 }
        case .ip:
            return [link("VirusTotal", "https://www.virustotal.com/gui/ip-address/\(encoded)"),
                    link("Shodan", "https://www.shodan.io/host/\(encoded)"),
                    link("AbuseIPDB", "https://www.abuseipdb.com/check/\(encoded)")].compactMap { $0 }
        case .url:
            return [link("VirusTotal", "https://www.virustotal.com/gui/search/\(encoded)"),
                    link("urlscan.io", "https://urlscan.io/search/#page.url%3A%22\(encoded)%22")].compactMap { $0 }
        case .cve:
            return [link("NVD", "https://nvd.nist.gov/vuln/detail/\(encoded)")].compactMap { $0 }
        case .technique:
            return [link("MITRE ATT&CK", "https://attack.mitre.org/techniques/\(value.replacingOccurrences(of: ".", with: "/"))/")].compactMap { $0 }
        case .other:
            return []
        }
    }

    enum IndicatorKind: String {
        case url, domain, ip, hash, cve, technique, other
    }

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"\b(?:h(?:tt|xx)ps?|ftp)(?::|\[:\])//[^\s<>"'`]+"#, options: [.caseInsensitive])
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"\b[A-Za-z0-9._%+\-]+(?:@|\[@\])[A-Za-z0-9.\-]+(?:\.|\[\.\])[A-Za-z]{2,}\b"#)
    private static let ipv4Pattern = try! NSRegularExpression(
        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.|\[\.\])){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#)
    private static let domainPattern = try! NSRegularExpression(
        pattern: #"\b(?:[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.|\[\.\]))+(?:xn--[A-Za-z0-9\-]+|[A-Za-z]{2,24})\b"#)
    private static let hashPattern = try! NSRegularExpression(pattern: #"\b[A-Fa-f0-9]{32,128}\b"#)
    /// Anything shaped like an IPv6 address; `inet_pton` then says which of them are one. A regular expression
    /// that tries to decide that by itself takes clock times and MAC addresses for addresses.
    private static let ipv6Pattern = try! NSRegularExpression(pattern: #"(?<![A-Fa-f0-9:.])[A-Fa-f0-9:]{3,39}(?![A-Fa-f0-9:])"#)
    private static let techniquePattern = try! NSRegularExpression(pattern: #"\bT1\d{3}(?:\.\d{3})?\b"#)
    private static let walletPatterns: [(String, NSRegularExpression)] = [
        ("BTC", try! NSRegularExpression(pattern: #"\b(?:bc1[ac-hj-np-z02-9]{25,62}|[13][a-km-zA-HJ-NP-Z1-9]{25,34})\b"#)),
        ("ETH", try! NSRegularExpression(pattern: #"\b0x[a-fA-F0-9]{40}\b"#)),
        ("TRX", try! NSRegularExpression(pattern: #"\bT[1-9A-HJ-NP-Za-km-z]{33}\b"#)),
        ("TON", try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_\-])(?:EQ|UQ)[A-Za-z0-9_\-]{46}(?![A-Za-z0-9_\-])"#)),
    ]
    private static let cvePattern = try! NSRegularExpression(pattern: #"\bCVE-\d{4}-\d{4,7}\b"#, options: [.caseInsensitive])

    /// File names and words that look like domains but are not worth a line in a report.
    private static let notDomains: Set<String> = [
        "exe", "dll", "pdf", "doc", "docx", "xls", "xlsx", "zip", "rar", "png", "jpg", "jpeg", "gif", "txt", "js",
        "json", "html", "htm", "py", "sh", "md", "csv", "log", "mp4", "mov", "apk", "dmg", "pkg", "iso", "bat", "ps1",
    ]

    static func indicators(in text: String) -> Indicators {
        var result = Indicators()
        let refanged = refang(text)
        func matches(_ pattern: NSRegularExpression, in source: String) -> [String] {
            let range = NSRange(source.startIndex..., in: source)
            return pattern.matches(in: source, range: range).compactMap { Range($0.range, in: source).map { String(source[$0]) } }
        }
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0.lowercased()).inserted }
        }

        // Trailing punctuation belongs to the sentence, not to the link.
        result.urls = unique(matches(urlPattern, in: refanged).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}»\"'")) })
        result.emails = unique(matches(emailPattern, in: refanged))
        result.ipv4 = unique(matches(ipv4Pattern, in: refanged))
        let hosts = Set(result.urls.compactMap { URL(string: $0)?.host?.lowercased() })
        let mailDomains = Set(result.emails.compactMap { $0.split(separator: "@").last.map { $0.lowercased() } })
        result.domains = unique(matches(domainPattern, in: refanged).filter { domain in
            let lower = domain.lowercased()
            guard let tld = lower.split(separator: ".").last, !notDomains.contains(String(tld)) else { return false }
            return !hosts.contains(lower) && !mailDomains.contains(lower) && Double(lower.replacingOccurrences(of: ".", with: "")) == nil
        })
        for hash in unique(matches(hashPattern, in: refanged)) {
            switch hash.count {
            case 32: result.md5.append(hash.lowercased())
            case 40: result.sha1.append(hash.lowercased())
            case 64: result.sha256.append(hash.lowercased())
            case 128: result.sha512.append(hash.lowercased())
            default: break
            }
        }
        result.cves = unique(matches(cvePattern, in: refanged).map { $0.uppercased() })
        result.ipv6 = unique(matches(ipv6Pattern, in: refanged).filter { candidate in
            // Two colons at least, and either a "::" or all eight groups: "12:30:45" is a time of day.
            guard candidate.filter({ $0 == ":" }).count >= 2,
                  candidate.contains("::") || candidate.filter({ $0 == ":" }).count == 7 else { return false }
            var address = in6_addr()
            return inet_pton(AF_INET6, candidate, &address) == 1
        }.map { $0.lowercased() })
        result.techniques = unique(matches(techniquePattern, in: refanged))
        // The original text, not the refanged one: an address is case-sensitive and has nothing to defang.
        for (network, pattern) in walletPatterns {
            result.wallets += unique(matches(pattern, in: text)).map { "\(network) \($0)" }
        }
        return result
    }

    /// `https://evil.com` → `hxxps://evil[.]com`: safe to paste into chats and tickets.
    static func defang(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "http", with: "hxxp", options: [.caseInsensitive, .anchored])
            .replacingOccurrences(of: "ftp", with: "fxp", options: [.caseInsensitive, .anchored])
            .replacingOccurrences(of: "://", with: "[://]")
            .replacingOccurrences(of: "@", with: "[@]")
        result = result.replacingOccurrences(of: ".", with: "[.]")
        return result
    }

    /// The reverse, so defanged indicators people paste are recognised too.
    static func refang(_ value: String) -> String {
        value
            .replacingOccurrences(of: "[.]", with: ".")
            .replacingOccurrences(of: "(.)", with: ".")
            .replacingOccurrences(of: "[@]", with: "@")
            .replacingOccurrences(of: "[://]", with: "://")
            .replacingOccurrences(of: "[:]", with: ":")
            .replacingOccurrences(of: "hxxp", with: "http", options: .caseInsensitive)
            .replacingOccurrences(of: "fxp", with: "ftp", options: .caseInsensitive)
    }

    // MARK: - links

    private static let shorteners: Set<String> = [
        "bit.ly", "tinyurl.com", "t.co", "goo.gl", "is.gd", "cutt.ly", "rb.gy", "ow.ly", "shorturl.at", "clck.ru", "tiny.cc", "s.id",
    ]
    /// Top-level domains that are also file extensions or are cheap enough to be mostly used for throwaway sites.
    private static let riskyTopLevel: Set<String> = ["zip", "mov", "top", "xyz", "click", "country", "gq", "tk", "ml", "cf", "work", "rest"]

    /// Telegram's own sites. Anything else that spells its name is someone else's.
    private static let telegramDomains: [String] = [
        "t.me", "telegram.org", "telegram.me", "telegram.dog", "telegra.ph", "telesco.pe", "tdesktop.com",
        "fragment.com", "tg.dev", "telegram.com",
    ]

    /// The host with the usual stand-ins put back: "te1egrarn" reads as "telegram" to an eye, so it does here.
    private static func skeleton(_ host: String) -> String {
        var result = host.lowercased()
        for (fake, real) in [("rn", "m"), ("vv", "w"), ("0", "o"), ("1", "l"), ("i", "l"), ("3", "e"), ("4", "a"), ("5", "s")] {
            result = result.replacingOccurrences(of: fake, with: real)
        }
        return result
    }

    /// Words over hidden links that were themselves addresses, by the link they sit on. Bounded: only links
    /// whose text names another site get here, and a long session must not grow it without end.
    private static let labelLock = NSLock()
    nonisolated(unsafe) private static var labels: [URL: String] = [:]

    static func noteLabel(_ text: String, for url: URL) {
        let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An address has a dot and no spaces; "нажмите здесь" over a link is ordinary.
        guard shown.contains("."), !shown.contains(where: \.isWhitespace), shown.count <= 200,
              let shownHost = URL(string: shown.contains("://") ? shown : "https://" + shown)?.host?.lowercased(),
              let host = url.host?.lowercased(), shownHost != host else { return }
        labelLock.lock()
        defer { labelLock.unlock() }
        if labels.count >= 2000 { labels.removeAll() }
        labels[url] = shown
    }

    static func label(for url: URL) -> String? {
        labelLock.lock()
        defer { labelLock.unlock() }
        return labels[url]
    }

    /// Reasons to look twice before opening a link; empty when nothing stands out.
    static func linkWarnings(_ url: URL, shownAs text: String? = nil) -> [String] {
        var warnings: [String] = []
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        if scheme == "http" { warnings.append("Соединение без шифрования (http)") }
        if url.user != nil {
            warnings.append("В адресе есть «имя@»: настоящий сайт — то, что после @")
        }
        if host.contains("xn--") { warnings.append("Домен в punycode (\(host)): может подделывать другой адрес буквами другого алфавита") }
        if mixesScripts(host) { warnings.append("В домене смешаны латиница и кириллица") }
        if host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil || host.hasPrefix("[") {
            warnings.append("Вместо домена — IP-адрес")
        }
        if shorteners.contains(host) { warnings.append("Сокращённая ссылка: настоящий адрес скрыт") }
        if let tld = host.split(separator: ".").last, riskyTopLevel.contains(String(tld)) {
            warnings.append("Домен в зоне .\(tld), которую часто используют для фишинга")
        }
        if host.split(separator: ".").count > 5 { warnings.append("Необычно длинная цепочка поддоменов") }
        if let port = url.port, ![80, 443].contains(port) { warnings.append("Нестандартный порт \(port)") }
        // 3232235777, 0xC0A80101 and 0300.0250.01.01 are all ways a browser reads an IPv4 address.
        if !host.isEmpty, host.range(of: #"^(?:0x[0-9a-f]+|\d+)(?:\.(?:0x[0-9a-f]+|\d+)){0,3}$"#, options: .regularExpression) != nil,
           host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) == nil
            || host.split(separator: ".").contains(where: { $0.count > 1 && $0.hasPrefix("0") }) {
            warnings.append("IP-адрес записан числом, чтобы не быть похожим на адрес")
        }
        if host.unicodeScalars.contains(where: { $0.value > 0x7F }), !mixesScripts(host) {
            warnings.append("В домене буквы не из латиницы: он может выглядеть как другой сайт")
        }
        if skeleton(host).contains("telegram") || skeleton(host).contains("teiegram"),
           !telegramDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            warnings.append("Домен похож на Telegram, но Telegram не принадлежит")
        }
        // Pages and scripts are what the web is made of; these are what a link has no business handing over.
        if downloads.contains(url.pathExtension.lowercased()) {
            warnings.append("Ссылка ведёт сразу на файл .\(url.pathExtension.lowercased()), который может запускать код")
        }
        if let text, let shownHost = URL(string: text.contains("://") ? text : "https://" + text)?.host?.lowercased(),
           shownHost.contains("."), !host.isEmpty, shownHost != host, !host.hasSuffix("." + shownHost) {
            warnings.append("Текст ссылки показывает \(shownHost), а ведёт она на \(host)")
        }
        return warnings
    }

    private static func mixesScripts(_ host: String) -> Bool {
        var latin = false, cyrillic = false
        for scalar in host.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A: latin = true
            case 0x400...0x4FF: cyrillic = true
            default: break
            }
        }
        return latin && cyrillic
    }

    // MARK: - files

    private static let executable: Set<String> = [
        "app", "pkg", "mpkg", "dmg", "command", "tool", "sh", "zsh", "bash", "scpt", "applescript", "workflow", "jar",
        "exe", "msi", "bat", "cmd", "com", "scr", "pif", "ps1", "vbs", "vbe", "js", "jse", "wsf", "hta", "lnk", "reg",
        "apk", "iso", "img", "docm", "xlsm", "pptm", "dylib", "so", "py", "pl", "rb",
        // What macOS runs or follows on a double click without calling it a program.
        "terminal", "inetloc", "fileloc", "webloc", "url", "action", "service", "scptd", "prefpane", "saver",
        "mobileconfig", "configprofile", "kext", "plugin", "appex", "osax", "qlgenerator", "shortcut",
        // Windows and Office formats that carry code; they travel through Telegram to people who forward them.
        "gadget", "cpl", "msix", "appx", "appref-ms", "settingcontent-ms", "library-ms", "chm", "hlp", "wsh",
        "psm1", "ps1xml", "vb", "xll", "xlam", "dotm", "ppam", "sldm", "one", "iqy", "slk", "jnlp", "cab",
        // Pages opened from disk run their scripts with the file's own reach.
        "html", "htm", "xhtml", "shtml", "svg", "mht", "mhtml",
    ]
    /// Extensions that mean "this link downloads a program" rather than "this link opens a page".
    private static let downloads: Set<String> = [
        "exe", "msi", "scr", "bat", "cmd", "ps1", "vbs", "hta", "lnk", "jar", "apk", "dmg", "pkg", "iso", "img",
        "command", "docm", "xlsm", "pptm", "mobileconfig", "msix", "appx", "cab", "chm",
    ]
    private static let documents: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "jpg", "jpeg", "png", "txt", "mp4", "mp3"]

    /// Why a file deserves care before it is opened; nil for ordinary files.
    static func fileWarning(for name: String) -> String? {
        // U+202E turns "invoice_fdp.exe" into something that reads like a PDF.
        if name.unicodeScalars.contains(where: {
            [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x200E, 0x200F, 0x2066, 0x2067, 0x2068, 0x2069, 0x061C].contains($0.value)
        }) {
            return "В имени файла скрытые символы направления текста: настоящее расширение замаскировано."
        }
        let parts = name.lowercased().split(separator: ".").map(String.init)
        guard parts.count > 1, let ext = parts.last else { return nil }
        if executable.contains(ext) {
            if parts.count > 2, documents.contains(parts[parts.count - 2]) {
                return "Двойное расширение (.\(parts[parts.count - 2]).\(ext)): файл выдаёт себя за документ, а на деле исполняемый."
            }
            return "Файл .\(ext) может запускать код. Открывайте, только если доверяете отправителю."
        }
        return nil
    }

    /// What the first bytes of a file say it is, when that is a program and its name says otherwise: the name
    /// is whatever the sender typed, the bytes are what the Mac will act on.
    static func contentWarning(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count >= 4 else { return nil }
        let bytes = [UInt8](head)
        let kind: String?
        switch (bytes[0], bytes[1], bytes[2], bytes[3]) {
        case (0x4D, 0x5A, _, _): kind = "программа Windows"
        case (0x7F, 0x45, 0x4C, 0x46): kind = "программа Linux"
        case (0xCF, 0xFA, 0xED, 0xFE), (0xCE, 0xFA, 0xED, 0xFE), (0xFE, 0xED, 0xFA, 0xCF), (0xFE, 0xED, 0xFA, 0xCE),
             (0xCA, 0xFE, 0xBA, 0xBE), (0xCA, 0xFE, 0xBA, 0xBF):
            kind = "программа macOS или Java"
        case (0x23, 0x21, _, _): kind = "скрипт"
        default: kind = nil
        }
        guard let kind else { return nil }
        let ext = url.pathExtension.lowercased()
        // A file that admits to being a program has already been warned about by its name.
        guard !executable.contains(ext) else { return nil }
        return "Имя говорит «.\(ext.isEmpty ? "без расширения" : ext)», а внутри \(kind). Открывайте, только если ждали именно этого."
    }

    /// SHA-256 of a file read in chunks, so large videos do not have to fit in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
