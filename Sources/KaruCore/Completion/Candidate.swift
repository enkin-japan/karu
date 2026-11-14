import Foundation

// M17 T17.5 — the completion candidate model (plan §5.2): pure values, no
// AppKit, `Sendable`, shared by `CandidateEngine` and `CompletionController`
// (T17.6 builds labels, widths and match highlighting on these fields).

/// What a candidate names.
public enum CandidateKind: String, Sendable, CaseIterable {
    case parameter, local, member, method, function, type, variable, property, module, keyword, builtin, word

    /// Kinds that share an identity (`CandidateIdentity`).
    public enum Group: UInt8, Sendable, Hashable {
        case value, callable, type, keyword, module
    }

    public var group: Group {
        switch self {
        case .parameter, .local, .member, .variable, .property, .word: return .value
        case .method, .function, .builtin: return .callable
        case .type: return .type
        case .keyword: return .keyword
        case .module: return .module
        }
    }

    /// The candidate kind of a declaration; `scoped`: a non-module binding.
    static func from(_ kind: DeclarationScan.DeclarationKind, scoped: Bool) -> CandidateKind {
        switch kind {
        case .function: return .function
        case .method: return .method
        case .class, .type: return .type
        case .parameter: return .parameter
        case .import: return .module
        case .property: return .property
        case .variable, .functionScopedVariable, .global, .nonlocal: return scoped ? .local : .variable
        }
    }

    /// The candidate kind of a class member.
    static func member(_ kind: DeclarationScan.DeclarationKind) -> CandidateKind {
        switch kind {
        case .function, .method: return .method
        case .class, .type: return .type
        default: return .property
        }
    }
}

/// Where a candidate comes from, in ranking order (plan §5.3 step 3). The
/// reserved sources are seams for T17.12–13 (imports) and T17.14 (workspace
/// index); nothing produces them yet.
public enum CandidateSource: UInt8, Sendable, CaseIterable, Comparable {
    /// A binding visible in the current scope chain (current function first).
    case scope
    /// A member of the receiver's inferred type (T17.11).
    case inferredType
    /// A member of the enclosing class (`self.` / `this.`).
    case selfMember
    /// `obj.name` seen earlier in the current scope for the same receiver.
    case receiverUsage
    /// Usage evidence from before the receiver was last rebound (lower
    /// confidence).
    case staleReceiverUsage
    /// A module-level declaration of this file.
    case fileDeclaration
    /// Reserved: an imported module's export (T17.12–13).
    case importedModule
    /// Reserved: another file of the workspace (T17.14).
    case workspace
    /// A keyword or builtin of the language.
    case keyword
    /// A word of the document (any text, including comments and strings).
    case documentWord

    /// Ranking group: lower ranks first; self / this members and usage
    /// evidence share one group.
    public var rank: Int {
        switch self {
        case .scope: return 0
        case .inferredType: return 1
        case .selfMember, .receiverUsage: return 2
        case .staleReceiverUsage: return 3
        case .fileDeclaration: return 4
        case .importedModule: return 5
        case .workspace: return 6
        case .keyword: return 7
        case .documentWord: return 8
        }
    }

    public static func < (lhs: CandidateSource, rhs: CandidateSource) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Match quality (plan §5.3 step 2), best first.
public enum MatchTier: UInt8, Sendable, Comparable {
    /// The name starts with the typed prefix, same case.
    case exactPrefix
    /// The name starts with the prefix ignoring case.
    case caseInsensitivePrefix
    /// The prefix's characters begin consecutive word parts (camelCase
    /// humps, `_` / `-` separated parts, digit runs): `udn` → `userDisplayName`.
    case wordStart
    /// Bounded loose match: the first character at a word start, the rest an
    /// ordered subsequence (bounded sources only).
    case fuzzy

    public static func < (lhs: MatchTier, rhs: MatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A candidate's stable, source-independent identity: its spelling and kind
/// group (T17.6 keeps the user's selection by identity across refreshes).
public struct CandidateIdentity: Hashable, Sendable {
    public let name: String
    public let group: CandidateKind.Group

    public init(name: String, group: CandidateKind.Group) {
        self.name = name
        self.group = group
    }
}

/// One completion candidate.
public struct Candidate: Sendable, Equatable {
    /// Original spelling (what the list shows).
    public let name: String
    /// Text that replaces the whole identifier at the caret on accept.
    public var insertText: String
    public var kind: CandidateKind
    /// The best-ranked source.
    public var source: CandidateSource
    /// Every source that produced this spelling, best first.
    public var sources: [CandidateSource]
    public var matchTier: MatchTier
    /// UTF-16 ranges within `name` the typed prefix matched.
    public var matchedRanges: [NSRange]
    /// Scope depth of a `scope` candidate (0 = innermost scope).
    public var scopeDepth: Int?
    /// Live-text location of the declaration / usage it came from, when known.
    public var location: Int?
    /// Distance in UTF-16 units from the caret to its nearest use within the
    /// current function or ±2 KB (plan §5.3 step 4).
    public var nearbyDistance: Int?
    /// Position in the recent-accept list (0 = most recent).
    public var recentRank: Int?
    /// Signature summary or type of an inferred member (T17.11, plan §5.5),
    /// shown after the category label.
    public var detail: String?

    public var identity: CandidateIdentity { CandidateIdentity(name: name, group: kind.group) }

    public init(name: String, kind: CandidateKind, source: CandidateSource, matchTier: MatchTier = .exactPrefix,
                matchedRanges: [NSRange] = [], scopeDepth: Int? = nil, location: Int? = nil) {
        self.name = name
        self.insertText = name
        self.kind = kind
        self.source = source
        self.sources = [source]
        self.matchTier = matchTier
        self.matchedRanges = matchedRanges
        self.scopeDepth = scopeDepth
        self.location = location
    }
}

/// Recently accepted candidates of one window (plan §3: at most 32, dropped
/// with the window), most recent first.
public struct RecentAccepts: Sendable, Equatable {
    public static let capacity = 32
    public private(set) var entries: [CandidateIdentity] = []

    public init() {}

    public mutating func record(_ identity: CandidateIdentity) {
        entries.removeAll { $0 == identity }
        entries.insert(identity, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    public mutating func removeAll() { entries.removeAll() }

    /// 0 = most recently accepted; nil when not in the list.
    public func rank(of identity: CandidateIdentity) -> Int? {
        entries.firstIndex(of: identity)
    }
}
