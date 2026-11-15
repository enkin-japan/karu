import Foundation

// M17 T17.14 — a static-language source file read from disk, outside any
// editor window: the project-folder index (signature summaries) and the
// cross-file type lookup (`CrossFileTypeService`) read declarations of
// files that are not open. Same token reader and declaration reader as the
// document path (`BraceModuleView`), with no edit journal (snapshot offsets
// are text offsets) and the file's own lexical checkpoints. Confined to the
// thread that created it (the index or cross-file queue).

final class BraceStaticFile {
    let text: NSString
    let language: BraceLanguage
    let identifier: String
    let reader: BraceTokenReader
    let decls: BraceDeclReader

    private final class CheckpointBox {
        var store = CheckpointStore()
    }

    init(text: NSString, language: BraceLanguage, identifier: String) {
        self.text = text
        self.language = language
        self.identifier = identifier
        let scanner = LexicalScanner(profile: language.lexicalProfile)
        let box = CheckpointBox()
        reader = BraceTokenReader(text: text, language: language, scanner: scanner) { at in
            WindowScan.resume(text: text, at: at, caret: at, hostIdentifier: identifier, scanner: scanner,
                              checkpoints: &box.store)
        }
        decls = BraceDeclReader(reader: reader)
    }

    /// The signature summary of the declaration whose name is at `location`
    /// (`BraceSummary.signature`: a function's parameters and result, a
    /// field's written type); nil when nothing is written.
    func signature(at location: Int, kind: DeclarationScan.DeclarationKind) -> String? {
        guard let (tk, n) = BraceSummary.tokens(reader: reader, atName: location) else { return nil }
        let info = decls.read(tk, name: n, kind: kind)
        return BraceSummary.signature(info, tokens: tk, reader: reader)
    }
}
