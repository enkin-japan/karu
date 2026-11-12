import Foundation
import Testing
@testable import KaruCore

// Run engine T16.3a: language-resolution policy, run settings, flag splitting.
// Pure logic — no processes.

@Suite("Run language resolution")
struct RunLanguageResolverTests {
    private let pythonText = "import os\ndef main():\n    print(os.getcwd())\n"

    @Test func manualRunnableLanguageIsUsedAsIs() {
        // Content looks like Python, but the manual choice wins and is never rewritten.
        #expect(RunLanguageResolver.resolve(identifier: "go", isManual: true, text: pythonText)
                == .run(.go, correctedIdentifier: nil))
    }

    @Test func manualNonRunnableLanguageFails() {
        #expect(RunLanguageResolver.resolve(identifier: "json", isManual: true, text: "{}")
                == .failure(.notExecutable("json")))
        #expect(RunLanguageResolver.resolve(identifier: "sql", isManual: true, text: "SELECT 1")
                == .failure(.notExecutable("sql")))
        #expect(RunLanguageResolver.resolve(identifier: "html", isManual: true, text: "<html>")
                == .failure(.notExecutable("html")))
    }

    @Test func manualPlainTextIsNotExecutable() {
        #expect(RunLanguageResolver.resolve(identifier: "", isManual: true, text: pythonText)
                == .failure(.plainTextNotExecutable))
    }

    @Test func autoWithLanguageUsesIt() {
        #expect(RunLanguageResolver.resolve(identifier: "python", isManual: false, text: "")
                == .run(.python, correctedIdentifier: nil))
        #expect(RunLanguageResolver.resolve(identifier: "Swift", isManual: false, text: "")
                == .run(.swift, correctedIdentifier: nil))
    }

    @Test func autoWithNonRunnableLanguageFails() {
        #expect(RunLanguageResolver.resolve(identifier: "markdown", isManual: false, text: "# a\n# b")
                == .failure(.notExecutable("markdown")))
    }

    @Test func autoPlainTextSniffsAndCorrects() {
        #expect(RunLanguageResolver.resolve(identifier: "", isManual: false, text: pythonText)
                == .run(.python, correctedIdentifier: "python"))
    }

    @Test func autoPlainTextSniffsShortTextWithoutThreshold() {
        // Well under the editor's 120-char / 3-line auto-detect threshold.
        #expect(RunLanguageResolver.resolve(identifier: "", isManual: false, text: "#!/bin/sh\necho hi")
                == .run(.bash, correctedIdentifier: "bash"))
    }

    @Test func autoPlainTextSniffedButNotRunnable() {
        #expect(RunLanguageResolver.resolve(identifier: "", isManual: false, text: "{\"a\": 1}")
                == .failure(.notExecutable("json")))
        #expect(RunLanguageResolver.resolve(identifier: "", isManual: false, text: "# Title\n## Sub\n")
                == .failure(.notExecutable("markdown")))
    }

    @Test func autoPlainTextUnrecognized() {
        #expect(RunLanguageResolver.resolve(identifier: "", isManual: false, text: "just some prose\nmore")
                == .failure(.unrecognized))
        #expect(RunLanguageResolver.resolve(identifier: "", isManual: false, text: "")
                == .failure(.unrecognized))
    }

    @Test func noRunTimeRefinement() {
        // C stays C even when the code is C++; JS stays JS even when typed.
        let cpp = "#include <iostream>\nint main() { std::cout << 1; }"
        #expect(RunLanguageResolver.resolve(identifier: "c", isManual: false, text: cpp)
                == .run(.c, correctedIdentifier: nil))
        let ts = "const a: number = 1\nlet b: string = 'x'"
        #expect(RunLanguageResolver.resolve(identifier: "javascript", isManual: false, text: ts)
                == .run(.javascript, correctedIdentifier: nil))
    }

    @Test func runnableSetMatchesSpec() {
        let runnable = Set(RunnableLanguage.allCases.map(\.identifier))
        #expect(runnable == ["python", "javascript", "typescript", "bash", "c", "cpp",
                             "swift", "go", "rust", "java", "csharp"])
        for id in SupportedLanguage.all.map(\.identifier) where !runnable.contains(id) {
            #expect(RunnableLanguage(identifier: id) == nil)
        }
    }
}

@Suite("Run settings")
struct RunSettingsTests {
    private func isolatedDefaults() -> UserDefaults {
        let name = "RunSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsAreAutoWithoutPathOrFlags() {
        let settings = RunSettings(defaults: isolatedDefaults(), center: NotificationCenter())
        for language in RunnableLanguage.allCases {
            #expect(settings.preference(for: language) == RunToolPreference())
        }
    }

    @Test func keysFollowSpec() {
        #expect(RunSettings.sourceKey(for: .python) == "run.python.source")
        #expect(RunSettings.pathKey(for: .csharp) == "run.csharp.path")
        #expect(RunSettings.flagsKey(for: .c) == "run.c.flags")
        #expect(RunSettings.flagsKey(for: .cpp) == "run.cpp.flags")
        #expect(RunSettings.flagsKey(for: .go) == nil)
    }

    @Test func roundTripsSourcePathAndFlags() {
        let defaults = isolatedDefaults()
        let settings = RunSettings(defaults: defaults, center: NotificationCenter())
        settings.setSource(.custom, for: .python)
        settings.setCustomPath("  /opt/py/bin/python3 \n", for: .python)
        settings.setFlagsString("-Wall -I\"/a b\" -DX='1 2'", for: .c)
        settings.setFlagsString("-O2", for: .go) // ignored: Go has no flags key

        #expect(defaults.string(forKey: "run.python.source") == "custom")
        #expect(settings.preference(for: .python) ==
                RunToolPreference(source: .custom, customPath: "/opt/py/bin/python3", extraFlags: []))
        #expect(settings.extraFlags(for: .c) == ["-Wall", "-I/a b", "-DX=1 2"])
        #expect(settings.extraFlags(for: .go).isEmpty)

        settings.setSource(.auto, for: .python)
        settings.setCustomPath("", for: .python)
        #expect(defaults.object(forKey: "run.python.source") == nil)
        #expect(defaults.object(forKey: "run.python.path") == nil)
    }

    @Test func unknownStoredSourceFallsBackToAuto() {
        let defaults = isolatedDefaults()
        defaults.set("bogus", forKey: "run.go.source")
        #expect(RunSettings(defaults: defaults).source(for: .go) == .auto)
    }

    @MainActor @Test func runKeysAreNotArchived() {
        // Machine-specific: must stay out of the settings backup.
        #expect(SettingsArchive.keys.allSatisfy { !$0.hasPrefix("run.") })
    }
}

@Suite("Shell-like flag splitting")
struct ShellWordsTests {
    @Test func splitsOnWhitespace() {
        #expect(ShellWords.split("  -Wall   -O2\t-g ") == ["-Wall", "-O2", "-g"])
        #expect(ShellWords.split("").isEmpty)
        #expect(ShellWords.split("   ").isEmpty)
    }

    @Test func quotesGroupWords() {
        #expect(ShellWords.split(#"-I"/path with space" -D'A B'"#) == ["-I/path with space", "-DA B"])
        #expect(ShellWords.split(#"'it''s' "" x"#) == ["its", "", "x"])
    }

    @Test func escapes() {
        #expect(ShellWords.split(#"a\ b "q\"x" 'no\escape'"#) == ["a b", "q\"x", #"no\escape"#])
    }

    @Test func noShellExpansion() {
        #expect(ShellWords.split("$HOME `id` *.c ;rm") == ["$HOME", "`id`", "*.c", ";rm"])
    }

    @Test func unterminatedQuoteRunsToEnd() {
        #expect(ShellWords.split("-DX=\"abc def") == ["-DX=abc def"])
    }
}
