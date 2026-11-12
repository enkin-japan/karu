import Foundation

/// Where a language's tool comes from (ARCHITECTURE.md §6 "工具链来源").
public enum ToolchainSource: String, CaseIterable, Sendable {
    /// Custom path if set and executable → Karu-managed → system PATH.
    case auto
    /// Only the Karu-managed toolchain (T16.5).
    case managed
    /// Only the login-shell PATH, then the default system PATH.
    case system
    /// Only the configured custom absolute path.
    case custom
}

/// Immutable snapshot of one language's run preferences, safe to hand to a
/// background queue (the locator and plan builder take this, never the live
/// `UserDefaults`).
public struct RunToolPreference: Equatable, Sendable {
    public var source: ToolchainSource
    /// Absolute path to the tool when the user configured one (`nil` = unset).
    public var customPath: String?
    /// Extra compiler flags (C / C++ only; empty for other languages).
    public var extraFlags: [String]

    public init(source: ToolchainSource = .auto, customPath: String? = nil, extraFlags: [String] = []) {
        self.source = source
        self.customPath = customPath
        self.extraFlags = extraFlags
    }
}

/// UserDefaults-backed run preferences. Machine-specific (paths, installed
/// toolchains), so deliberately **not** part of `SettingsArchive`.
///
/// Keys: `run.<lang>.source` (`auto|managed|system|custom`, default auto),
/// `run.<lang>.path` (custom absolute path), `run.c.flags`, `run.cpp.flags`
/// (raw strings split with `ShellWords.split`, no shell involved).
public struct RunSettings {
    public static let didChangeNotification = Notification.Name("KaruRunSettingsDidChange")
    public static let cFlagsKey = "run.c.flags"
    public static let cppFlagsKey = "run.cpp.flags"

    public static func sourceKey(for language: RunnableLanguage) -> String { "run.\(language.rawValue).source" }
    public static func pathKey(for language: RunnableLanguage) -> String { "run.\(language.rawValue).path" }
    /// Flags key for C / C++; `nil` for languages without extra flags.
    public static func flagsKey(for language: RunnableLanguage) -> String? {
        switch language {
        case .c: return cFlagsKey
        case .cpp: return cppFlagsKey
        default: return nil
        }
    }

    private let defaults: UserDefaults
    private let center: NotificationCenter

    public init(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = center
    }

    public func source(for language: RunnableLanguage) -> ToolchainSource {
        defaults.string(forKey: Self.sourceKey(for: language)).flatMap(ToolchainSource.init(rawValue:)) ?? .auto
    }

    public func setSource(_ source: ToolchainSource, for language: RunnableLanguage) {
        let key = Self.sourceKey(for: language)
        if source == .auto { defaults.removeObject(forKey: key) } else { defaults.set(source.rawValue, forKey: key) }
        notify(language)
    }

    /// The configured custom path, trimmed; `nil` when unset or blank.
    public func customPath(for language: RunnableLanguage) -> String? {
        let raw = defaults.string(forKey: Self.pathKey(for: language))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    public func setCustomPath(_ path: String?, for language: RunnableLanguage) {
        let key = Self.pathKey(for: language)
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(trimmed, forKey: key) }
        notify(language)
    }

    /// The raw flags string for C / C++ (empty for other languages / unset).
    public func flagsString(for language: RunnableLanguage) -> String {
        guard let key = Self.flagsKey(for: language) else { return "" }
        return defaults.string(forKey: key) ?? ""
    }

    public func setFlagsString(_ flags: String, for language: RunnableLanguage) {
        guard let key = Self.flagsKey(for: language) else { return }
        if flags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(flags, forKey: key)
        }
        notify(language)
    }

    /// Parsed extra flags for C / C++ (empty otherwise).
    public func extraFlags(for language: RunnableLanguage) -> [String] {
        ShellWords.split(flagsString(for: language))
    }

    /// A Sendable snapshot for the locator / plan builder.
    public func preference(for language: RunnableLanguage) -> RunToolPreference {
        RunToolPreference(source: source(for: language),
                          customPath: customPath(for: language),
                          extraFlags: extraFlags(for: language))
    }

    private func notify(_ language: RunnableLanguage) {
        center.post(name: Self.didChangeNotification, object: language.rawValue)
    }
}

/// Minimal shell-like word splitting for user-entered flags. No expansion,
/// globbing or substitution — only whitespace separation, single quotes
/// (literal), double quotes (`\"` and `\\` escapes) and backslash escapes
/// outside quotes. An unterminated quote runs to the end of the input.
public enum ShellWords {
    public static func split(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = Array(input).makeIterator()
        enum Quote { case none, single, double }
        var quote = Quote.none

        while let ch = iterator.next() {
            switch quote {
            case .single:
                if ch == "'" { quote = .none } else { current.append(ch) }
            case .double:
                if ch == "\"" {
                    quote = .none
                } else if ch == "\\" {
                    guard let next = iterator.next() else { current.append(ch); break }
                    if next == "\"" || next == "\\" { current.append(next) } else { current.append(ch); current.append(next) }
                } else {
                    current.append(ch)
                }
            case .none:
                if ch.isWhitespace {
                    if inWord { words.append(current); current = ""; inWord = false }
                } else if ch == "'" {
                    quote = .single; inWord = true
                } else if ch == "\"" {
                    quote = .double; inWord = true
                } else if ch == "\\" {
                    inWord = true
                    if let next = iterator.next() { current.append(next) }
                } else {
                    current.append(ch); inWord = true
                }
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
