import Foundation
import Testing
@testable import KaruCore

// M17 T17.5 — the pure candidate engine: matching tiers, sources, ranking,
// case handling, triggers, members and the replacement range.

/// Runs the engine on `source`, whose `│` marks the caret (removed). The
/// snapshot and word index are built from the text as given (fresh), or from
/// `snapshotText` (an older version whose edits are journaled as one
/// insertion of `typed` at the caret).
private func complete(_ source: String, language: String, manual: Bool = false, typed: String = "",
                      recent: RecentAccepts = RecentAccepts(), unmappable: Bool = false,
                      snapshot useSnapshot: Bool = true) -> CompletionResult? {
    let marker = (source as NSString).range(of: "│")
    precondition(marker.location != NSNotFound, "no caret marker")
    let plain = (source as NSString).replacingCharacters(in: marker, with: "")
    let caret = marker.location
    let def = language.isEmpty ? nil : LanguageRegistry.definition(forIdentifier: language)
    // The snapshot / index see the text without `typed`; the live text has it.
    let base = (plain as NSString).replacingCharacters(
        in: NSRange(location: caret - typed.utf16.count, length: typed.utf16.count), with: "")
    var request = CompletionRequest(text: plain as NSString, caret: caret, languageIdentifier: language)
    request.manual = manual
    request.keywords = def?.keywords ?? []
    request.builtins = def?.builtins ?? []
    if useSnapshot, !language.isEmpty {
        request.snapshot = DeclarationScan.scan(text: base, languageIdentifier: language)
        request.snapshotVersion = 1
    }
    if !typed.isEmpty {
        request.snapshotJournal.record(editedRange: NSRange(location: caret - typed.utf16.count,
                                                            length: typed.utf16.count),
                                       changeInLength: typed.utf16.count)
        request.wordsJournal = request.snapshotJournal
    }
    if unmappable {
        for _ in 0...EditJournal.capacity {
            request.snapshotJournal.record(editedRange: NSRange(location: 0, length: 0), changeInLength: 0)
        }
    }
    request.words = WordIndex(text: base, languageIdentifier: language)
    request.recent = recent
    request.scanner = CandidateEngine.contextScanner(for: language, definition: def)
    var engine = CandidateEngine()
    var checkpoints = CheckpointStore()
    return engine.complete(request, checkpoints: &checkpoints)
}

private func names(_ result: CompletionResult?) -> [String] { result?.candidates.map(\.name) ?? [] }

private func candidate(_ result: CompletionResult?, _ name: String) -> Candidate? {
    result?.candidates.first { $0.name == name }
}

@Suite("CandidateEngine", .serialized)
struct CandidateEngineTests {

    // MARK: Matching tiers

    @Test func matcherTiersAndRanges() {
        let m = CandidateMatcher("use")
        #expect(m.match("userCount", allowFuzzy: true)?.tier == .exactPrefix)
        #expect(m.match("userCount", allowFuzzy: true)?.ranges == [NSRange(location: 0, length: 3)])
        #expect(m.match("UserCount", allowFuzzy: true)?.tier == .caseInsensitivePrefix)

        let initials = CandidateMatcher("udn")
        let camel = initials.match("userDisplayName", allowFuzzy: false)
        #expect(camel?.tier == .wordStart)
        #expect(camel?.ranges == [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1),
                                  NSRange(location: 11, length: 1)])
        let snake = initials.match("user_display_name", allowFuzzy: false)
        #expect(snake?.tier == .wordStart)
        #expect(snake?.ranges == [NSRange(location: 0, length: 1), NSRange(location: 5, length: 1),
                                  NSRange(location: 13, length: 1)])
        // Parts continue: `usdn`.
        #expect(CandidateMatcher("usdn").match("userDisplayName", allowFuzzy: false)?.ranges
                == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 1), NSRange(location: 11, length: 1)])
        // Upper runs and digits split parts.
        #expect(CandidateMatcher.partStarts(Array("URLValue".utf16)) == [0, 3])
        #expect(CandidateMatcher.partStarts(Array("utf8Name".utf16)) == [0, 3, 4])
        #expect(CandidateMatcher("uv").match("URLValue", allowFuzzy: false)?.tier == .wordStart)
        // Fuzzy: ordered subsequence from a part start, only when allowed.
        let loose = CandidateMatcher("ucnt")
        #expect(loose.match("userCount", allowFuzzy: false) == nil)
        let fuzzy = loose.match("userCount", allowFuzzy: true)
        #expect(fuzzy?.tier == .fuzzy)
        #expect(fuzzy?.ranges == [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1),
                                  NSRange(location: 7, length: 2)])
        #expect(CandidateMatcher("zz").match("userCount", allowFuzzy: true) == nil)
    }

    @Test func tiersOrderTheList() {
        let text = """
        def f(userDisplayName, UserCount, userCount, under_cover_value):
            usc│
        """
        // `usc`: no prefix match; word-start `userCount`? u-s(er)-C ✓.
        let result = complete(text, language: "python")
        let list = names(result)
        #expect(candidate(result, "userCount")?.matchTier == .wordStart)
        #expect(candidate(result, "UserCount")?.matchTier == .wordStart)
        #expect(!list.contains("under_cover_value") || candidate(result, "under_cover_value")!.matchTier == .fuzzy)

        let prefixText = """
        def g(user_total, User_total, uxer_tool):
            user_t│
        """
        let ordered = names(complete(prefixText, language: "python"))
        #expect(Array(ordered.prefix(2)) == ["user_total", "User_total"])
    }

    @Test func wordStartFindsCamelAndSnakeNames() {
        let py = """
        def profile(user_display_name, user_id):
            print(user_id)
            return udn│
        """
        #expect(names(complete(py, language: "python")).first == "user_display_name")
        let js = """
        function profile(userDisplayName, userDomain) {
          return udn│;
        }
        """
        let result = complete(js, language: "javascript")
        #expect(names(result).first == "userDisplayName")
        #expect(candidate(result, "userDisplayName")?.matchedRanges.count == 3)
    }

    // MARK: Sources and ranking

    @Test func sourceOrderScopeThenFileThenKeywordThenWord() {
        let text = """
        # retword in a comment
        def retfile():
            pass

        def main(retparam):
            ret│
        """
        let result = complete(text, language: "python")
        let list = names(result)
        let order = ["retparam", "retfile", "return", "retword"].compactMap { list.firstIndex(of: $0) }
        #expect(order.count == 4)
        #expect(order == order.sorted())
        #expect(candidate(result, "retparam")?.source == .scope)
        #expect(candidate(result, "retparam")?.kind == .parameter)
        #expect(candidate(result, "retfile")?.source == .fileDeclaration)
        #expect(candidate(result, "return")?.source == .keyword)
        #expect(candidate(result, "retword")?.source == .documentWord)
    }

    @Test func currentFunctionOutranksAnotherFunctionsNames() {
        // py-scope-01: `user_count` / `user_config` (current params) above
        // `user_cache` (another function's parameter: only a word here).
        let text = """
        def render(user_count, user_config):
            header = str(user_count)
            print(header, user_count)
            return format_page(user_c│)


        def refresh(user_cache):
            return user_cache
        """
        let list = names(complete(text, language: "python", typed: "user_c"))
        #expect(Array(list.prefix(3)) == ["user_count", "user_config", "user_cache"])
    }

    @Test func shadowingKeepsOneCandidateFromTheNearestScope() {
        let text = """
        label_text = "global"

        def draw(label_width):
            label_text = "local " + str(label_width)
            return label_│
        """
        let result = complete(text, language: "python")
        #expect(result?.candidates.filter { $0.name == "label_text" }.count == 1)
        #expect(candidate(result, "label_text")?.source == .scope)
        #expect(candidate(result, "label_text")?.scopeDepth == 0)
        #expect(candidate(result, "label_text")?.sources.contains(.fileDeclaration) == true)
        #expect(Set(names(result).prefix(2)) == ["label_text", "label_width"])
    }

    @Test func enclosingScopesRankAfterTheCurrentFunction() {
        let text = """
        def outer(count_outer):
            def inner(count_inner):
                return count_│
            return inner
        """
        let result = complete(text, language: "python")
        #expect(Array(names(result).prefix(2)) == ["count_inner", "count_outer"])
        #expect(candidate(result, "count_outer")?.scopeDepth == 1)
    }

    @Test func nearbyUseBreaksTiesThenRecentThenDictionary() {
        let text = """
        def f(alpha_one, alpha_two, alpha_three):
            x = alpha_three
            return alpha_│
        """
        // Same tier and source: the one used on the line above wins.
        #expect(names(complete(text, language: "python")).first == "alpha_three")
        let noUse = """
        def f(alpha_one, alpha_two):
            return alpha_│
        """
        #expect(Array(names(complete(noUse, language: "python")).prefix(2)) == ["alpha_one", "alpha_two"])
        var recent = RecentAccepts()
        recent.record(CandidateIdentity(name: "alpha_two", group: .value))
        #expect(names(complete(noUse, language: "python", recent: recent)).first == "alpha_two")
    }

    @Test func recentAcceptsAreBounded() {
        var recent = RecentAccepts()
        for i in 0..<40 { recent.record(CandidateIdentity(name: "n\(i)", group: .value)) }
        #expect(recent.entries.count == RecentAccepts.capacity)
        #expect(recent.rank(of: CandidateIdentity(name: "n39", group: .value)) == 0)
        #expect(recent.rank(of: CandidateIdentity(name: "n0", group: .value)) == nil)
        recent.record(CandidateIdentity(name: "n30", group: .value))
        #expect(recent.rank(of: CandidateIdentity(name: "n30", group: .value)) == 0)
        #expect(recent.entries.count == RecentAccepts.capacity)
    }

    // MARK: Case

    @Test func distinctSpellingsStayDistinctExactCaseFirst() {
        let text = """
        const URLValue = new URL('https://example.com');
        let urlValue = URLValue.href;
        console.log(url│);
        """
        let result = complete(text, language: "javascript", typed: "url")
        let list = names(result)
        #expect(list.contains("URLValue"))
        #expect(list.contains("urlValue"))
        #expect(list.firstIndex(of: "urlValue")! < list.firstIndex(of: "URLValue")!)
        #expect(candidate(result, "urlValue")?.matchTier == .exactPrefix)
        #expect(candidate(result, "URLValue")?.matchTier == .caseInsensitivePrefix)
    }

    @Test func caseCorrectionIsOffered() {
        let text = """
        const URLValue = 1;
        console.log(urlvalue│);
        """
        let list = names(complete(text, language: "javascript", typed: "urlvalue"))
        #expect(list.first == "URLValue")
    }

    @Test func plainTextMergesSpellingsCaseInsensitively() {
        let text = """
        Configuration drift: the configuration repo and the confirmed values differ.
        compare conf│
        """
        let result = complete(text, language: "", typed: "conf")
        let list = names(result)
        #expect(list.filter { $0.lowercased() == "configuration" }.count == 1)
        #expect(list.contains("configuration"))
        #expect(list.contains("confirmed"))
    }

    // MARK: The identifier being typed

    @Test func typedIdentifierWithNoOtherOccurrenceIsDropped() {
        let fresh = """
        def f(alpha):
            brandnew│
        """
        #expect(complete(fresh, language: "python", typed: "brandnew") == nil)
        let existing = """
        def f(brandnew):
            brandnew│
        """
        #expect(names(complete(existing, language: "python", typed: "brandnew")).contains("brandnew"))
        // Another word's occurrence elsewhere keeps it too.
        let elsewhere = """
        # brandnew is mentioned here
        def f(alpha):
            brandnew│
        """
        #expect(names(complete(elsewhere, language: "python", typed: "brandnew")).contains("brandnew"))
    }

    // MARK: Triggers and positions

    @Test func noAutoPopupInStringsOrCommentsButManualGivesWords() {
        let comment = """
        def notes(cart_note):
            # remember the cart_│
            return cart_note
        """
        #expect(complete(comment, language: "python") == nil)
        let manual = complete(comment, language: "python", manual: true)
        #expect(manual?.context.position == .comment)
        #expect(manual?.candidates.allSatisfy { $0.source == .documentWord } == true)
        #expect(names(manual).contains("cart_note"))

        let string = """
        function notes(cartNote) {
          const hint = "cartN│";
        }
        """
        #expect(complete(string, language: "javascript") == nil)
        #expect(complete(string, language: "javascript", manual: true)?.context.position == .string)
    }

    @Test func dataFormatStringsCompleteLikePlainText() {
        let json = """
        {"customer_name": "a", "customer_note": "b", "cust│": 1}
        """
        let result = complete(json, language: "json")
        #expect(result?.context.position == .plainText)
        #expect(names(result).contains("customer_name"))
        #expect(names(result).contains("customer_note"))
    }

    @Test func interpolationIsCode() {
        let js = """
        function label(price, qty) {
          return `Total: ${price * qt│}`;
        }
        """
        let jsResult = complete(js, language: "javascript")
        #expect(jsResult?.context.position == .code)
        #expect(names(jsResult).first == "qty")
        let py = """
        def greet(user_name, user_nickname):
            return f"Hello {user_n│}!"
        """
        let pyResult = complete(py, language: "python")
        #expect(pyResult?.context.position == .code)
        #expect(Set(names(pyResult).prefix(2)) == ["user_name", "user_nickname"])
        // Outside the field the f-string is a string.
        let outside = """
        def greet(user_name):
            return f"Hello user_n│ {user_name}"
        """
        #expect(complete(outside, language: "python") == nil)
    }

    @Test func shortPrefixesAndDigitsDoNotTrigger() {
        #expect(complete("def f(alpha):\n    a│", language: "python") == nil)
        #expect(complete("def f(alpha):\n    12│", language: "python") == nil)
        #expect(complete("def f(alpha):\n    al│", language: "python") != nil)
        // Manual allows the empty prefix: the current scope's names.
        let manual = complete("x_mod = 1\ndef f(alpha, beta):\n    │", language: "python", manual: true)
        #expect(Set(names(manual)) == ["alpha", "beta"])
    }

    // MARK: Members

    @Test func pythonSelfMembersIncludeAssignedAttributes() {
        let text = """
        class Client:
            def __init__(self, host, timeout=5):
                self.host = host
                self.timeout = timeout
                self.retries, self.pool = 3, None

            def connect(self):
                return self.│

        class Session:
            def __init__(self):
                self.token = ""

            def commit(self):
                return True
        """
        let result = complete(text, language: "python")
        let list = Set(names(result))
        #expect(list.isSuperset(of: ["host", "timeout", "retries", "pool", "connect", "__init__"]))
        #expect(!list.contains("token"))
        #expect(!list.contains("commit"))
        #expect(candidate(result, "host")?.source == .selfMember)
        #expect(candidate(result, "connect")?.kind == .method)
        #expect(candidate(result, "timeout")?.kind == .property)
    }

    @Test func instanceAttributesAreNotBindingsOfTheMethod() {
        let text = """
        class Client:
            def __init__(self, host):
                self.port = 80
                return None
        """
        let scan = DeclarationScan.scan(text: text, languageIdentifier: "python")
        let inside = (text as NSString).range(of: "return").location
        #expect(!scan.visibleBindings(at: inside).map(\.name).contains("port"))
        #expect(scan.declarations.contains { $0.name == "port" && $0.kind == .property && !$0.isListed })
        #expect(DeclarationQueryIndex(scan: scan).classMembers(at: inside)?.map(\.name).contains("port") == true)
        // Not listed: highlighting and navigation are unchanged.
        #expect(!scan.completionSymbols.contains("port"))
    }

    @Test func javascriptThisMembers() {
        let text = """
        class Counter {
          constructor(start = 0) {
            this.count = start;
            this.step = 1;
          }
          increment() {
            return this.│;
          }
          reset() {}
        }
        class Basket {
          constructor() { this.fruits = []; }
          weigh() { return 1; }
        }
        """
        let result = complete(text, language: "javascript")
        let list = Set(names(result))
        #expect(list.isSuperset(of: ["count", "step", "increment", "reset"]))
        #expect(!list.contains("fruits"))
        #expect(!list.contains("weigh"))
        #expect(result?.context.memberAccess?.isSelfOrThis == true)
    }

    @Test func receiverUsageEvidenceAndRebinding() {
        let text = """
        def usage(obj, order, user):
            obj.render()
            print(obj.size)
            print(order.id, order.total)
            print(user.id, user.email)
            order.│
        """
        let result = complete(text, language: "python")
        #expect(Set(names(result)) == ["id", "total"])
        #expect(candidate(result, "id")?.source == .receiverUsage)

        let rebound = """
        def usage(obj):
            print(obj.old_name)
            obj = make()
            print(obj.new_name)
            obj.│
        """
        let reboundResult = complete(rebound, language: "python")
        #expect(names(reboundResult) == ["new_name", "old_name"])
        #expect(candidate(reboundResult, "old_name")?.source == .staleReceiverUsage)
        #expect(candidate(reboundResult, "new_name")?.source == .receiverUsage)
        #expect(candidate(reboundResult, "new_name")?.kind == .property)
    }

    @Test func dotWithoutEvidenceShowsNothing() {
        let text = """
        def f(value):
            print(other.name)
            value.│
        """
        #expect(complete(text, language: "python") == nil)
        // With a prefix it falls back to document words only.
        let prefixed = """
        def f(value, name_param):
            value.na│
        """
        let result = complete(prefixed, language: "python")
        #expect(result?.candidates.allSatisfy { $0.source == .documentWord } == true)
        // Spread / range dots are no member access.
        let spread = "function f(...restItems) { return [...restI│]; }"
        #expect(complete(spread, language: "javascript")?.context.memberAccess == nil)
        #expect(names(complete(spread, language: "javascript")).first == "restItems")
    }

    // MARK: Replacement range and characters

    @Test func wholeIdentifierIsTheReplacementRange() {
        let text = """
        function badge(userCount) {
          return userCo│unt + 1;
        }
        """
        let result = complete(text, language: "javascript", typed: "o")
        let caret = (text as NSString).range(of: "│").location
        #expect(result?.context.prefix == "userCo")
        #expect(result?.context.identifier == "userCount")
        #expect(result?.context.prefixRange == NSRange(location: caret - 6, length: 6))
        #expect(result?.context.replacementRange == NSRange(location: caret - 6, length: 9))
        #expect(names(result).first == "userCount")
    }

    @Test func javascriptDollarIdentifiers() {
        let text = """
        const $store = createStore();
        const $element = find();
        $st│
        """
        let result = complete(text, language: "javascript", typed: "$st")
        #expect(result?.context.prefix == "$st")
        #expect(names(result).first == "$store")
        // `$` is no identifier character in Python.
        #expect(complete("$store = 1\n$st│", language: "python")?.context.prefix == "st")
    }

    @Test func nonBMPIdentifierCharacters() {
        // U+1D465 MATHEMATICAL ITALIC SMALL X is a letter outside the BMP.
        let text = "\u{1D465}value = 1\n\u{1D465}v│"
        let result = complete(text, language: "python")
        #expect(result?.context.prefix == "\u{1D465}v")
        #expect(result?.context.prefixRange.length == 3)
        #expect(names(result).first == "\u{1D465}value")
        // Combining marks continue an identifier.
        let marks = "cafe\u{301}_total = 1\ncafe\u{301}│"
        #expect(complete(marks, language: "python")?.context.prefix == "cafe\u{301}")
    }

    // MARK: Fallbacks

    @Test func unmappableJournalFallsBackToModuleNames() {
        let text = """
        def module_func():
            pass

        def f(module_param):
            module_│
        """
        let result = complete(text, language: "python", unmappable: true)
        let list = names(result)
        #expect(candidate(result, "module_func")?.source == .fileDeclaration)
        // No scope query without a trustworthy offset: the parameter is a word.
        #expect(candidate(result, "module_param")?.source == .documentWord)
        #expect(list.contains("module_param"))
    }

    @Test func nameTypedAfterTheSnapshotIsOfferedImmediately() {
        // The snapshot and word index predate `fresh_total` (typed on the line
        // above); the nearby-line scan offers it at once.
        let typedLine = "    fresh_total = 1\n    fresh_t"
        let text = """
        def f(alpha):
        \(typedLine)│
        """
        let result = complete(text, language: "python", typed: typedLine)
        #expect(names(result).first == "fresh_total")
        #expect(candidate(result, "fresh_total")?.source == .documentWord)
    }

    @Test func growingPrefixReusesTheMatchedSet() {
        let text = "def f(alpha_beta, alpha_gamma):\n    al"
        var engine = CandidateEngine()
        var checkpoints = CheckpointStore()
        func request(_ live: String) -> CompletionRequest {
            var r = CompletionRequest(text: live as NSString, caret: (live as NSString).length,
                                      languageIdentifier: "python")
            r.snapshot = DeclarationScan.scan(text: text, languageIdentifier: "python")
            r.snapshotVersion = 7
            r.snapshotJournal.record(editedRange: NSRange(location: (text as NSString).length,
                                                          length: (live as NSString).length - (text as NSString).length),
                                     changeInLength: (live as NSString).length - (text as NSString).length)
            r.words = WordIndex(text: text, languageIdentifier: "python")
            r.scanner = CandidateEngine.contextScanner(for: "python", definition: nil)
            return r
        }
        let first = engine.complete(request(text), checkpoints: &checkpoints)
        #expect(!engine.lastReusedMatches)
        #expect(Set(names(first)) == ["alpha_beta", "alpha_gamma"])
        let second = engine.complete(request(text + "pha_g"), checkpoints: &checkpoints)
        #expect(engine.lastReusedMatches)
        #expect(names(second) == ["alpha_gamma"])
        // Backspace recomputes.
        _ = engine.complete(request(text + "pha_"), checkpoints: &checkpoints)
        #expect(!engine.lastReusedMatches)
    }
}
