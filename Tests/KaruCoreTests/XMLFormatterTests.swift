import Testing
@testable import KaruCore

@Suite("XMLFormatter.prettyPrint")
struct XMLFormatterPrettyPrintTests {

    @Test("multi-level nested elements are re-indented, default 2-space indent")
    func nestedElements() throws {
        let input = "<root><a><b>1</b><c>2</c></a></root>"
        let expected = """
        <root>
          <a>
            <b>1</b>
            <c>2</c>
          </a>
        </root>
        """
        let result = try XMLFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("4-space indent width")
    func fourSpaceIndent() throws {
        let input = "<root><a><b>1</b></a></root>"
        let expected = """
        <root>
            <a>
                <b>1</b>
            </a>
        </root>
        """
        let result = try XMLFormatter.prettyPrint(input, indentWidth: 4)
        #expect(result == expected)
    }

    @Test("attributes with single and double quotes, multiple attributes, are preserved verbatim")
    func attributesVerbatim() throws {
        let input = "<root><item id=\"1\" name='fish &amp; chips' class=\"a b\"/></root>"
        let expected = """
        <root>
          <item id="1" name='fish &amp; chips' class="a b"/>
        </root>
        """
        let result = try XMLFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("self-closing tags are preserved as self-closing")
    func selfClosingTag() throws {
        let input = "<root><flag/><other></other></root>"
        let expected = """
        <root>
          <flag/>
          <other></other>
        </root>
        """
        let result = try XMLFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("text-only elements are collapsed onto a single line")
    func textOnlyElementSingleLine() throws {
        let input = "<root>\n  <key>\n    CFBundleName\n  </key>\n</root>"
        let expected = """
        <root>
          <key>CFBundleName</key>
        </root>
        """
        let result = try XMLFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("single-line comments are re-indented with content kept verbatim")
    func singleLineComment() throws {
        let input = "<root><!-- a comment --><a>1</a></root>"
        let expected = """
        <root>
          <!-- a comment -->
          <a>1</a>
        </root>
        """
        let result = try XMLFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("multi-line comments keep their internal content untouched, only the block is re-indented")
    func multiLineComment() throws {
        let input = "<root><!--\n  line one\n    line two\n--><a>1</a></root>"
        let expected = """
        <root>
          <!--
          line one
            line two
        -->
          <a>1</a>
        </root>
        """
        let result = try XMLFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("CDATA sections are preserved verbatim")
    func cdataVerbatim() throws {
        let input = "<root><script><![CDATA[if (a < b && c > d) { return; }]]></script></root>"
        let expected = """
        <root>
          <script><![CDATA[if (a < b && c > d) { return; }]]></script>
        </root>
        """
        let result = try XMLFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("entities are not decoded and pass through untouched")
    func entitiesNotDecoded() throws {
        let input = "<root><a>Fish &amp; Chips &lt;tag&gt; &#39;quote&#39;</a></root>"
        let expected = """
        <root>
          <a>Fish &amp; Chips &lt;tag&gt; &#39;quote&#39;</a>
        </root>
        """
        let result = try XMLFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("a full plist document with declaration and DOCTYPE is reformatted, boolean/string/key elements stay single-line")
    func fullPlistDocument() throws {
        let input = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleName</key><string>Karu</string><key>LSRequiresIPhoneOS</key><true/><key>UIRequiredDeviceCapabilities</key><array><string>armv7</string></array></dict></plist>
        """
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
          <dict>
            <key>CFBundleName</key>
            <string>Karu</string>
            <key>LSRequiresIPhoneOS</key>
            <true/>
            <key>UIRequiredDeviceCapabilities</key>
            <array>
              <string>armv7</string>
            </array>
          </dict>
        </plist>
        """
        let result = try XMLFormatter.prettyPrint(input)
        #expect(result == expected)
    }

    @Test("mismatched closing tag throws with the closing tag's line number")
    func mismatchedClosingTagThrows() {
        let input = """
        <a>
          <b>
          </c>
        </a>
        """
        do {
            _ = try XMLFormatter.prettyPrint(input)
            Issue.record("expected an error to be thrown")
        } catch let error as XMLFormatError {
            #expect(error.line == 3)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("unclosed element throws with the opening tag's line number")
    func unclosedElementThrows() {
        let input = """
        <a>
          <b>text</b>
        """
        do {
            _ = try XMLFormatter.prettyPrint(input)
            Issue.record("expected an error to be thrown")
        } catch let error as XMLFormatError {
            #expect(error.line == 1)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("a tag missing its closing '>' throws with the opening tag's line number")
    func missingClosingBracketThrows() {
        let input = "<a>\n  <b"
        do {
            _ = try XMLFormatter.prettyPrint(input)
            Issue.record("expected an error to be thrown")
        } catch let error as XMLFormatError {
            #expect(error.line == 2)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("missing root element throws")
    func missingRootElementThrows() {
        #expect(throws: XMLFormatError.self) {
            try XMLFormatter.prettyPrint("<?xml version=\"1.0\"?>")
        }
    }
}
