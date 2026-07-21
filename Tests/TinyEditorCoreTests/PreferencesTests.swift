import Foundation
import Testing
@testable import TinyEditorCore

private func isolatedDefaults() -> UserDefaults {
    let name = "PreferencesTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

// MARK: - EditorFontSettings

@Test func fontSizeDefaultsToThirteenWhenUnset() {
    let settings = EditorFontSettings(defaults: isolatedDefaults())
    #expect(settings.fontSize == EditorFontSettings.defaultFontSize)
    #expect(settings.fontSize == 13)
}

@Test func fontSizeReadsStoredOverride() {
    let defaults = isolatedDefaults()
    defaults.set(16.0, forKey: EditorFontSettings.fontSizeKey)
    let settings = EditorFontSettings(defaults: defaults)
    #expect(settings.fontSize == 16)
}

@Test func fontSizeIgnoresNonPositiveOverride() {
    let defaults = isolatedDefaults()
    defaults.set(0.0, forKey: EditorFontSettings.fontSizeKey)
    let settings = EditorFontSettings(defaults: defaults)
    #expect(settings.fontSize == EditorFontSettings.defaultFontSize)
}

@Test func setFontSizePersistsClampedValue() {
    let defaults = isolatedDefaults()
    let settings = EditorFontSettings(defaults: defaults)
    settings.setFontSize(20)
    #expect(EditorFontSettings(defaults: defaults).fontSize == 20)
    // Above the max is clamped.
    settings.setFontSize(999)
    #expect(EditorFontSettings(defaults: defaults).fontSize == EditorFontSettings.maxFontSize)
}

// MARK: - FormatDispatch

@Test func dispatchFormatsJSON() {
    let result = FormatDispatch.format(text: "{\"a\":1}", languageIdentifier: "json", indentWidth: 2)
    #expect(result == .success("{\n  \"a\": 1\n}"))
}

@Test func dispatchHonorsIndentWidthForJSON() {
    let result = FormatDispatch.format(text: "{\"a\":1}", languageIdentifier: "json", indentWidth: 4)
    #expect(result == .success("{\n    \"a\": 1\n}"))
}

@Test func dispatchFormatsJSONL() {
    let input = "{\"a\": 1}\n\n{\"b\": 2}"
    let result = FormatDispatch.format(text: input, languageIdentifier: "jsonl", indentWidth: 2)
    #expect(result == .success("{\"a\":1}\n{\"b\":2}"))
}

@Test func dispatchFormatsXML() {
    let result = FormatDispatch.format(text: "<a><b>x</b></a>", languageIdentifier: "xml", indentWidth: 2)
    switch result {
    case .success(let text):
        #expect(text.contains("<b>x</b>"))
        #expect(text.contains("\n"))
    case .failure(let error):
        Issue.record("expected success, got \(error)")
    }
}

@Test func dispatchTreatsPlistAsXML() {
    let result = FormatDispatch.format(text: "<a><b>x</b></a>", languageIdentifier: "plist", indentWidth: 2)
    if case .failure(let error) = result {
        Issue.record("expected success, got \(error)")
    }
}

@Test func dispatchIsCaseInsensitiveOnLanguage() {
    let result = FormatDispatch.format(text: "{\"a\":1}", languageIdentifier: "JSON", indentWidth: 2)
    #expect(result == .success("{\n  \"a\": 1\n}"))
}

@Test func dispatchRejectsUnsupportedLanguage() {
    let result = FormatDispatch.format(text: "print(1)", languageIdentifier: "python", indentWidth: 4)
    #expect(result == .failure(.unsupportedLanguage("python")))
}

@Test func dispatchPassesThroughJSONErrorLine() {
    // Missing closing brace: JSONFormatter reports line 1.
    let result = FormatDispatch.format(text: "{\n  \"a\": 1", languageIdentifier: "json", indentWidth: 2)
    guard case .failure(.syntax(let line, _)) = result else {
        Issue.record("expected syntax failure, got \(result)")
        return
    }
    #expect(line == 1)
}

@Test func dispatchPassesThroughJSONLErrorLine() {
    // Second line is malformed; JSONL reports the original document line number.
    let result = FormatDispatch.format(text: "{\"a\":1}\n{oops", languageIdentifier: "jsonl", indentWidth: 2)
    guard case .failure(.syntax(let line, _)) = result else {
        Issue.record("expected syntax failure, got \(result)")
        return
    }
    #expect(line == 2)
}

@Test func dispatchSupportsReportsFormattableLanguages() {
    #expect(FormatDispatch.supports(languageIdentifier: "json"))
    #expect(FormatDispatch.supports(languageIdentifier: "jsonl"))
    #expect(FormatDispatch.supports(languageIdentifier: "xml"))
    #expect(FormatDispatch.supports(languageIdentifier: "plist"))
    #expect(FormatDispatch.supports(languageIdentifier: "PLIST"))
    #expect(!FormatDispatch.supports(languageIdentifier: "python"))
    #expect(!FormatDispatch.supports(languageIdentifier: ""))
}
