import Foundation

/// The interface language. The app was written in Russian, and its Russian strings are the keys: `L("Чаты")`
/// gives the same text back in Russian and looks it up in `Translations.english` otherwise.
enum Loc {
    /// The setting's key: "ru", "en", or anything else for the Mac's own language.
    static let preference = "appLanguage"

    /// Decided once at launch; a change of the setting takes a restart, since text is already on screen.
    static let isEnglish: Bool = {
        // The test stands check Russian text and say so here, whatever the Mac is set to.
        if let forced = ProcessInfo.processInfo.environment["EASY_LANG"] { return forced.hasPrefix("en") }
        switch UserDefaults.standard.string(forKey: preference) {
        case "en": return true
        case "ru": return false
        default: return !(Locale.preferredLanguages.first ?? "ru").hasPrefix("ru")
        }
    }()

    /// Dates, numbers and relative times follow the interface, whatever region the Mac is set to.
    static let locale = Locale(identifier: isEnglish ? "en_US" : "ru_RU")

    /// For text that is not a literal at the place it is shown (an enum's raw value, say).
    static func translate(_ key: String) -> String {
        isEnglish ? (Translations.english[key] ?? key) : key
    }
}

/// A string literal as `L` receives it: the text with every interpolation replaced by {0}, {1}…, which is the
/// key translations are stored under, and the interpolated values beside it.
struct LText: ExpressibleByStringInterpolation {
    var key: String
    var arguments: [String]

    init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity + interpolationCount * 3)
        }

        mutating func appendLiteral(_ literal: String) {
            key += literal
        }

        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}

/// The interface text for a literal: itself in Russian, its translation in English. A translation may use the
/// interpolated values in another order, or leave one out.
func L(_ text: LText) -> String {
    let format = Loc.translate(text.key)
    guard !text.arguments.isEmpty else { return format }
    var result = ""
    result.reserveCapacity(format.count + 16)
    var rest = format[...]
    while let open = rest.firstIndex(of: "{") {
        result += rest[..<open]
        let after = rest[rest.index(after: open)...]
        if let close = after.firstIndex(of: "}"), let index = Int(after[..<close]), text.arguments.indices.contains(index) {
            result += text.arguments[index]
            rest = after[after.index(after: close)...]
        } else {
            result.append("{")
            rest = after
        }
    }
    result += rest
    return result
}
