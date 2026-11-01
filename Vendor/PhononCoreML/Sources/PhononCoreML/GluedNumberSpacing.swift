// Post-processing rule: put a space where the recognizer glued prose words and numbers together
// ("at10" -> "at 10", "July2020" -> "July 2020", "5minutes" -> "5 minutes", "3pm" -> "3 pm") and leave identifiers alone
// (HbA1c, x1, 11th, 1990s, 3D, md5, ch1, fy26, 10mm, spo2). Port of analysis/digsp/digsp.py; decisions are identical on ASCII
// letter/digit runs. Idempotent, ASCII-only matching (Devanagari and other scripts are never altered), pure and thread-safe.
import Foundation

public enum GluedNumberSpacing {
    static let words: Set<String> = Set(GluedNumberWords.list.split(separator: "\n").map(String.init))
    // Month names are capitalised dictionary entries (absent from the lowercase list) but are plain prose before a year.
    static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let function: Set<String> = ["in", "at", "by", "on", "of", "to", "or", "so", "up", "is", "as", "from", "for", "and", "about", "till", "until", "since"]
    static let keepPrefix: Set<String> = ["bit", "bits", "hex", "oct", "sub", "str", "num", "sq", "sqr", "abc", "emp", "stud", "var", "tmp", "temp", "min", "max", "sum", "avg", "arr", "ptr", "obj", "cat", "dog", "row", "col", "int", "float", "char", "bin", "div", "mod", "exp", "log", "sin", "cos", "tan", "pos", "neg", "len", "buf", "msg", "opt", "cfg", "idx", "ref", "val", "res", "ret", "cnt", "fig", "eq", "tab", "lan", "car", "map", "set", "add", "cars", "omega", "rho", "zero", "one", "ode", "sox", "alpha", "beta", "gamma", "delta", "theta", "sigma", "lambda", "tau", "phi", "psi", "eta", "this", "there"]
    static let keepSuffix: Set<String> = ["bit", "bits", "byte", "bytes", "hz", "khz", "mhz", "ghz", "kb", "mb", "gb", "tb", "db", "mm", "cm", "km", "kg", "mg", "ml", "cc", "min", "sec", "ms", "ns", "us", "fps", "dpi", "rpm", "kv", "mv", "ma", "mah", "bps", "kbps", "mbps", "gbps", "ppm", "pct", "th", "st", "nd", "rd", "x", "k", "m", "s", "d", "v", "w", "l", "g", "c", "f", "a", "b", "p", "h", "n", "r", "t"]
    // letters+digits or digits+letters, delimited by anything that is not an ASCII letter or digit
    static let token = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])([A-Za-z]+)([0-9]+)(?![A-Za-z0-9])|(?<![A-Za-z0-9])([0-9]+)([A-Za-z]+)(?![A-Za-z0-9])")

    static func splitsWordNumber(_ letters: String, digits: String, months useMonths: Bool = true) -> Bool {
        let l = letters.lowercased()
        if l.utf8.count < 2 { return false }
        if l.utf8.count == 2 { return function.contains(l) && digits.utf8.count >= 2 }
        if keepPrefix.contains(l) { return false }
        return words.contains(l) || function.contains(l) || (useMonths && months.contains(l))
    }
    static func splitsNumberWord(_ letters: String) -> Bool {
        let l = letters.lowercased()
        if l == "am" || l == "pm" { return true }
        if keepSuffix.contains(l) || l.utf8.count < 4 { return false }
        return words.contains(l)
    }

    /// Characters that make a glued run part of a URL, e-mail, path, version or code-like token when they touch it.
    static let joiners: Set<unichar> = Set("/\\@_#$~=<>+&%*^|[]{}".utf16)
    static func isAlnum(_ c: unichar) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }

    /// True when the match sits in a URL, e-mail, path or code-like token (touching a joiner, or dot/dash/colon/comma-less joined to more text).
    static func isEmbedded(_ ns: NSString, _ r: NSRange) -> Bool {
        if r.location > 0 {
            let p = ns.character(at: r.location - 1)
            if joiners.contains(p) || p == 46 || p == 45 || p == 58 { return true }          // . - :
        }
        let end = r.location + r.length
        if end < ns.length {
            let n = ns.character(at: end)
            if joiners.contains(n) { return true }
            if n == 46 || n == 45 || n == 58 {                                                // . - : only when more of the token follows
                if end + 1 < ns.length, isAlnum(ns.character(at: end + 1)) { return true }
                if n == 45 { return true }
            }
        }
        return false
    }

    /// `months: false` reproduces the Python reference exactly (used by the parity test); the app uses the default.
    public static func apply(_ text: String, months: Bool = true) -> String {
        // Cheap exit: nothing to do without an ASCII digit.
        guard text.utf8.contains(where: { $0 >= 48 && $0 <= 57 }) else { return text }
        let ns = text as NSString
        let matches = token.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        let out = NSMutableString(string: text)
        var offset = 0
        for m in matches {
            let replacement: String
            if m.range(at: 1).location != NSNotFound {
                let a = ns.substring(with: m.range(at: 1)), d = ns.substring(with: m.range(at: 2))
                guard splitsWordNumber(a, digits: d, months: months) else { continue }
                replacement = a + " " + d
            } else {
                let d = ns.substring(with: m.range(at: 3)), a = ns.substring(with: m.range(at: 4))
                guard splitsNumberWord(a) else { continue }
                replacement = d + " " + a
            }
            if isEmbedded(ns, m.range) { continue }
            out.replaceCharacters(in: NSRange(location: m.range.location + offset, length: m.range.length), with: replacement)
            offset += 1
        }
        return out as String
    }

    // uiui: S1 emits times, decimals and thousands as separate spaced tokens ("to3 :30 ,", "10 .5 %", "2 ,000", "21 st").
    // A two-letter preposition before one digit is split here rather than in `apply`, whose rules match the Python reference.
    static let shortWordDigit = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9/\\\\@_#$~=<>+&%*^|.:-])([Aa]t|[Tt]o|[Bb]y|[Oo]n|[Oo]f)([0-9])(?![A-Za-z0-9/\\\\@_#$~=<>+&%*^|-])")
    static let insideNumber = try! NSRegularExpression(pattern: "([0-9]) ([:.,])(?=[0-9])")
    static let afterNumber = try! NSRegularExpression(pattern: "([0-9]) ([,.?!:;%])(?![A-Za-z0-9])")
    static let ordinal = try! NSRegularExpression(pattern: "([0-9]) (st|nd|rd|th)(?![A-Za-z0-9])")

    /// The text a person reads: `apply`, then numbers closed up with their punctuation. Idempotent, ASCII-only matching.
    public static func applyForDictation(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 >= 48 && $0 <= 57 }) else { return text }
        func replacing(_ regex: NSRegularExpression, _ value: String, with template: String) -> String {
            regex.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length), withTemplate: template)
        }
        var value = replacing(shortWordDigit, text, with: "$1 $2")
        value = apply(value)
        value = replacing(insideNumber, value, with: "$1$2")
        value = replacing(afterNumber, value, with: "$1$2")
        return replacing(ordinal, value, with: "$1$2")
    }
}
