import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.11b — type inference for Python member completion (plan §8.1,
// §5.4, §13): each capability of the Python column, precision rules,
// incomplete code, caches and their release, the large-document path and
// the completion wiring (summaries in the rows).

private func isolatedDefaults() -> (UserDefaults, () -> Void) {
    let name = "TypeInferenceTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return (d, { d.removePersistentDomain(forName: name) })
}

/// A Python document in a text view with its analysis and an inference
/// service. `source` marks the caret with `|` (after `receiver.` and an
/// optional member prefix).
@MainActor
private final class Inference {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    let analysis: DocumentAnalysis
    let service: TypeInferenceService
    let caret: Int
    let hub = TextStorageObserverHub()
    private let clean: () -> Void

    init(_ source: String, tables: PythonTypeTables? = nil) {
        let ns = source as NSString
        let bar = ns.range(of: "|", options: .backwards)
        precondition(bar.location != NSNotFound, "mark the caret with |")
        caret = bar.location
        textView.string = ns.replacingCharacters(in: bar, with: "")
        let (defaults, clean) = isolatedDefaults()
        self.clean = clean
        analysis = DocumentAnalysis(textView: textView, moduleSettings: ModuleSettings(defaults: defaults, center: NotificationCenter()),
                                    moduleCenter: NotificationCenter(), scheduler: AnalysisScheduler())
        analysis.setLanguage(identifier: "python")
        service = TypeInferenceService(tables: tables ?? .shared)
        // Edits reach the analysis as in the editor window.
        hub.add(analysis)
        textView.textStorage?.delegate = hub
    }

    deinit { clean() }

    var text: NSString { textView.textStorage!.mutableString }

    var dot: Int {
        let start = IdentifierText.runStart(before: caret, in: text, dollar: false) ?? caret
        return start - 1
    }

    /// Candidates in the engine's ranking order (no prefix filtering).
    var candidates: [Candidate]? {
        service.memberCandidates(analysis: analysis, text: text, dot: dot).map { CandidateEngine.ranked($0) }
    }

    var names: [String]? { candidates?.map(\.name) }

    func detail(_ name: String) -> String? { candidates?.first { $0.name == name }?.detail }

    /// The receiver's type, straight from an evaluator.
    var receiver: InferredType {
        guard let snapshot = analysis.ensureSyntax(), let tree = snapshot.tree else { return .unknown }
        let module = PyModuleView(storage: .tree(PyUnit(tree)), text: text, parseStatement: { _ in nil })
        guard let stmt = module.topLevelStatement(containing: dot),
              let member = TypeInferenceService.memberNode(in: stmt, dot: dot) else { return .unknown }
        let evaluator = PythonEvaluator(text: text, module: module, tables: .shared,
                                        returnCache: ByteLRU(byteLimit: 1 << 20), budget: InferenceBudget())
        return evaluator.receiverType(of: member)
    }
}

@MainActor
private func names(_ source: String) -> [String]? { Inference(source).names }

@MainActor
private func receiver(_ source: String) -> InferredType { Inference(source).receiver }

private let str = InferredType.instance(.table("builtins", "str"), [])
private let int = InferredType.instance(.table("builtins", "int"), [])

// MARK: - Annotations and generics

@Suite("TypeInference annotations")
@MainActor
struct TypeInferenceAnnotationTests {
    @Test func parameterAnnotation() throws {
        let list = try #require(names("def f(name: str):\n    name.|"))
        #expect(list.contains("upper") && list.contains("startswith"))
        #expect(!list.contains("append") && !list.contains("bit_length"))
    }

    @Test func stringAnnotationForwardReference() throws {
        let src = """
        def use(c: "Client"):
            c.|

        class Client:
            def connect(self) -> bool:
                return True
        """
        #expect(try #require(names(src)).contains("connect"))
    }

    @Test func optionalUnnarrowedListsTheInnerMembers() throws {
        let list = try #require(names("from typing import Optional\nfrom pathlib import Path\ndef f(p: Optional[Path]):\n    p.|"))
        #expect(list.contains("read_text") && list.contains("name"))
    }

    @Test func pep604UnionWithNone() throws {
        #expect(try #require(names("def f(s: str | None):\n    s.|")).contains("upper"))
    }

    @Test func genericContainerSubscript() {
        #expect(receiver("def f(xs: list[int]):\n    xs[0].|") == int)
        let nested = receiver("def f(d: dict[str, list[int]]):\n    d['a'].|")
        #expect(nested == .instance(.table("builtins", "list"), [int]))
    }

    @Test func typeVarSolvedFromArgument() {
        let src = """
        from typing import TypeVar
        T = TypeVar("T")
        def first(xs: list[T]) -> T:
            return xs[0]
        def g():
            first(["a", "b"]).|
        """
        #expect(receiver(src) == str)
    }

    @Test func pep695TypeParameters() {
        let src = "def last[T](xs: list[T]) -> T:\n    return xs[-1]\nlast([1, 2]).|"
        #expect(receiver(src) == int)
    }

    @Test func typingAliasesAndIterables() {
        #expect(receiver("from typing import List\ndef f(xs: List[str]):\n    for x in xs:\n        x.|") == str)
        #expect(receiver("from typing import Iterable\ndef f(xs: Iterable[str]):\n    for x in xs:\n        x.|") == str)
        #expect(receiver("from typing import Iterator\ndef f(it: Iterator[int]):\n    next(it).|") == int)
    }

    @Test func callableAnnotationCall() {
        let src = "from typing import Callable\nclass C:\n    pass\ndef f(make: Callable[[], C]):\n    make().|"
        #expect(receiver(src) == .instance(.document("C"), []))
    }

    @Test func tupleAnnotationIndex() {
        #expect(receiver("def f(t: tuple[int, str]):\n    t[1].|") == str)
        #expect(receiver("def f(t: tuple[int, ...]):\n    t[3].|") == int)
    }
}

// MARK: - Classes

@Suite("TypeInference classes")
@MainActor
struct TypeInferenceClassTests {
    @Test func dataclassFieldsAndProperty() throws {
        let src = """
        from dataclasses import dataclass
        @dataclass
        class Point:
            x: float
            y: float
            @property
            def norm(self) -> float:
                return 0.0
        p = Point(1.0, 2.0)
        p.|
        """
        let i = Inference(src)
        let list = try #require(i.names)
        #expect(Array(list.prefix(3)) == ["norm", "x", "y"])
        #expect(i.detail("x") == "float")
        #expect(i.detail("norm") == "float")
        #expect(receiver("from dataclasses import dataclass\n@dataclass\nclass P:\n    x: float\nP(1).x.|")
                == .instance(.table("builtins", "float"), []))
    }

    @Test func namedTupleFields() throws {
        let src = "from typing import NamedTuple\nclass Pair(NamedTuple):\n    left: str\n    right: int\ndef f(p: Pair):\n    p.|"
        let list = try #require(names(src))
        #expect(list.contains("left") && list.contains("right") && list.contains("_asdict") && list.contains("count"))
        #expect(receiver(src.replacingOccurrences(of: "p.|", with: "p.left.|")) == str)
    }

    @Test func typedDictKeysAreNotAttributes() throws {
        let src = "from typing import TypedDict\nclass Movie(TypedDict):\n    title: str\n    year: int\ndef f(m: Movie):\n    m.|"
        let list = try #require(names(src))
        #expect(list.contains("keys") && list.contains("get"))
        #expect(!list.contains("title") && !list.contains("year"))
        #expect(receiver(src.replacingOccurrences(of: "m.|", with: "m[\"title\"].|")) == str)
    }

    @Test func selfFieldsFromInitAndOtherMethods() throws {
        let src = """
        class Client:
            def __init__(self, host: str):
                self.host = host
                self.items = []
            def open(self):
                self.session = Session()
                self.|
        class Session:
            def commit(self): pass
        """
        let i = Inference(src)
        let list = try #require(i.names)
        #expect(Array(list.prefix(4)).sorted() == ["host", "items", "open", "session"])
        #expect(i.detail("host") == "str")
        #expect(receiver(src.replacingOccurrences(of: "self.|", with: "self.session.|")) == .instance(.document("Session"), []))
    }

    @Test func inheritedMembersRankAfterOwnAndDundersLast() throws {
        let src = """
        class Base:
            def base_method(self): pass
        class Child(Base):
            def own(self): pass
            def __repr__(self): return ""
            def _private(self): pass
        Child().|
        """
        let list = try #require(names(src))
        #expect(Array(list.prefix(3)) == ["own", "base_method", "_private"])
        #expect(list.firstIndex(of: "__repr__")! > list.firstIndex(of: "_private")!)
        #expect(list.last?.hasPrefix("__") == true)
    }

    @Test func classMethodAndClsAndClassObject() throws {
        let src = """
        class Repo:
            registry = {}
            def __init__(self):
                self.rows = []
            @classmethod
            def create(cls):
                cls.|
            def save(self): pass
        """
        let list = try #require(names(src))
        #expect(list.contains("create") && list.contains("save") && list.contains("registry"))
        #expect(!list.contains("rows"))   // instance-only field
        #expect(receiver(src.replacingOccurrences(of: "cls.|", with: "cls().|")) == .instance(.document("Repo"), []))
    }

    @Test func enumMembers() {
        let src = "from enum import Enum\nclass Color(Enum):\n    RED = 1\n    BLUE = 2\nColor.RED.|"
        #expect(receiver(src) == .instance(.document("Color"), []))
        let i = Inference(src)
        #expect(i.names?.contains("value") == true && i.names?.contains("name") == true)
    }

    @Test func genericDocumentClassSubstitution() {
        let src = """
        from typing import Generic, TypeVar
        T = TypeVar("T")
        class Box(Generic[T]):
            def __init__(self, item: T):
                self.item = item
            def get(self) -> T:
                return self.item
        def f(b: Box[str]):
            b.get().|
        """
        #expect(receiver(src) == str)
    }

    @Test func superCall() {
        let src = """
        class Base:
            def hello(self) -> str:
                return ""
        class Child(Base):
            def hello(self) -> str:
                super().|
        """
        #expect(Inference(src).names?.contains("hello") == true)
        #expect(receiver(src) == .instance(.document("Base"), []))
    }
}

// MARK: - Inference from values

@Suite("TypeInference values")
@MainActor
struct TypeInferenceValueTests {
    @Test func literals() {
        #expect(receiver("x = 3\nx.|") == .literal(.table("builtins", "int"), "3"))
        #expect(receiver("x = 3.5\nx.|") == .instance(.table("builtins", "float"), []))
        #expect(receiver("x = b'ab'\nx.|") == .instance(.table("builtins", "bytes"), []))
        #expect(receiver("x = f'{1}'\nx.|") == str)
        #expect(receiver("x = True\nx.|") == .literal(.table("builtins", "bool"), "True"))
    }

    @Test func containerLiterals() {
        #expect(receiver("xs = [1, 2]\nxs[0].|") == int)
        #expect(receiver("d = {'a': 1}\nd['a'].|") == int)
        #expect(receiver("s = {'a'}\nfor v in s:\n    v.|") == str)
        #expect(receiver("t = (1, 'a')\nt[1].|") == str)
        #expect(receiver("xs = ['a']\nys = [x.upper() for x in xs]\nys[0].|") == str)
        #expect(receiver("xs = ['a']\n[x.| for x in xs]") == str)
        #expect(receiver("d = {'k': 1}\nfor k, v in d.items():\n    k.|") == str)
    }

    @Test func elementTypeFromAppendAddExtend() {
        #expect(receiver("def f():\n    names = []\n    names.append('a')\n    names[0].|") == str)
        #expect(receiver("def f():\n    seen = set()\n    seen.add(1)\n    for s in seen:\n        s.|") == int)
        #expect(receiver("def f():\n    out = []\n    out.extend(['a'])\n    out[0].|") == str)
        #expect(receiver("def f():\n    d = {}\n    d['k'] = 1.5\n    d['k'].|") == .instance(.table("builtins", "float"), []))
    }

    @Test func returnUnionOfReturns() {
        let src = """
        def load(flag):
            if flag:
                return "a"
            return None
        load(True).|
        """
        #expect(receiver(src) == .union([str, .none]))
        #expect(Inference(src).names?.contains("upper") == true)
    }

    @Test func recursionAndCallDepthAreBounded() {
        let recursive = "def f(n):\n    if n:\n        return f(n - 1)\n    return f(n)\nf(1).|"
        #expect(receiver(recursive) == .unknown || receiver(recursive) == .none)
        let deep = """
        def a(): return b()
        def b(): return c()
        def c(): return d()
        def d(): return "x"
        a().|
        """
        // Beyond the call depth the type is unknown (not guessed).
        #expect(receiver(deep).containsUnknown)
        #expect(receiver("def c(): return d()\ndef d(): return 'x'\nc().|") == str)
    }

    @Test func withAndForBindings() {
        #expect(receiver("def f(p):\n    with open(p) as fh:\n        fh.|") == .instance(.table("_io", "TextIOWrapper"), []))
        #expect(receiver("def f(p):\n    with open(p, 'rb') as fh:\n        fh.|") == .instance(.table("_io", "BufferedReader"), []))
        #expect(receiver("for i, s in enumerate(['a']):\n    s.|") == str)
        #expect(receiver("for line in open('x'):\n    line.|") == str)
    }

    @Test func exceptAndWalrusAndTernary() {
        #expect(receiver("try:\n    pass\nexcept ValueError as e:\n    e.|") == .instance(.table("builtins", "ValueError"), []))
        #expect(receiver("import re\nif (m := re.match('a', 'b')):\n    m.|")
                == .instance(.table("re", "Match"), [str]))
        #expect(receiver("def f(c):\n    x = 'a' if c else 'b'\n    x.|").widened == str)
    }

    @Test func importsResolveThroughTheTables() throws {
        #expect(receiver("import os.path as osp\nosp.|") == .module("os.path"))
        #expect(receiver("import os\nos.path.|") == .module("os.path"))
        #expect(receiver("from collections import defaultdict\nd = defaultdict(list)\nd.|")
                == .instance(.table("collections", "defaultdict"), [.unknown, .instance(.table("builtins", "list"), [])]))
        #expect(receiver("from pathlib import Path\nPath('x').parent.|") == .instance(.table("pathlib", "Path"), []))
        #expect(receiver("import json\njson.loads('1').|") == .unknown)   // Any
        #expect(receiver("from .models import User\nUser.|") == .unknown)  // project import: T17.13
        let os = try #require(names("import os\nos.|"))
        #expect(os.contains("path") && os.contains("getcwd") && !os.contains("sys"))
    }

    @Test func asyncAwait() {
        let src = """
        async def fetch() -> str:
            return ""
        async def main():
            (await fetch()).|
        """
        #expect(receiver(src) == str)
    }

    @Test func operators() {
        #expect(receiver("x = 'a' + 'b'\nx.|") == str)
        #expect(receiver("x = 1 + 2\nx.|") == int)
        #expect(receiver("x = 1 / 2\nx.|") == .instance(.table("builtins", "float"), []))
        #expect(receiver("def f(a: str | None):\n    x = a or 'd'\n    x.|") == str)
    }
}

// MARK: - Narrowing

@Suite("TypeInference narrowing")
@MainActor
struct TypeInferenceNarrowingTests {
    @Test func isinstanceNarrowsAUnion() throws {
        let src = "def f(v: int | str):\n    if isinstance(v, str):\n        v.|"
        let list = try #require(names(src))
        #expect(list.contains("upper") && !list.contains("bit_length"))
        let negative = "def f(v: int | str):\n    if not isinstance(v, str):\n        v.|"
        #expect(receiver(negative) == int)
        #expect(receiver("def f(v: int | str):\n    if isinstance(v, str):\n        pass\n    else:\n        v.|") == int)
    }

    @Test func noneChecks() {
        let opt = "from pathlib import Path\ndef f(p: Path | None):\n"
        let path = InferredType.instance(.table("pathlib", "Path"), [])
        #expect(receiver(opt + "    if p is not None:\n        p.|") == path)
        #expect(receiver(opt + "    if p != None:\n        p.|") == path)
        #expect(receiver(opt + "    if p is None:\n        return\n    p.|") == path)   // early return
        #expect(receiver(opt + "    if not p:\n        raise ValueError()\n    p.|") == path)
        #expect(receiver(opt + "    if p:\n        p.|") == path)                       // truthiness
        #expect(receiver(opt + "    assert p is not None\n    p.|") == path)
        #expect(receiver(opt + "    if p is None:\n        p.|") == .none)
    }

    @Test func narrowingOfAttributeChainsAndAnd() {
        let src = """
        class Node:
            def __init__(self, nxt: "Node | None"):
                self.nxt = nxt
            def walk(self):
                if self.nxt is not None and self.nxt.|
        """
        #expect(receiver(src) == .instance(.document("Node"), []))
        let early = "class N:\n    def __init__(self, v: str | None):\n        self.v = v\n    def m(self):\n        if self.v is None:\n            return\n        self.v.|"
        #expect(receiver(early) == str)
    }

    @Test func narrowingAfterLoopsAndBranchesJoins() {
        let src = "def f(c):\n    if c:\n        x = 'a'\n    else:\n        x = 1\n    x.|"
        #expect(receiver(src).widened == .union([str, int]))
        let list = Inference(src).names ?? []
        #expect(!list.contains("upper") && !list.contains("bit_length"))
        #expect(list.contains("__str__"))
    }

    @Test func matchClassPattern() {
        let src = "class A:\n    def a(self): pass\ndef f(v):\n    match v:\n        case A():\n            v.|"
        #expect(receiver(src) == .instance(.document("A"), []))
    }
}

// MARK: - Precision and incomplete code

@Suite("TypeInference precision")
@MainActor
struct TypeInferencePrecisionTests {
    @Test func unknownReceiversGiveNoMembers() {
        #expect(names("def f(obj):\n    obj.|") == nil)
        #expect(names("x = undefined_thing()\nx.|") == nil)
        #expect(names("from mypkg import thing\nthing.|") == nil)
    }

    @Test func unionListsOnlySharedMembers() throws {
        let list = try #require(names("def f(v: int | str):\n    v.|"))
        #expect(!list.contains("upper") && !list.contains("bit_length"))
        #expect(list.contains("__add__"))
        let docs = """
        class Order:
            def __init__(self):
                self.id = 1
                self.total = 2
        class User:
            def __init__(self):
                self.id = 1
                self.email = ""
        def f(x: Order | User):
            x.|
        """
        let shared = try #require(names(docs))
        #expect(shared.contains("id") && !shared.contains("total") && !shared.contains("email"))
    }

    @Test func unionWithUnknownIsUnknown() {
        #expect(names("from mypkg import Thing\ndef f(x: str | Thing):\n    x.|") == nil)
    }

    /// T17.11c: a field assigned from itself used to recurse without bound
    /// (a stack overflow on the main thread).
    @Test func selfReferentialFieldIsBounded() {
        let src = "class A:\n    def __init__(self):\n        self.n = self.n + 1\n        self.m = self.m\nA().n.|"
        #expect(receiver(src) == int)
        #expect(names(src.replacingOccurrences(of: "A().n.|", with: "A().m.|")) == nil)
    }

    @Test func unknownDecoratorMakesTheResultUnknown() {
        let src = "def deco(f): return f\n@deco\ndef make() -> str:\n    return ''\nmake().|"
        #expect(names(src) == nil)
        let known = "import functools\n@functools.lru_cache(maxsize=None)\ndef make() -> str:\n    return ''\nmake().|"
        #expect(receiver(known) == str)
    }

    @Test func incompleteLineStillTypesTheReceiver() {
        // The line being typed ends at the dot.
        #expect(receiver("def f():\n    text = 'hi'\n    text.|\n    other = 1") == .literal(.table("builtins", "str"), "'hi'"))
        // Inside an unclosed call on the caret's line.
        #expect(receiver("def f():\n    text = 'hi'\n    print(text.|") == .literal(.table("builtins", "str"), "'hi'"))
        // An unclosed call above swallows the next lines.
        let swallowed = "def f(data):\n    result = compute(data,\n    text = \"hi\"\n    text.|"
        #expect(receiver(swallowed).widened == str)
        // A missing colon.
        #expect(receiver("def f(name: str)\n    name.|") == str)
    }

    @Test func noMemberNodeInStringsAndComments() {
        #expect(names("x = 'abc'\ny = \"x.|\"") == nil)
        #expect(names("x = 'abc'\n# x.|") == nil)
    }

    @Test func fStringInterpolationIsCode() {
        #expect(receiver("name = 'a'\nprint(f\"{name.|}\")") == .literal(.table("builtins", "str"), "'a'"))
    }
}

// MARK: - Summaries

@Suite("TypeInference summaries")
@MainActor
struct TypeInferenceSummaryTests {
    @Test func tableMethodSummary() throws {
        let i = Inference("s = 'a'\ns.|")
        let split = try #require(i.detail("split"))
        #expect(split == "(sep: str | None = ..., maxsplit: SupportsIndex = ...) -> list[str]"
                || split.hasSuffix("-> list[str]"))
        #expect(i.detail("upper") == "() -> str")
    }

    @Test func genericArgumentsAreSubstituted() throws {
        let i = Inference("def f(xs: list[str]):\n    xs.|")
        #expect(i.detail("append") == "(object: str) -> None")
        #expect(i.detail("pop")?.hasSuffix("-> str") == true)
    }

    @Test func documentSignature() throws {
        let src = "class C:\n    def run(self, n: int, *, label: str = 'x') -> bool:\n        return True\nC().|"
        #expect(Inference(src).detail("run") == "(n: int, *, label: str = 'x') -> bool")
        let inferred = "class C:\n    def name(self):\n        return 'n'\nC().|"
        #expect(Inference(inferred).detail("name") == "() -> str")
    }

    @Test func longSummariesKeepTheReturnType() {
        let long = "(first_argument: dict[str, list[int]], second_argument: tuple[int, ...] = ...) -> list[str]"
        let short = InferredMemberList.shortened(long)
        #expect(short.utf16.count <= InferredMemberList.detailLimit + 1)
        #expect(short.hasSuffix(") -> list[str]") && short.hasPrefix("("))
        #expect(InferredMemberList.shortened("() -> int") == "() -> int")
    }

    @Test func moduleMemberSummaries() throws {
        let i = Inference("import os.path\nos.path.|")
        let join = try #require(i.detail("join"))
        #expect(join.hasPrefix("(a: ") && join.contains(" -> "))
        let kinds = try #require(i.candidates)
        #expect(kinds.first { $0.name == "join" }?.kind == .function)
    }
}

// MARK: - Caches, release and the large-document path

@Suite("TypeInference caches", .serialized)
@MainActor
struct TypeInferenceCacheTests {
    @Test func byteLRUBoundsBytesAndCount() {
        let lru = ByteLRU<Int, String>(byteLimit: 100, countLimit: 3)
        for k in 0..<10 { lru.insert("v\(k)", for: k, cost: 30) }
        #expect(lru.count <= 3 && lru.bytes <= 100)
        #expect(lru.value(for: 9) == "v9" && lru.value(for: 0) == nil)
        _ = lru.value(for: 7)
        lru.insert("x", for: 10, cost: 30)
        #expect(lru.value(for: 7) != nil)        // recently used survives
        lru.insert("huge", for: 11, cost: 1_000)  // larger than the cap: not kept
        #expect(lru.value(for: 11) == nil)
        lru.removeAll()
        #expect(lru.isEmpty && lru.bytes == 0)
    }

    @Test func tablesCachesAreBoundedAndReleased() {
        let tables = PythonTypeTables(store: TypeTableStore(), typeCacheBytes: 16 * 1024, memberCacheBytes: 32 * 1024)
        let i = Inference("s = 'a'\ns.|\nimport os\n", tables: tables)
        #expect(i.names?.contains("upper") == true)
        let j = Inference("import os\nos.|", tables: tables)
        #expect(j.names?.contains("getcwd") == true)
        #expect(tables.retainedBytes <= 16 * 1024 + 32 * 1024 + 16 * 1024)
        tables.release()
        #expect(tables.isReleased)
        #expect(tables.store.statistics.mappedFiles == 0)
    }

    @Test func returnTypesAreCachedAcrossVersionsAndValidated() {
        let src = "def make():\n    return 'x'\ndef use():\n    make().|"
        let i = Inference(src)
        #expect(i.receiver == str)
        _ = i.names
        let first = i.service.statistics
        #expect(first.returnInferences >= 1)
        // An edit elsewhere (a new version): the cached return type is reused.
        i.textView.textStorage?.replaceCharacters(in: NSRange(location: i.text.length, length: 0), with: "\n# end")
        i.service.noteEdit(editedRange: NSRange(location: i.text.length - 6, length: 6), changeInLength: 6)
        i.service.noteEdit(editedRange: NSRange(location: 0, length: 0), changeInLength: 0)   // a fresh request
        _ = i.names
        #expect(i.service.statistics.returnCacheHits > first.returnCacheHits)
        // Changing the function invalidates it.
        let at = i.text.range(of: "'x'")
        i.textView.textStorage?.replaceCharacters(in: at, with: "123")   // same length: the caret stays
        i.service.noteEdit(editedRange: NSRange(location: at.location, length: 3), changeInLength: 0)
        #expect(i.candidates?.contains { $0.name == "bit_length" } == true)
        i.service.release()
        #expect(i.service.isReleased)
    }

    @Test func reuseWhileTypingAfterTheSameDot() {
        let i = Inference("s = 'a'\ns.|")
        _ = i.names
        i.textView.textStorage?.replaceCharacters(in: NSRange(location: i.caret, length: 0), with: "up")
        // The text storage reports the whole line as edited.
        i.service.noteEdit(editedRange: NSRange(location: i.caret - 2, length: 4), changeInLength: 2)
        let before = i.service.statistics.reused
        _ = i.service.memberCandidates(analysis: i.analysis, text: i.text, dot: i.dot)
        #expect(i.service.statistics.reused == before + 1)
        // An edit before the dot drops it.
        i.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "#\n")
        i.service.noteEdit(editedRange: NSRange(location: 0, length: 2), changeInLength: 2)
        _ = i.service.memberCandidates(analysis: i.analysis, text: i.text, dot: i.dot + 2)
        #expect(i.service.statistics.reused == before + 1)
    }

    @Test func exhaustedBudgetGivesNoMembers() {
        let i = Inference("s = 'a'\ns.|")
        i.service.budgetSteps = 3
        #expect(i.candidates == nil)
        #expect(i.service.statistics.aborted == 1)
        // Not retried while the caret stays after the same dot.
        #expect(i.candidates == nil)
        #expect(i.service.statistics.aborted == 1 && i.service.statistics.reused == 1)
        let slow = Inference("s = 'a'\ns.|")
        slow.service.budgetMilliseconds = 0
        #expect(slow.candidates == nil)
        #expect(slow.service.statistics.aborted == 1)
    }

    @Test func largeDocumentUsesTheSummary() throws {
        var body = ""
        var k = 0
        while body.utf16.count < SyntaxBuild.fullTreeUnitLimit + 64 * 1024 {
            body += "def helper_\(k)(value: int) -> int:\n    return value + \(k)\n\n"
            k += 1
        }
        let src = "from pathlib import Path\nclass Store:\n    def __init__(self, root: Path):\n        self.root = root\n\n"
            + body + "def use(s: Store):\n    s.root.|\n"
        let i = Inference(src)
        i.service.budgetMilliseconds = 2_000   // debug builds: building the name index takes a while
        #expect(SyntaxBuild.mode(forLength: i.text.length) == .summary)
        // No published summary yet: unknown instead of a full synchronous build.
        #expect(i.candidates == nil)
        #expect(i.service.statistics.skippedLarge == 1)
        _ = i.analysis.ensureSyntax()
        let list = try #require(i.names)
        #expect(list.contains("read_text"))
        #expect(i.analysis.syntax?.summary != nil)
    }
}

// MARK: - Completion wiring

@Suite("TypeInference completion", .serialized)
@MainActor
struct TypeInferenceCompletionTests {
    @MainActor
    private final class Harness {
        let center = NotificationCenter()
        let settings: ModuleSettings
        let clean: () -> Void
        let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window: NSWindow
        let hub = TextStorageObserverHub()
        let controller: CompletionController

        init(_ text: String) {
            let (defaults, clean) = isolatedDefaults()
            self.clean = clean
            settings = ModuleSettings(defaults: defaults, center: center)
            let scroll = NSScrollView(frame: textView.frame)
            scroll.documentView = textView
            window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            textView.string = text
            textView.textStorage?.delegate = hub
            controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center,
                                              scheduler: AnalysisScheduler())
            hub.add(controller)
            textView.completionKeyHandler = controller
            controller.labelLanguageOverride = .en
            controller.setLanguage(identifier: "python")
            controller.indexDocument()
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }

        func type(_ s: String) {
            for ch in s {
                let key = String(ch)
                textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: key,
                                             charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
                controller.textViewDidInsertKey(event)
            }
        }

        func close() {
            controller.dismissCompletion()
            textView.textStorage?.delegate = nil
            window.close()
            clean()
        }
    }

    @Test func memberPopupShowsInferredMembersWithSummaries() throws {
        let h = Harness("words = 'upgrade update'\nname = 'abc'\n")
        defer { h.close() }
        h.type("name.up")
        let candidates = h.controller.currentCandidatesForTesting
        #expect(candidates.first?.name == "upper")
        #expect(candidates.allSatisfy { $0.source == .inferredType })   // no document words (`upgrade`, `update`)
        let cell = try #require(h.controller.cellForTesting(row: 0))
        #expect(cell.content?.detail == "() -> str")
        #expect(cell.accessibilityLabel() == "upper, member, () -> str")
        let width = h.controller.panelForTesting?.frame.width ?? 0
        #expect(width >= CompletionListMetrics.minimumWidth && width <= CompletionListMetrics.maximumWidth)
    }

    @Test func unknownReceiverKeepsUsageEvidence() {
        let h = Harness("def f(obj):\n    obj.render()\n    ")
        defer { h.close() }
        h.type("obj.")
        #expect(h.controller.currentSuggestionsForTesting == ["render"])
        #expect(h.controller.currentCandidatesForTesting.first?.source == .receiverUsage)
    }

    @Test func turningModulesOffReleasesInference() {
        let h = Harness("name = 'abc'\n")
        defer { h.close() }
        h.type("name.")
        #expect(!h.controller.isInferenceStateReleased)
        #expect(!PythonTypeTables.shared.isReleased)
        h.settings.setEnabled(false, for: .typeInference)
        #expect(h.controller.isInferenceStateReleased)
        #expect(PythonTypeTables.shared.isReleased)
        #expect(h.controller.analysis.syntax == nil)
        h.settings.setEnabled(true, for: .typeInference)
        h.type("\nname.")
        #expect(!h.controller.isInferenceStateReleased)
        h.settings.setEnabled(false, for: .completion)
        #expect(h.controller.isRuntimeStateReleased)
        #expect(h.controller.isInferenceStateReleased)
    }

    @Test func typeInferenceOffFallsBackToUsage() {
        let h = Harness("name = 'abc'\nname.strip()\n")
        defer { h.close() }
        h.settings.setEnabled(false, for: .typeInference)
        h.type("name.")
        #expect(h.controller.currentSuggestionsForTesting == ["strip"])
        #expect(h.controller.isInferenceStateReleased)
    }

    @Test func languageChangeDropsInference() {
        let h = Harness("name = 'abc'\n")
        defer { h.close() }
        h.type("name.")
        #expect(!h.controller.isInferenceStateReleased)
        h.controller.setLanguage(identifier: "javascript")
        #expect(h.controller.isInferenceStateReleased)
    }
}

// MARK: - Screenshots (opt-in)

/// `KARU_T1711B_SHOTS=<dir> swift test --filter TypeInferenceScreenshots`
/// renders the member popup with signature summaries over the editor in
/// light / dark and zh-Hans / en (as T17.6's `CompletionScreenshots`).
@MainActor
@Suite("TypeInferenceScreenshots", .serialized)
struct TypeInferenceScreenshots {
    @Test func render() throws {
        guard let dir = ProcessInfo.processInfo.environment["KARU_T1711B_SHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let source = """
        from dataclasses import dataclass


        @dataclass
        class Invoice:
            label: str
            amount: float = 0.0

            def total(self, tax: float = 0.1, *, rounded: bool = True) -> float:
                return self.amount * (1 + tax)


        def render(invoice: Invoice, title: str):
            title = title.strip()

        """
        for (typed, shot) in [("    invoice.", "members"), ("    title.s", "str")] {
        for (appearance, look) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for language in [AppLanguage.zhHans, .en] {
                let (defaults, clean) = isolatedDefaults()
                defer { clean() }
                let center = NotificationCenter()
                let settings = ModuleSettings(defaults: defaults, center: center)
                let size = NSSize(width: 640, height: 300)
                let frame = NSRect(origin: .zero, size: size)
                let scroll = NSScrollView(frame: frame)
                let textView = EditorTextView(frame: frame)
                textView.isRichText = false
                textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                scroll.documentView = textView
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = scroll
                window.appearance = NSAppearance(named: appearance)
                textView.string = source
                let hub = TextStorageObserverHub()
                textView.textStorage?.delegate = hub
                let controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center,
                                                      scheduler: AnalysisScheduler())
                hub.add(controller)
                textView.completionKeyHandler = controller
                controller.labelLanguageOverride = language
                controller.setLanguage(identifier: "python")
                controller.indexDocument()
                window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
                for ch in typed {
                    let key = String(ch)
                    textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, characters: key,
                                                 charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
                    controller.textViewDidInsertKey(event)
                }
                let panel = try #require(controller.panelForTesting)
                panel.appearance = NSAppearance(named: appearance)
                controller.selectRowForTesting(1)
                panel.contentView?.layoutSubtreeIfNeeded()
                let content = try #require(window.contentView)
                content.layoutSubtreeIfNeeded()
                func bitmap(_ view: NSView) -> NSBitmapImageRep {
                    var rep: NSBitmapImageRep!
                    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                        rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        view.cacheDisplay(in: view.bounds, to: rep)
                    }
                    return rep
                }
                let editor = bitmap(content)
                let popup = bitmap(try #require(panel.contentView))
                let panelInWindow = window.convertFromScreen(panel.frame)
                let scale: CGFloat = 2
                let canvas = try #require(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                canvas.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    NSColor.textBackgroundColor.setFill()
                    NSRect(origin: .zero, size: size).fill()
                }
                editor.draw(in: NSRect(origin: .zero, size: size))
                popup.draw(in: panelInWindow)
                NSGraphicsContext.restoreGraphicsState()
                let png = try #require(canvas.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(shot)-\(look)-\(language.rawValue).png"))
                controller.dismissCompletion()
                textView.textStorage?.delegate = nil
                window.close()
            }
        }
        }
    }
}
