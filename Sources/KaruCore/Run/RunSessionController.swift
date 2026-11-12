import AppKit

/// What a run session needs from its editor window (T16.3b).
/// `EditorWindowController` is the only conformer.
@MainActor
protocol RunSessionHost: AnyObject {
    /// Snapshot of the buffer to run.
    var runSourceText: String { get }
    var currentLanguageIdentifierValue: String { get }
    var isLanguageAuto: Bool { get }
    /// The saved document's URL (working directory), `nil` when untitled.
    var runDocumentURL: URL? { get }
    /// The window's vertical content stack and the editor view the panel is
    /// inserted below.
    var runPanelHost: (stack: NSStackView, editor: NSView)? { get }
    /// The panel height the user last chose in this window (`nil` = default).
    /// Kept by the window so it survives the session being released.
    var runPanelHeight: CGFloat? { get set }
    /// Applies a sniffed language while staying in Auto mode.
    func applyAutoDetectedLanguage(identifier: String)
    /// Running / panel state changed (toolbar refresh).
    func runSessionStateDidChange()
    /// The user closed the panel: the host drops its session.
    func runSessionDidClose()
}

/// Per-window "run the current buffer" driver (T16.3b, ARCHITECTURE.md §6).
///
/// Created lazily by `EditorWindowController` on the first Run / Show Output
/// and released when the panel is closed, the window closes or the `run`
/// module is switched off. Owns at most one `CodeRunner` (and through it the
/// bounded output buffer) and the output panel while it is shown. Holds no
/// timer and no thread: preparation runs as one detached task per run.
@MainActor
final class RunSessionController {
    /// Resolves the tool, builds the plan and writes the workspace. Blocking;
    /// always called off the main thread.
    typealias Prepare = @Sendable (_ language: RunnableLanguage, _ text: String, _ documentURL: URL?,
                                   _ preference: RunToolPreference) -> Result<RunPlan, RunFailure>

    nonisolated static let defaultPrepare: Prepare = { language, text, url, preference in
        RunPreparer().prepare(language: language, text: text, documentURL: url, preference: preference)
    }

    static let minimumPanelHeight: CGFloat = 80
    static let minimumEditorHeight: CGFloat = 60
    static let defaultPanelFraction: CGFloat = 0.3
    static let fallbackPanelHeight: CGFloat = 160

    private weak var host: RunSessionHost?
    private let prepare: Prepare
    private let preference: (RunnableLanguage) -> RunToolPreference

    private(set) var runner: CodeRunner?
    private(set) var panel: RunOutputPanel?
    private var panelConstraints: [NSLayoutConstraint] = []
    private var panelHeightConstraint: NSLayoutConstraint?
    private var dragStart: (panel: CGFloat, available: CGFloat)?

    private(set) var isPreparing = false
    private var prepareGeneration = 0
    private var pendingRerun = false
    private var isStarting = false
    private var deferredFinish: RunResult?
    /// Header label text: "Python · /usr/bin/python3".
    private var info = ""

    var isRunning: Bool { runner?.isRunning ?? false }
    /// Preparing or running — the toolbar shows Stop.
    var isActive: Bool { isPreparing || isRunning }
    var isPanelVisible: Bool { panel != nil }

    init(host: RunSessionHost, prepare: @escaping Prepare = RunSessionController.defaultPrepare,
         preference: @escaping (RunnableLanguage) -> RunToolPreference = { RunSettings().preference(for: $0) }) {
        self.host = host
        self.prepare = prepare
        self.preference = preference
    }

    // MARK: Commands

    /// Run ⌘R. While a run is active it is stopped first and the new run
    /// starts once it has finished (stop-and-rerun).
    func run() {
        if isRunning {
            pendingRerun = true
            runner?.stop()
            notify()
            return
        }
        startRun()
    }

    /// Stop ⌘. — cancels a preparation or stops the process group.
    func stop() {
        pendingRerun = false
        if isPreparing {
            prepareGeneration += 1
            isPreparing = false
            appendStatus(L10n.t(.runCancelled))
            notify()
            return
        }
        runner?.stop()
    }

    func toggleOutput() {
        if isPanelVisible { hideOutput() } else { showOutput() }
    }

    /// Creates the panel (if hidden) below the editor and renders the retained output.
    func showOutput() {
        guard panel == nil, let (stack, editor) = host?.runPanelHost else { return }
        let panel = RunOutputPanel()
        panel.onClear = { [weak self] in self?.clearOutput() }
        panel.onStopOrRerun = { [weak self] in
            guard let self else { return }
            if self.isActive { self.stop() } else { self.run() }
        }
        panel.onClose = { [weak self] in self?.closeOutput() }
        panel.onSendLine = { [weak self] in self?.sendLine($0) }
        panel.onEOF = { [weak self] in self?.sendEOF() }
        panel.onLanguageChange = { [weak self] in self?.refreshPanel(rerender: true) }
        panel.divider.onDragBegan = { [weak self, weak panel, weak editor] in
            guard let panel, let editor else { return }
            self?.dragStart = (panel.frame.height, panel.frame.height + editor.frame.height)
        }
        panel.divider.onDrag = { [weak self] delta in self?.dragPanel(by: delta) }

        let height = host?.runPanelHeight ?? Self.defaultHeight(editorHeight: editor.frame.height)
        panel.translatesAutoresizingMaskIntoConstraints = false
        let index = stack.arrangedSubviews.firstIndex(of: editor).map { $0 + 1 } ?? stack.arrangedSubviews.count
        stack.insertArrangedSubview(panel, at: index)
        let heightConstraint = panel.heightAnchor.constraint(equalToConstant: height)
        heightConstraint.priority = NSLayoutConstraint.Priority(990)
        let panelMin = panel.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumPanelHeight)
        panelMin.priority = NSLayoutConstraint.Priority(999)
        let editorMin = editor.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumEditorHeight)
        editorMin.priority = NSLayoutConstraint.Priority(995)
        panelConstraints = [heightConstraint, panelMin, editorMin,
                            panel.widthAnchor.constraint(equalTo: stack.widthAnchor)]
        NSLayoutConstraint.activate(panelConstraints)
        panelHeightConstraint = heightConstraint
        self.panel = panel
        refreshPanel(rerender: true)
        notify()
    }

    /// Hides (and releases) the panel; a running process keeps running.
    func hideOutput() {
        guard let panel else { return }
        NSLayoutConstraint.deactivate(panelConstraints)
        panelConstraints = []
        panelHeightConstraint = nil
        dragStart = nil
        if let stack = panel.superview as? NSStackView { stack.removeArrangedSubview(panel) }
        panel.removeFromSuperview()
        self.panel = nil
        notify()
    }

    /// The panel's × button: stops the run and releases panel, runner and session.
    func closeOutput() {
        tearDown()
        host?.runSessionDidClose()
    }

    /// Releases everything (window close, module off, panel close). A live
    /// process is stopped; its runner is kept only until it has exited so the
    /// temp workspace is still cleaned up.
    func tearDown() {
        prepareGeneration += 1
        isPreparing = false
        pendingRerun = false
        if let runner {
            Self.retire(runner)
            self.runner = nil
        }
        hideOutput()
    }

    func clearOutput() {
        runner?.clearOutput()
        refreshPanel(rerender: true)
    }

    func sendLine(_ line: String) {
        guard let runner, runner.isRunning else { return }
        runner.send(line: line)
        appendSystemText("› " + line + "\n")
    }

    func sendEOF() {
        guard let runner, runner.isRunning else { return }
        runner.sendEOF()
        panel?.setInputEnabled(false)
    }

    // MARK: Run flow

    private func startRun() {
        guard let host else { return }
        showOutput()
        let text = host.runSourceText
        let resolution = RunLanguageResolver.resolve(identifier: host.currentLanguageIdentifierValue,
                                                     isManual: !host.isLanguageAuto, text: text)
        let language: RunnableLanguage
        switch resolution {
        case .failure(let failure):
            report(failure, info: "")
            return
        case .run(let resolved, let corrected):
            language = resolved
            if let corrected { host.applyAutoDetectedLanguage(identifier: corrected) }
        }

        let runner = ensureRunner()
        runner.clearOutput()
        info = RunMessages.languageName(language.identifier) + " · " + L10n.t(.runPreparing)
        isPreparing = true
        prepareGeneration += 1
        let generation = prepareGeneration
        let url = host.runDocumentURL
        let preference = preference(language)
        let prepare = self.prepare
        refreshPanel(rerender: true)
        notify()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = prepare(language, text, url, preference)
            let consumed = await self?.finishPreparing(result, language: language, generation: generation) ?? false
            // Superseded (rerun / stop) or the session is gone (window closed,
            // module off): drop the unused workspace.
            if !consumed, case .success(let plan) = result { RunWorkspace.cleanup(plan) }
        }
    }

    /// Returns false when the preparation was superseded and its plan unused.
    private func finishPreparing(_ result: Result<RunPlan, RunFailure>, language: RunnableLanguage,
                                 generation: Int) -> Bool {
        guard generation == prepareGeneration, isPreparing else { return false }
        isPreparing = false
        switch result {
        case .failure(let failure):
            report(failure, info: RunMessages.languageName(language.identifier))
        case .success(let plan):
            launch(plan)
        }
        notify()
        return true
    }

    private func launch(_ plan: RunPlan) {
        let runner = ensureRunner()
        let tool = RunMessages.toolPath(of: plan)
        info = RunMessages.languageName(plan.language.identifier) + " · " + tool
        isStarting = true
        let started = runner.start(plan)
        isStarting = false
        guard started else {
            DispatchQueue.global(qos: .utility).async { RunWorkspace.cleanup(plan) }
            return
        }
        // `start` cleared the buffer; the header goes first.
        runner.appendSystem(RunMessages.header(language: plan.language, toolPath: tool) + "\n")
        refreshPanel(rerender: true)
        if let result = deferredFinish {
            // The spawn failed synchronously inside `start`.
            deferredFinish = nil
            handleFinish(result)
        }
        notify()
    }

    private func ensureRunner() -> CodeRunner {
        if let runner { return runner }
        let runner = CodeRunner()
        runner.onOutput = { [weak self] chunks in
            guard let self, let runner = self.runner else { return }
            self.panel?.append(chunks, buffer: runner.output)
        }
        runner.onFinish = { [weak self] result in
            guard let self else { return }
            if self.isStarting { self.deferredFinish = result } else { self.handleFinish(result) }
        }
        self.runner = runner
        return runner
    }

    private func handleFinish(_ result: RunResult) {
        appendStatus(RunMessages.completion(result))
        refreshPanel(rerender: false)
        notify()
        if pendingRerun {
            pendingRerun = false
            startRun()
        }
    }

    /// Shows a resolve / prepare failure as the panel's only content.
    private func report(_ failure: RunFailure, info: String) {
        let runner = ensureRunner()
        runner.clearOutput()
        self.info = info
        runner.appendSystem(RunMessages.failure(failure) + "\n")
        refreshPanel(rerender: true)
        notify()
    }

    /// Appends a gray status line, starting a new line if the output does not
    /// end with one.
    private func appendStatus(_ line: String) {
        let atLineStart = runner?.output.segments.last?.text.last.map(\.isNewline) ?? true
        let prefix = atLineStart ? "" : "\n"
        appendSystemText(prefix + line + "\n")
    }

    private func appendSystemText(_ text: String) {
        let runner = ensureRunner()
        runner.appendSystem(text)
        panel?.append([RunOutputChunk(stream: .system, text: text)], buffer: runner.output)
    }

    private func refreshPanel(rerender: Bool) {
        guard let panel else { return }
        panel.update(isActive: isActive, acceptsInput: isRunning, info: info)
        if rerender { panel.render(runner?.output ?? RunOutputBuffer()) }
    }

    private func notify() {
        panel?.update(isActive: isActive, acceptsInput: isRunning, info: info)
        host?.runSessionStateDidChange()
    }

    // MARK: Panel height

    static func defaultHeight(editorHeight: CGFloat) -> CGFloat {
        guard editorHeight >= 1 else { return fallbackPanelHeight }
        return max(minimumPanelHeight, (editorHeight * defaultPanelFraction).rounded())
    }

    /// Applies a divider drag: `delta` > 0 grows the panel. Clamped so the
    /// panel stays ≥ 80 pt and the editor ≥ 60 pt.
    func dragPanel(by delta: CGFloat) {
        guard let start = dragStart, let constraint = panelHeightConstraint else { return }
        let maximum = max(Self.minimumPanelHeight, start.available - Self.minimumEditorHeight)
        let height = min(max(start.panel + delta, Self.minimumPanelHeight), maximum).rounded()
        constraint.constant = height
        host?.runPanelHeight = height
    }

    // MARK: Retiring runners

    /// Runners stopped by a teardown, kept alive until their process exits
    /// (so `CodeRunner` still removes the temp workspace). Empty when idle.
    private static var retiring: [ObjectIdentifier: CodeRunner] = [:]
    static var retiringCount: Int { retiring.count }

    private static func retire(_ runner: CodeRunner) {
        runner.onOutput = nil
        runner.onPhaseChange = nil
        guard runner.isRunning else {
            runner.onFinish = nil
            return
        }
        let id = ObjectIdentifier(runner)
        retiring[id] = runner
        runner.onFinish = { _ in RunSessionController.retiring[id] = nil }
        runner.stop()
    }
}

// MARK: - Window entry points (menu / toolbar first-responder targets)

extension EditorWindowController {
    var isRunModuleEnabled: Bool { runModuleSettings.isEnabled(.run) }
    var isRunActive: Bool { runSession?.isActive ?? false }

    /// The session, created on first use; `nil` while the `run` module is off.
    @discardableResult
    func ensureRunSession() -> RunSessionController? {
        guard isRunModuleEnabled else { return nil }
        if let runSession { return runSession }
        let session = RunSessionController(host: self, prepare: runPrepare)
        runSession = session
        return session
    }

    /// Stops the run and releases the session and panel (window close / module off).
    func tearDownRunSession() {
        guard let session = runSession else { return }
        runSession = nil
        session.tearDown()
        runSessionStateDidChange()
    }

    /// The scratchpad is a panel, so the main editor window behind it would
    /// otherwise receive Run through the main-window responder chain.
    private var isScratchpadKey: Bool {
        NSApp?.keyWindow?.delegate is ScratchpadController
    }

    /// Run ⌘R (stop-and-rerun while active).
    @objc public func runCode(_ sender: Any?) {
        guard !isScratchpadKey, let session = ensureRunSession() else { NSSound.beep(); return }
        session.run()
    }

    /// Stop ⌘.
    @objc public func stopRun(_ sender: Any?) {
        guard let session = runSession, session.isActive else { NSSound.beep(); return }
        session.stop()
    }

    /// Show / Hide Output ⇧⌘Y.
    @objc public func toggleRunOutput(_ sender: Any?) {
        guard !isScratchpadKey, let session = ensureRunSession() else { NSSound.beep(); return }
        session.toggleOutput()
    }

    /// Validation for the Run menu; `nil` for other items.
    func validateRunMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(runCode(_:)):
            return isRunModuleEnabled && !isScratchpadKey
        case #selector(stopRun(_:)):
            return isRunModuleEnabled && !isScratchpadKey && isRunActive
        case #selector(toggleRunOutput(_:)):
            let visible = runSession?.isPanelVisible ?? false
            item.title = L10n.t(visible ? .menuRunHideOutput : .menuRunShowOutput)
            return isRunModuleEnabled && !isScratchpadKey
        default:
            return nil
        }
    }
}
