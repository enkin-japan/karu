import Foundation

/// Languages the run engine can execute (ARCHITECTURE.md §6). Raw values are
/// the editor's language identifiers (`SupportedLanguage.all`), so a window's
/// current identifier maps straight onto a case.
public enum RunnableLanguage: String, CaseIterable, Sendable {
    case python, javascript, typescript, bash, c, cpp, swift, go, rust, java, csharp

    /// The editor language identifier (same as `rawValue`).
    public var identifier: String { rawValue }

    /// Case-insensitive lookup from an editor identifier; `nil` when the
    /// language is not runnable (Plain Text, JSON, Markdown, SQL, HTML, …).
    public init?(identifier: String) {
        self.init(rawValue: identifier.lowercased())
    }
}

/// Why a run could not start (or a tool could not be located). Plain data —
/// T16.3b maps each case to a localized message; nothing here is user-facing.
public enum RunFailure: Error, Equatable, Sendable {
    /// Auto mode on a Plain Text buffer and the sniffer recognised nothing.
    case unrecognized
    /// The language (identifier attached) exists but cannot be executed.
    case notExecutable(String)
    /// The user explicitly chose Plain Text.
    case plainTextNotExecutable
    /// No executable named `tool` on the custom / managed / login / default path.
    case toolNotFound(String)
    /// The source is "managed" but no Karu-installed toolchain is available
    /// for the language (identifier attached).
    case toolchainNotInstalled(String)
    /// The source is "custom" but the configured path is empty or not an
    /// executable file (path attached, may be empty).
    case customToolInvalid(String)
    /// The resolved tool is an Apple `/usr/bin` shim (tool attached) and no
    /// developer directory is installed; invoking it would pop the system
    /// "install Command Line Tools" dialog, so the engine refuses first.
    case developerToolsMissing(String)
    /// `/usr/bin/java` (or `javac`) is the macOS stub and no JDK is installed.
    case javaRuntimeMissing
    /// The temp workspace could not be created / written (reason attached).
    case workspaceFailed(String)
    /// `posix_spawn` (or the pipe setup) failed (reason attached).
    case launchFailed(String)
}

/// Outcome of resolving which language to run.
public enum RunLanguageResolution: Equatable, Sendable {
    /// Run as `language`. `correctedIdentifier` is non-nil only when the
    /// window was Auto + Plain Text and the sniffer found the language: the UI
    /// should apply it to the title bar while staying in Auto mode.
    case run(RunnableLanguage, correctedIdentifier: String?)
    case failure(RunFailure)
}

/// The language-resolution policy for "run the current buffer"
/// (ARCHITECTURE.md §6 "语言判定"). Pure logic.
///
/// - A manually chosen language is used as-is and never rewritten.
/// - Auto mode with a language already set uses that language.
/// - Auto mode on Plain Text sniffs the whole buffer (no minimum-length
///   threshold; the sniffer still caps its own sample at 8 KB).
/// - There is deliberately no run-time C→C++ / JS→TS refinement.
public enum RunLanguageResolver {
    public static func resolve(identifier: String, isManual: Bool, text: String) -> RunLanguageResolution {
        let id = identifier.lowercased()
        if !id.isEmpty {
            guard let language = RunnableLanguage(identifier: id) else {
                return .failure(.notExecutable(id))
            }
            return .run(language, correctedIdentifier: nil)
        }
        if isManual { return .failure(.plainTextNotExecutable) }

        guard let sniffed = LanguageSniffer.sniff(text) else { return .failure(.unrecognized) }
        guard let language = RunnableLanguage(identifier: sniffed) else {
            return .failure(.notExecutable(sniffed))
        }
        return .run(language, correctedIdentifier: sniffed)
    }
}
