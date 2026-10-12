import AppKit
import SwiftUI

/// Raw TDLib object behind "Код сообщения…" and "Код чата…": a readable tree by default, JSON on request.
/// Edit history uses the same sheet as plain text.
struct CodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsJSON = false
    let code: InspectedCode

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(code.title)
                    .font(.body.weight(.semibold))
                Spacer()
                if code.node != nil {
                    Picker("", selection: $showsJSON) {
                        Text(L("Понятно")).tag(false)
                        Text("JSON").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(12)
            Divider()
            // Code keeps its lines and scrolls sideways; plain text wraps.
            ScrollView(code.isCode ? [.vertical, .horizontal] : .vertical) {
                content
                    .textSelection(.enabled)
                    .fixedSize(horizontal: code.isCode, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(L("Скопировать")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copiedText, forType: .string)
                }
                if let found = code.indicators {
                    Menu(L("Экспорт")) {
                        Button(L("Скопировать как JSON")) { copy(found.json()) }
                        Button(L("Скопировать как CSV")) { copy(found.csv()) }
                    }
                    .fixedSize()
                    // Opening a lookup tells that service what you are looking at; nothing leaves before a click.
                    Menu(L("Проверить")) {
                        ForEach(Array(found.rows.enumerated()), id: \.offset) { _, row in
                            let lookups = SecurityTools.lookups(for: row.value, kind: row.kind)
                            if !lookups.isEmpty {
                                Menu(row.value.count > 48 ? String(row.value.prefix(46)) + "…" : row.value) {
                                    ForEach(lookups) { lookup in
                                        Button(lookup.service) { NSWorkspace.shared.open(lookup.url) }
                                    }
                                }
                            }
                        }
                    }
                    .fixedSize()
                    .help(L("Открыть индикатор в VirusTotal, urlscan, Shodan и других. Сервис узнает, что вы искали"))
                }
                Spacer()
                Button(L("Готово")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
    }

    @ViewBuilder
    private var content: some View {
        if let node = code.node, !showsJSON {
            Text(ReadableCode.render(node))
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(2)
        } else {
            Text(code.json)
                .font(code.isCode ? .system(size: 11, design: .monospaced) : .system(size: 13))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var copiedText: String {
        if let node = code.node, !showsJSON { return String(ReadableCode.render(node).characters) }
        return code.json
    }
}

/// TDLib objects as an indented tree: the object's type after its key, then its fields, one per line.
/// Strings are green, numbers blue, flags orange; Unix times get a readable date next to them.
enum ReadableCode {
    private static let dateKeys: Set<String> = ["date", "edit_date", "was_online", "expires", "close_date", "until_date", "join_date"]

    static func render(_ node: TDNode) -> AttributedString {
        var output = AttributedString()
        append(value: node, key: nil, depth: 0, to: &output)
        return output
    }

    private static func append(value: Any, key: String?, depth: Int, to output: inout AttributedString) {
        var line = AttributedString(String(repeating: "  ", count: depth))
        if let key {
            line += styled(key + ": ", .secondary)
        }

        switch value {
        case let object as TDNode:
            line += styled(object.tdType.isEmpty ? "{}" : object.tdType, .purple)
            output += line + AttributedString("\n")
            for field in object.keys.sorted() where field != "@type" {
                append(value: object[field] as Any, key: field, depth: depth + 1, to: &output)
            }
        case let list as [Any]:
            if list.isEmpty {
                output += line + styled(L("пусто"), .secondary) + AttributedString("\n")
            } else if list.count <= 12, list.allSatisfy({ !($0 is TDNode) && !($0 is [Any]) }) {
                for (index, element) in list.enumerated() {
                    if index > 0 { line += AttributedString(", ") }
                    line += scalar(element, key: nil)
                }
                output += line + AttributedString("\n")
            } else {
                output += line + styled(L("\(list.count) шт."), .secondary) + AttributedString("\n")
                for (index, element) in list.enumerated() {
                    append(value: element, key: "[\(index)]", depth: depth + 1, to: &output)
                }
            }
        default:
            output += line + scalar(value, key: key) + AttributedString("\n")
        }
    }

    private static func scalar(_ value: Any, key: String?) -> AttributedString {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return styled(number.boolValue ? L("да") : L("нет"), .orange)
        case let number as NSNumber:
            var text = styled(number.stringValue, .blue)
            if let key, dateKeys.contains(key), number.doubleValue > 1_000_000_000 {
                let date = Date(timeIntervalSince1970: number.doubleValue)
                let readable = date.formatted(.dateTime.day().month(.wide).year().hour().minute().second().locale(Loc.locale))
                text += styled("  (\(readable))", .secondary)
            }
            return text
        case let string as String:
            // Long values (file references, base64 thumbnails) are cut so the tree stays readable.
            let shown = string.count > 160 ? String(string.prefix(160)) + "…" : string
            return styled("\"\(shown)\"", .green)
        case is NSNull:
            return styled(L("нет"), .secondary)
        default:
            return AttributedString(String(describing: value))
        }
    }

    private static func styled(_ text: String, _ color: Color) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = color
        return result
    }
}
