import Testing
@testable import KaruCore

@Suite("JSONFormatter.prettyPrint")
struct JSONFormatterPrettyPrintTests {

    @Test("nested object and array, default 2-space indent")
    func nestedObjectAndArray() throws {
        let input = """
        {"a":1,"b":[1,2,{"c":true,"d":null}]}
        """
        let expected = """
        {
          "a": 1,
          "b": [
            1,
            2,
            {
              "c": true,
              "d": null
            }
          ]
        }
        """
        let result = try JSONFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("4-space indent width")
    func fourSpaceIndent() throws {
        let input = "{\"a\":{\"b\":1}}"
        let expected = """
        {
            "a": {
                "b": 1
            }
        }
        """
        let result = try JSONFormatter.prettyPrint(input, indentWidth: 4)
        #expect(result == expected)
    }

    @Test("escaped and unicode/emoji string content is preserved verbatim")
    func escapedAndUnicodeStrings() throws {
        // Contains: a \n escape, an escaped quote, an escaped backslash, a
        // \uXXXX escape (left undecoded), a literal emoji, and literal CJK
        // text -- all of which must round-trip byte-for-byte.
        let input = #"{"s":"line1\nline2 \"quoted\" \\ \u00e9 😀 中文"}"#
        let expected = "{\n  \"s\": \"line1\\nline2 \\\"quoted\\\" \\\\ \\u00e9 😀 中文\"\n}"
        let result = try JSONFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("large numbers are preserved exactly, without losing precision")
    func largeNumbersPreserved() throws {
        let input = "{\"n\":12345678901234567890.000000001,\"e\":1.5e+308,\"neg\":-42}"
        let result = try JSONFormatter.prettyPrint(input)
        #expect(result.contains("12345678901234567890.000000001"))
        #expect(result.contains("1.5e+308"))
        #expect(result.contains("-42"))
    }

    @Test("key order is preserved as written, not sorted")
    func keyOrderPreserved() throws {
        let input = "{\"z\":1,\"a\":2,\"m\":3}"
        let expected = """
        {
          "z": 1,
          "a": 2,
          "m": 3
        }
        """
        let result = try JSONFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("empty object and empty array stay on one line")
    func emptyContainers() throws {
        let input = "{\"o\":{},\"a\":[]}"
        let expected = """
        {
          "o": {},
          "a": []
        }
        """
        let result = try JSONFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("top-level scalar values are supported")
    func topLevelScalars() throws {
        #expect(try JSONFormatter.prettyPrint("42") == "42")
        #expect(try JSONFormatter.prettyPrint("\"hello\"") == "\"hello\"")
        #expect(try JSONFormatter.prettyPrint("true") == "true")
        #expect(try JSONFormatter.prettyPrint("null") == "null")
    }

    @Test("missing comma between object members throws with correct line")
    func missingCommaThrows() {
        let input = """
        {
          "a": 1
          "b": 2
        }
        """
        #expect(throws: JSONFormatError.self) {
            try JSONFormatter.prettyPrint(input)
        }
        do {
            _ = try JSONFormatter.prettyPrint(input)
            Issue.record("expected an error to be thrown")
        } catch let error as JSONFormatError {
            #expect(error.line == 3)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("trailing comma before closing brace throws with correct line")
    func trailingCommaThrows() {
        let input = """
        {
          "a": 1,
        }
        """
        do {
            _ = try JSONFormatter.prettyPrint(input)
            Issue.record("expected an error to be thrown")
        } catch let error as JSONFormatError {
            #expect(error.line == 3)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("unclosed object throws with the opening brace's line")
    func unclosedObjectThrows() {
        let input = """
        {
          "a": 1
        """
        do {
            _ = try JSONFormatter.prettyPrint(input)
            Issue.record("expected an error to be thrown")
        } catch let error as JSONFormatError {
            #expect(error.line == 1)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("unclosed array throws with the opening bracket's line")
    func unclosedArrayThrows() {
        let input = """
        [
          1,
          2
        """
        do {
            _ = try JSONFormatter.prettyPrint(input)
            Issue.record("expected an error to be thrown")
        } catch let error as JSONFormatError {
            #expect(error.line == 1)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("mismatched closing bracket throws")
    func mismatchedBracketThrows() {
        #expect(throws: JSONFormatError.self) {
            try JSONFormatter.prettyPrint("{\"a\": 1]")
        }
    }
}

@Suite("JSONFormatter.formatJSONL")
struct JSONFormatterJSONLTests {

    @Test("multiple lines, including blank lines, are normalized to compact form")
    func multipleLinesWithBlankLines() throws {
        let input = """
        {"a": 1,   "b": 2}

        [1,  2,   3]

        {"nested": {"x": [1,2], "y": "z"}}
        """
        let expected = """
        {"a":1,"b":2}
        [1,2,3]
        {"nested":{"x":[1,2],"y":"z"}}
        """
        let result = try JSONFormatter.formatJSONL(input)
        #expect(result == expected)
    }

    @Test("line order is preserved")
    func lineOrderPreserved() throws {
        let input = """
        {"id": 1}
        {"id": 2}
        {"id": 3}
        """
        let result = try JSONFormatter.formatJSONL(input)
        #expect(result == "{\"id\":1}\n{\"id\":2}\n{\"id\":3}")
    }

    @Test("top-level scalars are valid JSONL rows")
    func topLevelScalarRows() throws {
        let input = """
        1
        "two"
        true
        null
        """
        let result = try JSONFormatter.formatJSONL(input)
        #expect(result == "1\n\"two\"\ntrue\nnull")
    }

    @Test("blank line at start, middle and end are all skipped")
    func blankLinesEverywhere() throws {
        let input = "\n{\"a\":1}\n\n{\"b\":2}\n\n"
        let result = try JSONFormatter.formatJSONL(input)
        #expect(result == "{\"a\":1}\n{\"b\":2}")
    }

    @Test("error on an invalid line reports the original document line number")
    func errorReportsOriginalLineNumber() {
        let input = """
        {"a": 1}
        {"b": 2,}
        {"c": 3}
        """
        do {
            _ = try JSONFormatter.formatJSONL(input)
            Issue.record("expected an error to be thrown")
        } catch let error as JSONFormatError {
            #expect(error.line == 2)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("unterminated string on a later line reports that line number")
    func unterminatedStringReportsLineNumber() {
        let input = """
        {"a": 1}
        {"b": 2}
        {"c": "unterminated}
        """
        do {
            _ = try JSONFormatter.formatJSONL(input)
            Issue.record("expected an error to be thrown")
        } catch let error as JSONFormatError {
            #expect(error.line == 3)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
