import Foundation

typealias TDNode = [String: Any]

extension Dictionary where Key == String, Value == Any {
    var tdType: String { self["@type"] as? String ?? "" }

    /// JSONSerialization hands out bridged NSStrings. They are copied into native Swift storage once here:
    /// kept in chats and messages, bridged strings made every copy, comparison and hash go through CoreFoundation.
    func tdString(_ key: String) -> String {
        guard var value = self[key] as? String else { return "" }
        value.makeContiguousUTF8()
        return value
    }
    func tdInt(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? 0 }
    func tdDouble(_ key: String) -> Double { (self[key] as? NSNumber)?.doubleValue ?? 0 }
    func tdBool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
    func tdNode(_ key: String) -> TDNode? { self[key] as? TDNode }
    func tdNodes(_ key: String) -> [TDNode] { self[key] as? [TDNode] ?? [] }

    /// int53 fields arrive as JSON numbers, int64 fields (e.g. `chatPosition.order`) as strings.
    func tdInt64(_ key: String) -> Int64 {
        if let number = self[key] as? NSNumber { return number.int64Value }
        if let string = self[key] as? String { return Int64(string) ?? 0 }
        return 0
    }

    func tdInt64s(_ key: String) -> [Int64] {
        (self[key] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value ?? Int64($0 as? String ?? "") }
    }

    /// Plain text of a nested `formattedText` field.
    func tdText(_ key: String) -> String { tdNode(key)?.tdString("text") ?? "" }
}
