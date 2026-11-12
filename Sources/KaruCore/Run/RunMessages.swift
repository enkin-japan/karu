import Foundation

/// Localized, user-facing text for the run UI (T16.3b): one actionable
/// message per `RunFailure`, the gray status lines that open and close a run,
/// and the tool-origin captions used by Settings › Run. Pure — every entry
/// takes the UI language explicitly so tests can cover all three tables.
enum RunMessages {
    /// Display name for an editor language identifier: the menu title when the
    /// language is known (`cpp` → `C++`), else the identifier itself.
    static func languageName(_ identifier: String) -> String {
        let id = identifier.lowercased()
        if id.isEmpty { return "Plain Text" }
        return SupportedLanguage.all.first { $0.identifier == id }?.title ?? identifier
    }

    static func failure(_ failure: RunFailure, language: AppLanguage = L10n.current) -> String {
        switch failure {
        case .unrecognized:
            return L10n.string(.runFailUnrecognized, language: language)
        case .notExecutable(let id):
            return L10n.string(.runFailNotExecutable, language: language, languageName(id))
        case .plainTextNotExecutable:
            return L10n.string(.runFailPlainText, language: language)
        case .toolNotFound(let tool):
            return L10n.string(.runFailToolNotFound, language: language, tool)
        case .toolchainNotInstalled(let id):
            return L10n.string(.runFailToolchainNotInstalled, language: language, languageName(id))
        case .customToolInvalid(let path):
            return path.isEmpty
                ? L10n.string(.runFailCustomEmpty, language: language)
                : L10n.string(.runFailCustomInvalid, language: language, path)
        case .developerToolsMissing(let tool):
            return L10n.string(.runFailDeveloperTools, language: language, tool)
        case .javaRuntimeMissing:
            return L10n.string(.runFailJava, language: language)
        case .workspaceFailed(let reason):
            return L10n.string(.runFailWorkspace, language: language, reason)
        case .launchFailed(let reason):
            return L10n.string(.runFailLaunch, language: language, reason)
        }
    }

    /// "▶ Python · /usr/bin/python3" — the first line of every run.
    static func header(language: RunnableLanguage, toolPath: String) -> String {
        "▶ " + languageName(language.identifier) + " · " + toolPath
    }

    /// The tool shown in the header: the compiler for compiled languages,
    /// otherwise the interpreter.
    static func toolPath(of plan: RunPlan) -> String {
        plan.compile?.executable ?? plan.run.executable
    }

    static func duration(_ seconds: TimeInterval) -> String {
        String(format: "%.2f s", max(0, seconds))
    }

    /// The closing status line for a finished run.
    static func completion(_ result: RunResult, language: AppLanguage = L10n.current) -> String {
        switch result.completion {
        case .finished(let termination):
            if result.wasStopped { return L10n.string(.runStopped, language: language) }
            switch termination {
            case .exited(let code):
                return L10n.string(.runExited, language: language, Int(code), duration(result.duration))
            case .signaled(let signal):
                return L10n.string(.runSignaled, language: language, Int(signal), duration(result.duration))
            }
        case .compileFailed(let termination):
            if result.wasStopped { return L10n.string(.runStopped, language: language) }
            switch termination {
            case .exited(let code):
                return L10n.string(.runCompileFailed, language: language, Int(code))
            case .signaled(let signal):
                return L10n.string(.runCompileSignaled, language: language, Int(signal))
            }
        case .launchFailed(let failure):
            return Self.failure(failure, language: language)
        case .cancelled:
            return L10n.string(.runCancelled, language: language)
        }
    }

    static func origin(_ origin: ToolOrigin, language: AppLanguage = L10n.current) -> String {
        switch origin {
        case .custom: return L10n.string(.runOriginCustom, language: language)
        case .managed: return L10n.string(.runOriginManaged, language: language)
        case .loginPath: return L10n.string(.runOriginLogin, language: language)
        case .systemPath: return L10n.string(.runOriginSystem, language: language)
        case .fixed: return L10n.string(.runOriginFixed, language: language)
        }
    }

    // MARK: Managed toolchains (T16.5)

    /// "27 MB" (decimal megabytes, at least 1; unit not localized).
    static func megabytes(_ bytes: Int64) -> String {
        "\(max(1, Int((Double(bytes) / 1_000_000).rounded()))) MB"
    }

    static func toolchainError(_ error: ToolchainInstallError, language: AppLanguage = L10n.current) -> String {
        switch error {
        case .cancelled: return L10n.string(.runToolchainErrorCancelled, language: language)
        case .network(let reason): return L10n.string(.runToolchainErrorNetwork, language: language, reason)
        case .httpStatus(let code): return L10n.string(.runToolchainErrorHTTP, language: language, code)
        case .insecureURL(let url): return L10n.string(.runToolchainErrorInsecure, language: language, url)
        case .checksumMismatch: return L10n.string(.runToolchainErrorChecksum, language: language)
        case .extractionFailed(let reason): return L10n.string(.runToolchainErrorExtract, language: language, reason)
        case .executableMissing(let path): return L10n.string(.runToolchainErrorMissing, language: language, path)
        case .filesystem(let reason): return L10n.string(.runToolchainErrorFilesystem, language: language, reason)
        }
    }

    /// Status line of a managed toolchain in Settings › Run: activity first,
    /// then the last failure, then installed / not-installed.
    static func toolchainStatus(_ entry: ToolchainManifestEntry, _ state: ToolchainManager.State,
                                language: AppLanguage = L10n.current) -> String {
        if let activity = state.activity {
            switch activity {
            case .downloading:
                let percent = Int(((activity.fraction ?? 0) * 100).rounded(.down))
                return L10n.string(.runToolchainDownloading, language: language, percent)
            case .verifying: return L10n.string(.runToolchainVerifying, language: language)
            case .extracting: return L10n.string(.runToolchainExtracting, language: language)
            case .uninstalling: return L10n.string(.runToolchainUninstalling, language: language)
            }
        }
        if let error = state.lastError {
            return L10n.string(.runToolchainFailed, language: language, toolchainError(error, language: language))
        }
        guard let version = state.installedVersion else {
            return L10n.string(.runToolchainNotInstalled, language: language, megabytes(entry.downloadSize))
        }
        guard let usage = state.diskUsage else {
            return L10n.string(.runToolchainInstalled, language: language, version)
        }
        return L10n.string(.runToolchainInstalledSize, language: language, version, megabytes(usage))
    }

    static func sourceTitle(_ source: ToolchainSource, language: AppLanguage = L10n.current) -> String {
        switch source {
        case .auto: return L10n.string(.runSourceAuto, language: language)
        case .managed: return L10n.string(.runSourceManaged, language: language)
        case .system: return L10n.string(.runSourceSystem, language: language)
        case .custom: return L10n.string(.runSourceCustom, language: language)
        }
    }
}
