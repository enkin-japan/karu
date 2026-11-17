import Foundation
import Testing
@testable import KaruCore

// Measures LanguageSniffer.rank on three corpora and asserts the limits agreed
// for the evidence-scoring detector (LEDGER「无扩展名文本的语言识别改造」):
// A. windows cut from the M17 highlight fixtures at test time;
// B. common paste shapes (Tests/Fixtures/LanguageDetection/shapes.json);
// C. non-code text that must never be set automatically (negatives.json).
// Every group prints a report line so the numbers can be read from the output.

private let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private let highlightFixtures = testsRoot.appendingPathComponent("Fixtures/M17/highlight")
private let corpusFixtures = testsRoot.appendingPathComponent("Fixtures/LanguageDetection")

private struct Shape: Decodable {
    let name: String
    let language: String
    let text: String
}

private struct Negative: Decodable {
    let name: String
    let text: String
}

/// Accepted near pairs: the detector may answer the safer, more general member.
private func isAccepted(_ got: String, for wanted: String) -> Bool {
    if got == wanted { return true }
    switch wanted {
    case "cpp": return got == "c"
    case "typescript": return got == "javascript"
    case "typescriptreact": return got == "typescript" || got == "javascript"
    default: return false
    }
}

private struct Outcome {
    let correct: Bool
    let wrong: Bool
    let covered: Bool
    let got: String?
    let candidates: [String]
}

private func evaluate(_ text: String, wanted: String) -> Outcome {
    let ranking = LanguageSniffer.rank(text)
    let ids = ranking.candidates.map(\.identifier)
    let correct = ranking.confident.map { isAccepted($0, for: wanted) } ?? false
    let wrong = ranking.confident != nil && !correct
    let covered = correct || ids.contains { isAccepted($0, for: wanted) }
    return Outcome(correct: correct, wrong: wrong, covered: covered, got: ranking.confident, candidates: ids)
}

private struct Tally {
    var total = 0, correct = 0, wrong = 0, covered = 0
    mutating func add(_ o: Outcome) {
        total += 1
        if o.correct { correct += 1 }
        if o.wrong { wrong += 1 }
        if o.covered { covered += 1 }
    }
    func rate(_ n: Int) -> Double { total == 0 ? 0 : Double(n) / Double(total) }
    func line(_ label: String) -> String {
        func pct(_ n: Int) -> String { String(format: "%.0f%%", rate(n) * 100) }
        return "\(label): correct \(correct) (\(pct(correct))) wrong \(wrong) covered \(covered) (\(pct(covered))) total \(total)"
    }
}

/// One window of a fixture file, sliced exactly as the 2026-11-17 baseline.
private struct Window {
    let file: String
    let language: String
    let size: Int
    let start: Int
    let text: String
}

private let windowFiles: [(String, String)] = [
    ("bash.sh", "bash"), ("c.c", "c"), ("cpp.cpp", "cpp"), ("csharp.cs", "csharp"), ("css.css", "css"),
    ("go.go", "go"), ("html.html", "html"), ("java.java", "java"), ("javascript.js", "javascript"),
    ("json.json", "json"), ("markdown.md", "markdown"), ("python.py", "python"), ("rust.rs", "rust"),
    ("sql.sql", "sql"), ("swift.swift", "swift"), ("toml.toml", "toml"), ("typescript.ts", "typescript"),
    ("xml.xml", "xml"), ("yaml.yaml", "yaml"),
]

private func makeWindows() throws -> [Window] {
    var windows: [Window] = []
    for (file, language) in windowFiles {
        let content = try String(contentsOf: highlightFixtures.appendingPathComponent(file), encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        for size in [8, 15, 30] {
            var starts: [Int] = []
            var start = 0
            while start <= lines.count - size {
                starts.append(start)
                start += size
            }
            if starts.isEmpty { starts = [0] }
            if starts.count > 12 {
                let count = starts.count
                starts = (0..<12).map { starts[Int(Double($0) * Double(count) / 12)] }
            }
            for s in starts {
                let text = lines[s..<min(s + size, lines.count)].joined(separator: "\n")
                let visible = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
                if visible < 60 { continue }
                windows.append(Window(file: file, language: language, size: size, start: s, text: text))
            }
        }
    }
    return windows
}

@Suite("Language detection corpus")
struct LanguageDetectionCorpusTests {
    @Test func fixtureWindows() throws {
        let windows = try makeWindows()
        var all = Tally()
        var bySize: [Int: Tally] = [:]
        var byLanguage: [String: Tally] = [:]
        var problems: [String] = []
        for window in windows {
            let outcome = evaluate(window.text, wanted: window.language)
            all.add(outcome)
            bySize[window.size, default: Tally()].add(outcome)
            byLanguage[window.language, default: Tally()].add(outcome)
            let where_ = "\(window.file) start \(window.start) size \(window.size)"
            if outcome.wrong {
                problems.append("WRONG \(where_): wanted \(window.language) got \(outcome.got ?? "-") candidates \(outcome.candidates)")
            } else if !outcome.covered {
                problems.append("uncovered \(where_): wanted \(window.language) candidates \(outcome.candidates)")
            } else if !outcome.correct {
                problems.append("candidate-only \(where_): wanted \(window.language) candidates \(outcome.candidates)")
            }
        }
        print("[corpus] " + all.line("windows"))
        for size in bySize.keys.sorted() {
            print("[corpus] " + bySize[size]!.line("windows size \(size)"))
        }
        for language in byLanguage.keys.sorted() {
            print("[corpus] " + byLanguage[language]!.line("windows \(language)"))
        }
        for problem in problems { print("[corpus] " + problem) }

        // Hard limit.
        #expect(all.wrong <= 3)
        // Targets (see the report for any gap).
        #expect(all.rate(all.correct) >= 0.55)
        #expect(all.rate(all.covered) >= 0.80)
        let thirty = bySize[30] ?? Tally()
        #expect(thirty.rate(thirty.correct) >= 0.85)
    }

    @Test func pasteShapes() throws {
        let data = try Data(contentsOf: corpusFixtures.appendingPathComponent("shapes.json"))
        let shapes = try JSONDecoder().decode([Shape].self, from: data)
        #expect(shapes.count >= 90)
        var all = Tally()
        var problems: [String] = []
        for shape in shapes {
            let outcome = evaluate(shape.text, wanted: shape.language)
            all.add(outcome)
            if outcome.wrong {
                problems.append("WRONG \(shape.name): wanted \(shape.language) got \(outcome.got ?? "-") candidates \(outcome.candidates)")
            } else if !outcome.covered {
                problems.append("uncovered \(shape.name): wanted \(shape.language) candidates \(outcome.candidates)")
            } else if !outcome.correct {
                problems.append("candidate-only \(shape.name): wanted \(shape.language) candidates \(outcome.candidates)")
            }
        }
        print("[corpus] " + all.line("shapes"))
        for problem in problems { print("[corpus] " + problem) }

        // Hard limits.
        #expect(all.wrong == 0)
        let userSnippet = """
            class Solution:
                def mySqrt(self, x: int) -> int:
                    left, right = 0, x
                    while right >= left:
                        middle = (left + right) // 2
                        square = middle * middle
                        if square == x:
                            return middle
                        elif square > x:
                            right = middle - 1
                        else:
                            left = middle + 1
                    return right
            """
        #expect(shapes.contains { $0.text.hasPrefix(userSnippet) })
        #expect(LanguageSniffer.rank(userSnippet).confident == "python")
        // Targets.
        #expect(all.rate(all.correct) >= 0.70)
        #expect(all.rate(all.covered) >= 0.90)
    }

    @Test func negatives() throws {
        let data = try Data(contentsOf: corpusFixtures.appendingPathComponent("negatives.json"))
        let negatives = try JSONDecoder().decode([Negative].self, from: data)
        #expect(negatives.count >= 45)
        var confident = 0
        var withCandidates = 0
        for negative in negatives {
            let ranking = LanguageSniffer.rank(negative.text)
            if let language = ranking.confident {
                confident += 1
                print("[corpus] WRONG negative \(negative.name): got \(language)")
            }
            if !ranking.candidates.isEmpty {
                withCandidates += 1
                print("[corpus] negative with candidates \(negative.name): \(ranking.candidates.map(\.identifier))")
            }
        }
        let rate = Double(withCandidates) / Double(max(negatives.count, 1))
        print("[corpus] negatives: confident \(confident) with candidates \(withCandidates) "
              + "(\(String(format: "%.0f%%", rate * 100))) total \(negatives.count)")

        // Hard limit.
        #expect(confident == 0)
        // Target.
        #expect(rate <= 0.15)
    }

    /// Samples written after the rules, by someone who did not write them, to
    /// catch rules fitted to the other corpora. They are a regression set now:
    /// do not tune against them; add new unseen samples to judge a rule change.
    @Test func heldOutSamples() throws {
        struct Sample: Decodable {
            let name: String
            let language: String?
            let text: String
        }
        let data = try Data(contentsOf: corpusFixtures.appendingPathComponent("holdout.json"))
        let samples = try JSONDecoder().decode([Sample].self, from: data)
        var code = Tally()
        var negativeTotal = 0, negativeConfident = 0, negativeWithCandidates = 0
        for sample in samples {
            guard let wanted = sample.language else {
                let ranking = LanguageSniffer.rank(sample.text)
                negativeTotal += 1
                if let language = ranking.confident {
                    negativeConfident += 1
                    print("[corpus] WRONG held-out negative \(sample.name): got \(language)")
                }
                if !ranking.candidates.isEmpty { negativeWithCandidates += 1 }
                continue
            }
            let outcome = evaluate(sample.text, wanted: wanted)
            code.add(outcome)
            if outcome.wrong {
                print("[corpus] WRONG held-out \(sample.name): wanted \(wanted) got \(outcome.got ?? "-")")
            } else if !outcome.correct {
                print("[corpus] held-out not confident \(sample.name): wanted \(wanted) candidates \(outcome.candidates)")
            }
        }
        print("[corpus] " + code.line("held-out"))
        print("[corpus] held-out negatives: confident \(negativeConfident) with candidates "
              + "\(negativeWithCandidates) total \(negativeTotal)")

        #expect(code.total >= 50 && negativeTotal >= 15)
        #expect(code.wrong == 0)
        #expect(negativeConfident == 0)
        // 52 of 53 when the set was first run (2026-11-17).
        #expect(code.correct >= 50)
        #expect(code.covered >= 52)
    }

    @Test func rankPerformance() throws {
        // An 8 KB sample of mixed real code (the sniffer's sample cap). It
        // opens with Go so that no start-of-document marker short-cuts the
        // scoring pass; the C file's long comment is left out for the same
        // reason (comment lines are skipped cheaply).
        var sample = ""
        let order = ["go.go", "swift.swift", "rust.rs", "typescript.ts", "java.java", "csharp.cs", "cpp.cpp",
                     "python.py", "css.css", "sql.sql", "yaml.yaml", "markdown.md", "toml.toml"]
        for file in order where sample.utf8.count < 8 * 1024 {
            sample += try String(contentsOf: highlightFixtures.appendingPathComponent(file), encoding: .utf8)
        }
        #expect(sample.utf8.count >= 8 * 1024)
        let text = String(decoding: Array(sample.utf8.prefix(8 * 1024)), as: UTF8.self)
        _ = LanguageSniffer.rank(text) // warm up lazily built tables
        var timings: [Double] = []
        for _ in 0..<50 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = LanguageSniffer.rank(text)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        timings.sort()
        let median = timings[timings.count / 2]
        print("[corpus] rank median \(String(format: "%.2f", median)) ms over 50 runs on \(text.utf8.count) bytes")
        #expect(median <= 5)
    }
}
