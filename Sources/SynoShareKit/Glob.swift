import Foundation

/// A path glob over `rel_path`: `*` and `?` stay within one segment, `**` crosses
/// segments (`**/` also matches no folder at all). A folder is selected with `folder/**`.
/// Matching ignores case, like the exFAT and APFS volumes files are saved to.
public struct Glob: @unchecked Sendable {
    public let pattern: String
    private let regex: NSRegularExpression

    public init(_ pattern: String) throws {
        self.pattern = pattern
        regex = try NSRegularExpression(pattern: "^" + Self.translate(pattern) + "$", options: [.caseInsensitive])
    }

    public func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    static func translate(_ pattern: String) -> String {
        var result = ""
        var rest = Substring(pattern)
        while let character = rest.first {
            if rest.hasPrefix("**/") {
                result += "(?:.*/)?"
                rest = rest.dropFirst(3)
                continue
            }
            if rest.hasPrefix("**") {
                result += ".*"
                rest = rest.dropFirst(2)
                continue
            }
            switch character {
            case "*": result += "[^/]*"
            case "?": result += "[^/]"
            default: result += NSRegularExpression.escapedPattern(for: String(character))
            }
            rest = rest.dropFirst()
        }
        return result
    }
}
