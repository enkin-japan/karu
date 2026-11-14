import Foundation
import Testing
@testable import KaruCore

// M17 T17.3a — the lexical profiles of the C family, CSS, SQL, Swift, TOML,
// HTML and XML, and the JS/TS regex-literal atom: cross-line boundary
// samples per construct (openers and closers on other lines, escapes at the
// closer, prefixes, nesting, interpolation, CDATA, regex vs division).
// T17.3b — Bash, YAML and Markdown: comment / quote contexts and the line
// blocks (heredocs, block scalars, fences).
// Every sample is tokenized in one pass and line by line with the carried
// state, and both must agree.

// MARK: - Helpers

/// Token kinds per UTF-16 unit of a sample (nil where no token).
private struct Analysed {
    let ns: NSString
    let kinds: [TokenKind?]

    /// The kinds over the `occurrence`-th (1-based) match of `piece`.
    func kinds(of piece: String, occurrence: Int = 1) -> Set<TokenKind?> {
        var from = 0
        var hit = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            hit = ns.range(of: piece, options: .literal, range: NSRange(location: from, length: ns.length - from))
            guard hit.location != NSNotFound else { return [] }
            from = hit.location + 1
        }
        return Set(kinds[hit.location..<NSMaxRange(hit)])
    }
}

private func analyse(_ language: String, _ text: String,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> Analysed {
    let def = try #require(LanguageRegistry.definition(forIdentifier: language), sourceLocation: sourceLocation)
    #expect(def.lexicalProfile != nil, sourceLocation: sourceLocation)
    let ns = text as NSString
    func perUnit(_ tokens: [(range: NSRange, kind: TokenKind)]) -> [TokenKind?] {
        var out = [TokenKind?](repeating: nil, count: ns.length)
        for token in tokens {
            for i in token.range.location..<NSMaxRange(token.range) { out[i] = token.kind }
        }
        return out
    }
    var state = LexicalScanState()
    let whole = perUnit(def.tokens(in: ns, range: NSRange(location: 0, length: ns.length), state: &state))
    var lineState = LexicalScanState()
    var lines: [(range: NSRange, kind: TokenKind)] = []
    var loc = 0
    while loc < ns.length {
        let line = ns.lineRange(for: NSRange(location: loc, length: 0))
        lines += def.tokens(in: ns, range: line, state: &lineState)
        loc = NSMaxRange(line)
    }
    #expect(perUnit(lines) == whole, "line-by-line differs from one pass", sourceLocation: sourceLocation)
    #expect(lineState == state, sourceLocation: sourceLocation)
    return Analysed(ns: ns, kinds: whole)
}

private let code: Set<TokenKind?> = [nil]
private let string: Set<TokenKind?> = [.string]
private let comment: Set<TokenKind?> = [.comment]
private let keyword: Set<TokenKind?> = [.keyword]
private let punctuation: Set<TokenKind?> = [.punctuation]
private let plain: Set<TokenKind?> = [.plain]

/// The scanner state at the end of `text`.
private func endState(_ language: String, _ text: String) throws -> LexicalScanState {
    let scanner = try #require(LanguageRegistry.definition(forIdentifier: language)?.lexicalScanner)
    var state = LexicalScanState()
    let ns = text as NSString
    scanner.advance(ns, from: 0, to: ns.length, state: &state)
    return state
}

// MARK: - Tests

@Suite("LexicalProfiles")
struct LexicalProfilesTests {
    @Test func cCommentsStringsCharsAndDigitSeparators() throws {
        let a = try analyse("c", """
            int a = 1; /* open "x"
            still comment 'y' // z
            */ int b = '"'; char c = L'\\''; int d = 1'000'000;
            char *s = "a \\" b /* no */"; // line "q"
            char *t = u8"x" L"y";
            #define M "line \\
            continued" int
            #include <stdio.h>
            """)
        #expect(a.kinds(of: "/* open \"x\"\nstill comment 'y' // z\n*/") == comment)
        #expect(a.kinds(of: "int", occurrence: 2) == keyword)
        #expect(a.kinds(of: "'\"'") == string)
        #expect(a.kinds(of: "L'\\''") == string)
        #expect(a.kinds(of: "1'000'000").contains(nil))      // separators stay code
        #expect(a.kinds(of: "'000") != string)
        #expect(a.kinds(of: "\"a \\\" b /* no */\"") == string)
        #expect(a.kinds(of: "// line \"q\"") == comment)
        #expect(a.kinds(of: "u8\"x\"") == string)
        #expect(a.kinds(of: "L\"y\"") == string)
        #expect(a.kinds(of: "\"line \\\ncontinued\"") == string)  // escaped newline continues
        #expect(a.kinds(of: "int", occurrence: 4) == keyword)
        #expect(a.kinds(of: "<stdio.h>") == string)
        #expect(a.kinds(of: "#include") == [.type])
    }

    @Test func cppRawStringsWithDelimitersAndPrefixes() throws {
        let a = try analyse("cpp", """
            auto r = R"d(first )" still
            // not a comment )x"
            )d" + x; auto u = u8R"x(a)x"; auto k = LR"(b)";
            auto n = 1'000; char c = u8'a';
            """)
        #expect(a.kinds(of: "R\"d(first )\" still\n// not a comment )x\"\n)d\"") == string)
        #expect(a.kinds(of: " + x; ").contains(nil))
        #expect(a.kinds(of: "auto", occurrence: 2) == keyword)
        #expect(a.kinds(of: "u8R\"x(a)x\"") == string)
        #expect(a.kinds(of: "LR\"(b)\"") == string)
        #expect(a.kinds(of: "1'000") != string)
        #expect(a.kinds(of: "u8'a'") == string)
    }

    @Test func javaTextBlocksAndCharacters() throws {
        let a = try analyse("java", """
            String t = \"\"\"
                text "q" \\\"\"\" still
                // no comment
                \"\"\"; int x = 1; char c = '"'; String s = "a";
            /* block "x"
             */ int y;
            """)
        #expect(a.kinds(of: "\"\"\"\n    text \"q\" \\\"\"\" still\n    // no comment\n    \"\"\"") == string)
        #expect(a.kinds(of: "int") == keyword)
        #expect(a.kinds(of: "'\"'") == string)
        #expect(a.kinds(of: "\"a\"") == string)
        #expect(a.kinds(of: "/* block \"x\"\n */") == comment)
        #expect(a.kinds(of: "int", occurrence: 2) == keyword)
    }

    @Test func csharpVerbatimRawAndInterpolatedStrings() throws {
        let a = try analyse("csharp", """
            var v = @"C:\\dir\\""q"" more
            second line"; int i;
            var s = $"a {b + "c"} {{lit}} d"; int j;
            var r = \"\"\"
              raw "" and \"\"\"\" content
              \"\"\"; int k;
            var ri = $\"\"\"
              x {y} z
              \"\"\"; int l;
            var rr = $$\"\"\"
              {{w}} {z}
              \"\"\"; int m;
            var vi = $@"{p}\\
            q {r}"; int n;
            var iv = @$"{u}"; char c = '"';
            """)
        #expect(a.kinds(of: "@\"C:\\dir\\\"\"q\"\" more\nsecond line\"") == string)
        #expect(a.kinds(of: "int") == keyword)
        #expect(a.kinds(of: "$\"a ") == string)
        #expect(a.kinds(of: "{", occurrence: 1) == punctuation)
        #expect(a.kinds(of: "b + ") == code)
        #expect(a.kinds(of: "\"c\"") == string)
        #expect(a.kinds(of: "} {{lit}} d\"") == [.punctuation, .string])
        #expect(a.kinds(of: " {{lit}} d\"") == string)
        #expect(a.kinds(of: "int", occurrence: 2) == keyword)
        #expect(a.kinds(of: "\"\"\"\n  raw \"\" and \"\"\"\" content\n  \"\"\"") == string)
        #expect(a.kinds(of: "int", occurrence: 3) == keyword)
        #expect(a.kinds(of: "$\"\"\"\n  x ") == string)
        #expect(a.kinds(of: "y") == code)
        #expect(a.kinds(of: "int", occurrence: 4) == keyword)
        // `$$"""`: `{{` opens, the first `}` closes, the second is content.
        #expect(a.kinds(of: "{{w") == [.punctuation, nil])
        #expect(a.kinds(of: "}} {z}") == [.punctuation, .string])
        #expect(a.kinds(of: "} {z}\n  \"\"\"") == string)     // second `}`, `{z}`, closer
        #expect(a.kinds(of: "int", occurrence: 5) == keyword)
        #expect(a.kinds(of: "$@\"") == string)
        #expect(a.kinds(of: "p") == code)
        #expect(a.kinds(of: "}\\\nq ") == [.punctuation, .string])
        #expect(a.kinds(of: "r}") == [nil, .punctuation])
        #expect(a.kinds(of: "int", occurrence: 6) == keyword)
        #expect(a.kinds(of: "@$\"") == string)
        #expect(a.kinds(of: "u}") == [nil, .punctuation])
        #expect(a.kinds(of: "'\"'") == string)
    }

    @Test func goRawStringsAndRunes() throws {
        let a = try analyse("go", """
            s := `raw "q" // no
            /* no */ \\`
            x := 1 // c
            r := '"'; t := "a\\"b"
            /* multi
            line */ var y int
            """)
        #expect(a.kinds(of: "`raw \"q\" // no\n/* no */ \\`") == string)
        #expect(a.kinds(of: "1") == [.number])
        #expect(a.kinds(of: "// c") == comment)
        #expect(a.kinds(of: "'\"'") == string)
        #expect(a.kinds(of: "\"a\\\"b\"") == string)
        #expect(a.kinds(of: "/* multi\nline */") == comment)
        #expect(a.kinds(of: "var") == keyword)
    }

    @Test func cssCommentsAndStrings() throws {
        let a = try analyse("css", """
            a { content: "x /* no */"; quotes: 'it\\'s'; }
            /* multi "q"
               line */ b { color: red; }
            c { content: "line \\
            continued"; }
            """)
        #expect(a.kinds(of: "\"x /* no */\"") == string)
        #expect(a.kinds(of: "'it\\'s'") == string)
        #expect(a.kinds(of: "/* multi \"q\"\n   line */") == comment)
        #expect(a.kinds(of: "color") == [.property])
        #expect(a.kinds(of: "\"line \\\ncontinued\"") == string)
    }

    @Test func sqlMultiLineStringsDoubledQuotesAndComments() throws {
        let a = try analyse("sql", """
            SELECT 'it''s
            multi -- no
            /* no */ end' AS "a""b", `c` -- comment 'x
            FROM t /* block
            'not string' */ WHERE x = 1;
            SELECT 'a\\' AS y, a / b / 2;
            """)
        #expect(a.kinds(of: "'it''s\nmulti -- no\n/* no */ end'") == string)
        #expect(a.kinds(of: "AS") == keyword)
        #expect(a.kinds(of: "\"a\"\"b\"") == string)
        #expect(a.kinds(of: "`c`") == string)
        #expect(a.kinds(of: "-- comment 'x") == comment)
        #expect(a.kinds(of: "FROM") == keyword)
        #expect(a.kinds(of: "/* block\n'not string' */") == comment)
        #expect(a.kinds(of: "WHERE") == keyword)
        #expect(a.kinds(of: "'a\\'") == string)            // no backslash escape
        #expect(a.kinds(of: "AS", occurrence: 2) == keyword)
        #expect(a.kinds(of: " / b / ") == code)
    }

    @Test func swiftNestedCommentsInterpolationAndExtendedDelimiters() throws {
        let a = try analyse("swift", """
            /* outer /* inner */ still */ let a = 1
            let s = \"\"\"
              Hi \\(name + "x") and \\("y")
              \"\"\" ; let b = 2
            let r = #"a \\(no) \\#(yes) "# ; let c = 3
            let m = #\"\"\"
              \"\"\" not closed
              \\#(z) \"\"\"#; let d = 4
            let e = "q\\"r" + "t\\(qq)v"
            """)
        #expect(a.kinds(of: "/* outer /* inner */ still */") == comment)
        #expect(a.kinds(of: "let") == keyword)
        #expect(a.kinds(of: "\"\"\"\n  Hi ") == string)
        #expect(a.kinds(of: "\\(") == punctuation)
        #expect(a.kinds(of: "name + ") == code)
        #expect(a.kinds(of: "\"x\"") == string)
        #expect(a.kinds(of: ") and ") == [.punctuation, .string])
        #expect(a.kinds(of: "\"y\"") == string)
        #expect(a.kinds(of: "let", occurrence: 3) == keyword)
        #expect(a.kinds(of: "#\"a \\(no) ") == string)
        #expect(a.kinds(of: "\\#(") == punctuation)
        #expect(a.kinds(of: "yes") == code)
        #expect(a.kinds(of: " \"#") == string)
        #expect(a.kinds(of: "let", occurrence: 5) == keyword)
        #expect(a.kinds(of: "#\"\"\"\n  \"\"\" not closed\n  ") == string)
        #expect(a.kinds(of: "z") == code)
        #expect(a.kinds(of: " \"\"\"#") == string)
        #expect(a.kinds(of: "let", occurrence: 7) == keyword)
        #expect(a.kinds(of: "\"q\\\"r\"") == string)
        #expect(a.kinds(of: "qq") == code)
    }

    @Test func tomlMultiLineAndLiteralStringsAndQuotedKeys() throws {
        let a = try analyse("toml", """
            a = \"\"\"
            x = "q" # no
            line \\
            \"\"\"
            b = '''
            c\\n # no
            '''
            "key" = 'v' # comment "x"
            e = "esc \\" # no"
            f = 'raw \\' # comment
            [owner."quoted key"]
            """)
        #expect(a.kinds(of: "\"\"\"\nx = \"q\" # no\nline \\\n\"\"\"") == string)
        #expect(a.kinds(of: "b") == [.property])
        #expect(a.kinds(of: "'''\nc\\n # no\n'''") == string)
        #expect(a.kinds(of: "\"key\"") == [.property])
        #expect(a.kinds(of: "'v'") == string)
        #expect(a.kinds(of: "# comment \"x\"") == comment)
        #expect(a.kinds(of: "\"esc \\\" # no\"") == string)
        #expect(a.kinds(of: "'raw \\'") == string)
        #expect(a.kinds(of: "# comment", occurrence: 2) == comment)
        #expect(a.kinds(of: "[owner.") == [.type])
        #expect(a.kinds(of: "\"quoted key\"") == string)
    }

    @Test func htmlCommentsSpanLinesAndAttributeStringsStayRules() throws {
        let a = try analyse("html", """
            <p class="a">x "plain"</p> <!-- one
            <div class="fake"> "q"
            --> <b title='t'>y</b>
            """)
        #expect(a.kinds(of: "\"a\"") == string)
        #expect(a.kinds(of: "<!-- one\n<div class=\"fake\"> \"q\"\n-->") == comment)
        #expect(a.kinds(of: "<b") == keyword)
        #expect(a.kinds(of: "'t'") == string)
        #expect(a.kinds(of: "title") == [.property])
    }

    @Test func xmlCDATAAndComments() throws {
        let a = try analyse("xml", """
            <a x="1"><![CDATA[
            <b>"q" <!-- no --> ]] >
            ]]></a> <!-- c "z"
            --> <c/>
            """)
        #expect(a.kinds(of: "\"1\"") == string)
        #expect(a.kinds(of: "<![CDATA[\n<b>\"q\" <!-- no --> ]] >\n]]>") == string)
        #expect(a.kinds(of: "</a") == keyword)
        #expect(a.kinds(of: "<!-- c \"z\"\n-->") == comment)
        #expect(a.kinds(of: "<c") == keyword)
    }

    @Test(arguments: ["javascript", "typescript"])
    func regexLiteralsVersusDivision(_ language: String) throws {
        let a = try analyse(language, """
            x = /re/g;
            y = a / b / c;
            if (ok) /re/.test(s);
            return /re\\/x[/"]/;
            z = f(a) / 2 / 3;
            w = [/'/, /"/];
            v = `t ${ /}/.test(s) } u`;
            q = a /* c */ / b;
            p = typeof /x/; n = len /x/ 2;
            m = /a
            b/;
            """)
        #expect(a.kinds(of: "/re/g") == string)
        #expect(a.kinds(of: " / b / ") == code)
        #expect(a.kinds(of: ") /re/") == code)                  // `)` then `/`: division
        #expect(a.kinds(of: "/re\\/x[/\"]/") == string)        // escaped `/`, `/` and `"` in a class
        #expect(a.kinds(of: "return") == keyword)
        #expect(a.kinds(of: ") / 2 / 3") == [nil, .number])
        #expect(a.kinds(of: "/'/") == string)
        #expect(a.kinds(of: "/\"/") == string)
        #expect(a.kinds(of: "/}/") == string)                  // `}` in a regex does not close `${`
        #expect(a.kinds(of: ".test(s) ") == code)
        #expect(a.kinds(of: "} u`") == [.punctuation, .string])
        #expect(a.kinds(of: "/* c */") == comment)
        #expect(a.kinds(of: " / b;") == code)
        #expect(a.kinds(of: "/x/;") == [.string, nil])         // after `typeof`
        #expect(a.kinds(of: " /x/ 2") == [nil, .number])        // after an identifier
        #expect(a.kinds(of: "/a\nb/") == code)                   // never across lines
    }

    // MARK: - T17.3b: Bash

    @Test func bashHeredocs() throws {
        let a = try analyse("bash", """
            cat <<EOF
            body $x "q" # no
            EOF
            echo after # c
            \tcat <<-END
            \t\tline one
            \tEND
            cat <<A
            \tA
            A
            cat <<'Q' | grep x "s" # tail
            $HOME 'x'
            Q
            cat <<\\E
            raw
            E
            cat << "D"
            EOF x
            D x
            D\u{20}
            D
            cat <<< "word"
            echo next
            """)
        #expect(a.kinds(of: "body $x \"q\" # no") == string)
        #expect(a.kinds(of: "EOF\necho") == [nil, .builtin])      // terminator line is code
        #expect(a.kinds(of: "# c") == comment)
        #expect(a.kinds(of: "\t\tline one") == string)
        #expect(a.kinds(of: "\tEND\n") == code)                   // `<<-` strips the tabs
        #expect(a.kinds(of: "\tA\n") == string)                   // `<<` does not
        #expect(a.kinds(of: "A\ncat <<'Q'") == [nil, .builtin])
        #expect(a.kinds(of: "grep") == [.builtin])                 // the opener line stays code
        #expect(a.kinds(of: "\"s\"") == string)
        #expect(a.kinds(of: "# tail") == comment)
        #expect(a.kinds(of: "$HOME 'x'") == string)
        #expect(a.kinds(of: "raw") == string)
        #expect(a.kinds(of: "EOF x\nD x\nD \n") == string)          // trailing text: no terminator
        #expect(a.kinds(of: "D\ncat <<<") == [nil, .builtin])
        #expect(a.kinds(of: "\"word\"") == string)                 // here-string: no heredoc
        #expect(a.kinds(of: "echo next") == [.builtin, nil])
        #expect(try endState("bash", "cat <<EOF\nno end\n$x").frames
                == [.heredoc(terminator: "EOF", stripTabs: false, inBody: true)])
        let open = try analyse("bash", "cat <<EOF\nno end\n$x")
        #expect(open.kinds(of: "no end\n$x") == string)              // to the document end
    }

    @Test func bashCommentsQuotesAndInterpolations() throws {
        let a = try analyse("bash", """
            echo $# ${#x} a#b # real
            v="$(echo ")")"; echo z
            w='it'"'"'s' x
            m="multi
            line ${y} # no"
            d=$'tab\\t\\'q' e
            """)
        #expect(!a.kinds(of: "$# ${#x} a#b").contains(.comment))
        #expect(a.kinds(of: "# real") == comment)
        #expect(a.kinds(of: "\"$(") == [.string, .punctuation])
        #expect(a.kinds(of: "\")\"") == string)                     // the quoted `)` does not close
        #expect(a.kinds(of: ")\"; echo") == [.punctuation, .string, nil, .builtin])
        #expect(a.kinds(of: "'it'\"'\"'s'") == string)
        #expect(a.kinds(of: "s' x") == [.string, nil])
        #expect(a.kinds(of: "\"multi\nline ") == string)
        #expect(a.kinds(of: " # no\"") == string)
        #expect(a.kinds(of: "$'tab\\t\\'q'") == string)
        #expect(a.kinds(of: "' e") == [.string, nil])
    }

    // MARK: - T17.3b: YAML

    @Test func yamlBlockScalarsQuotesAndComments() throws {
        let a = try analyse("yaml", """
            a: |
              line # not comment
              key: v

              more
            b: >-
              folded
            c: |2+
                two
            d: plain # comment
            - |
              item body
            - key: |
                nested body
              other: x
            e: don't say "hi" here
            "quoted key": 'v'
            f: [ 'a', "b" ]
            g: a#b # c
            h: | # after indicator
              body h
            i: 1
            """)
        #expect(a.kinds(of: "line # not comment\n  key: v\n\n  more") == string)
        #expect(a.kinds(of: "b: >-") == [.property, nil])         // the dedent ends the block
        #expect(a.kinds(of: "folded") == string)
        #expect(a.kinds(of: "two") == string)
        #expect(a.kinds(of: "d: plain") == [.property, nil])
        #expect(a.kinds(of: "# comment") == comment)
        #expect(a.kinds(of: "item body") == string)
        #expect(a.kinds(of: "- key") == [nil, .property])
        #expect(a.kinds(of: "nested body") == string)
        #expect(a.kinds(of: "other") == [.property])
        #expect(a.kinds(of: "don't say \"hi\" here") == code)
        #expect(a.kinds(of: "\"quoted key\"") == [.property])
        #expect(a.kinds(of: "'v'") == string)
        #expect(a.kinds(of: "'a'") == string)
        #expect(a.kinds(of: "\"b\"") == string)
        #expect(a.kinds(of: "a#b") == code)
        #expect(a.kinds(of: "# c") == comment)
        #expect(a.kinds(of: "# after indicator") == comment)
        #expect(a.kinds(of: "body h") == string)
        #expect(a.kinds(of: "i: 1") == [.property, nil, .number])
        // Something else after the indicator: no block scalar.
        let b = try analyse("yaml", "a: | x\n  b: c\n")
        #expect(b.kinds(of: "b") == [.property])
        #expect(try endState("yaml", "a: |\n  body\n\n").frames == [.indentedBlock(parentIndent: 0, inBody: true)])
    }

    // MARK: - T17.3b: Markdown

    @Test func markdownFencesAndComments() throws {
        let a = try analyse("markdown", """
            ```js
            code <!-- not a comment
            ```
            text `inline`
            ~~~
            ```
            still
            ~~~~
            after **b**
               ```
            indented 3
               ```
                ```
            not a fence
            ``` a`b
            not a fence either
            ````
            inner
            ```
            ````
            <!-- c
            # no heading
            --> done
            ```
            unclosed
            """)
        #expect(a.kinds(of: "```js\ncode <!-- not a comment\n```\n") == plain)
        #expect(a.kinds(of: "`inline`") == string)
        #expect(a.kinds(of: "~~~\n```\nstill\n~~~~\n") == plain)   // longer closer; ``` does not close
        #expect(a.kinds(of: "**b**") == keyword)
        #expect(a.kinds(of: "   ```\nindented 3\n   ```\n") == plain)
        #expect(a.kinds(of: "not a fence\n") == code)                // four spaces: no fence
        #expect(a.kinds(of: "not a fence either") == code)            // backtick in the info string
        #expect(a.kinds(of: "````\ninner\n```\n````\n") == plain)   // shorter run inside
        #expect(a.kinds(of: "<!-- c\n# no heading\n-->") == comment)
        #expect(a.kinds(of: " done") == code)
        #expect(a.kinds(of: "```\nunclosed") == plain)
        #expect(try endState("markdown", "```\nunclosed").frames == [.fence(marker: 96, length: 3, inBody: true)])
    }
}
