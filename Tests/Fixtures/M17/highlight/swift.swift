import Foundation

/* Outer block comment
   /* Swift block comments nest */
   func notReal() -> Int { return 0 } — still a comment
*/

/// A greeting renderer. `code` in doc comments stays comment-coloured.
struct Greeter {
    var name: String
    var count: Int = 0

    /// Multi-line string with interpolation, including a nested string literal.
    func letter(signedBy author: String) -> String {
        """
        Dear \(name),

        You have \(count) new \(count == 1 ? "message" : "messages").
        Signature: \(author.uppercased()) — "quoted" text stays string.
        Nested: \(["a", "b"].map { "\($0)!" }.joined(separator: ", "))
        // this is not a comment
        """
    }

    /// Raw strings: backslashes are literal, `\#(…)` interpolates.
    func pattern() -> String {
        #"^\d+\.\d+ "\(not interpolated)" and \#(name) interpolated$"#
    }

    func rawMultiline() -> String {
        #"""
        Raw block: \n stays literal, a lone """ does not end it,
        and \#(count) is interpolated.
        """#
    }
}

enum Level: String, CaseIterable {
    case debug, info /* inline comment */, warning = "warn"
}

final class Ledger {
    private var entries: [String: Double] = [:]

    func record(_ key: String, amount: Double) {
        entries[key, default: 0] += amount
    }

    func ratio(of a: Double, to b: Double) -> Double {
        a / b / 2 // two divisions
    }

    var summary: String {
        let total = entries.values.reduce(0, +)
        return "Ledger(\(entries.count) entries, total \(String(format: "%.2f", total)))"
    }
}

let quote: Character = "\""
let escaped = "tab\t \"quote\" /* not a comment */ // nor this"
let greeter = Greeter(name: "Ada", count: 2)
print(greeter.letter(signedBy: "Karu"), greeter.pattern(), greeter.rawMultiline())

let ledger = Ledger()
ledger.record("coffee", amount: 3.5)
/* multi-line
   /* nested */
   comment before the last statement */
print(ledger.summary, ledger.ratio(of: 9, to: 3), quote, escaped, Level.allCases)
