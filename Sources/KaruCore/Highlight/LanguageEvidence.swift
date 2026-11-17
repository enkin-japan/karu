import Foundation

// Evidence tables for LanguageSniffer.rank: the languages that compete, the
// features the line scanner reports, and what each feature is worth.
//
// A feature is a syntax fact (a declaration shape, a keyword in statement
// position, an operator, a comment or block style). Each one carries a cap on
// how many occurrences count, so one repeated feature cannot win alone, and a
// set of per-language weights; negative weights record syntax that a language
// does not have (`;` line ends for Python, `:=` for anything but Go, …).

/// The languages that compete for a sample. Close families compete as one
/// entry and are refined afterwards: `.c` becomes C or C++, `.javascript`
/// becomes JavaScript, TypeScript or TypeScript JSX. The declaration order is
/// the fixed tie-break order.
enum SniffLanguage: Int, CaseIterable {
    case python, javascript, java, csharp, c, go, rust, swift, bash, sql
    case html, xml, css, json, yaml, toml, markdown

    /// Score needed before the language is set without asking.
    var confidentThreshold: Double {
        switch self {
        case .yaml: return 9
        case .toml: return 7
        case .css: return 6
        case .markdown, .sql: return 5
        case .go, .rust: return 5.5
        case .javascript: return 4
        default: return 5
        }
    }

    /// Score needed to be offered as a candidate.
    var candidateThreshold: Double {
        switch self {
        case .yaml, .toml, .markdown, .sql: return 4
        default: return 3
        }
    }
}

/// Features reported by the line scanner. Weights and caps live in `effect`.
enum SniffFeature: Int, CaseIterable {
    // Generic block / statement shape.
    case semicolonEnd, braceOpenEnd, closeBraceLine, allmanBrace, braceSemicolon
    case ifParen, ifBare, whileBare, returnSemi, returnBare
    case slashComment, cBlockComment, hashComment, proseLine, tabIndent
    case fatArrow, nilToken, printCall, selfDot, bareAssign, annotationLine
    case braceClass, interfaceDecl, enumDecl, pascalCall, forInBrace

    // Python
    case pyDef, pyClass, pyBlock, pyElif, pyImport, pyFromImport, pyKeywordLine, pyConstant
    case pyFString, pyDunder, pyComprehension, pyTupleAssign, pyIndentedBody, pyDocstring

    // JavaScript / TypeScript / JSX
    case jsConst, letSemi, letBare, varSemi, varBare, jsFunction, jsStrictEq, jsGlobals, jsRequire
    case jsImport, jsExport, jsTemplate, jsUndefined, jsConstructor, jsMethod, jsForOf, jsArrowDecl
    case jsObjectLiteral, jsUseStrict
    case tsPrimAnnotation, tsReturnType, tsInterface, tsTypeAlias, tsAsConst, tsGenericFunction
    case tsImportType, tsMember, tsOptionalParam, tsGenericAnnotation
    case jsxAttr, jsxComponent

    // Java
    case javaPackage, javaImportJava, javaImport, javaMain, javaPrint, javaMethod, javaField
    case javaClassDecl, javaOverride, javaDiamond, enhancedFor, javaStringType, javaThrows, javaLambda
    case accessClassDecl, extendsImplements, javaStaticFinal

    // C#
    case csUsing, csUsingSystem, csNamespace, csFileNamespace, csProperty, csConsole, csInterp
    case csMain, csVerbatim, csForeach, csTask, csTypeFirst, csDirective, csMethod, csField, csClassDecl

    // C / C++
    case cInclude, cPreproc, cStdCall, cPtrArrow, cStruct, cTypedef, cNull, cPointerDecl, cFuncDef
    case cMain, cTypedDecl
    case cppHeader, cppStd, cppUsingNamespace, cppTemplate, cppAccess, cppStream, cppNullptr, cppAuto
    case cppKeyword, cppNamespace, cppRangeFor

    // Go
    case goPackage, goFunc, goMethod, funcEmpty, goColonEq, goErrNil, goFmt, goTypeDecl, goImport
    case goTypes, deferStmt, goRange, goVarTyped

    // Rust
    case rustFn, rustImpl, rustUse, rustMacro, rustRef, rustTypes, rustAttr, rustMatch, rustEnumCtor
    case rustTry, rustClosure, rustLoop, rustPub, rustLetMut, rustPathCall, rustIfLet, matchArm

    // Swift
    case swiftFunc, swiftGuard, swiftIfLet, swiftTypedBinding, swiftInterp, swiftExtProto
    case swiftConformance, swiftAttribute, swiftDecl, swiftClosureArg, swiftOptionalCast
    case swiftImport, swiftFrameworkImport

    // Bash
    case bashIf, bashKeyword, bashFor, bashCase, bashVar, bashSubst, bashCommand, bashAssign
    case bashFuncDef, bashRedirect, bashTest, bashChain, bashFunctionKeyword

    // SQL
    case sqlKeywordUpper, sqlKeywordLower, sqlStructure, sqlComment, sqlColumn

    // CSS
    case cssSelector, cssAtRule, cssProperty, cssValue, cssCustomProp, cssImportant

    // HTML / XML
    case htmlTag, xmlTag, xmlDecl, xmlCData, xmlNamespace, markupAttr, markupComment, entity

    // JSON
    case jsonKeyLine, jsonBraceLine, nonJSONLine

    // YAML
    case yamlKV, yamlKVWeak, yamlParent, yamlNested, yamlListMap, dashItem, yamlDocStart, yamlAnchor
    case yamlBlockScalar, yamlFlowValue

    // TOML
    case tomlHeader, tomlKV, tomlBadValue

    // Markdown
    case mdFence, mdHeading, mdHeadingDeep, mdLink, mdEmphasis, mdInlineCode, mdTable, mdTableRow
    case mdQuote, mdTask, numberedItem, mdSetext
}

typealias SniffWeights = [(SniffLanguage, Double)]

extension SniffFeature {
    /// How many occurrences count, and what each is worth per language.
    var effect: (cap: Int, weights: SniffWeights) {
        switch self {
        // Generic shape
        case .semicolonEnd:
            return (8, [(.c, 0.3), (.java, 0.3), (.csharp, 0.3), (.javascript, 0.2), (.rust, 0.2), (.sql, 0.3),
                        (.python, -0.6), (.swift, -0.4), (.go, -0.6), (.yaml, -0.6), (.toml, -0.6),
                        (.markdown, -0.5), (.bash, -0.2), (.json, -0.5)])
        case .braceOpenEnd:
            return (6, [(.c, 0.2), (.java, 0.2), (.csharp, 0.2), (.javascript, 0.2), (.go, 0.2), (.rust, 0.2),
                        (.swift, 0.2), (.css, 0.1), (.yaml, -0.6), (.toml, -0.6), (.markdown, -0.5), (.sql, -0.5)])
        case .closeBraceLine:
            return (6, [(.c, 0.1), (.java, 0.1), (.csharp, 0.1), (.javascript, 0.1), (.go, 0.1), (.rust, 0.1),
                        (.swift, 0.1), (.css, 0.1), (.python, -0.4), (.yaml, -0.5), (.toml, -0.5),
                        (.markdown, -0.5), (.sql, -0.3)])
        case .allmanBrace:
            return (3, [(.csharp, 0.8), (.c, 0.3), (.python, -0.4)])
        case .braceSemicolon:
            return (2, [(.c, 0.8), (.javascript, 0.3), (.csharp, 0.2), (.python, -0.5)])
        case .ifParen:
            return (4, [(.c, 0.3), (.java, 0.3), (.csharp, 0.3), (.javascript, 0.3), (.go, -0.6), (.rust, -0.4),
                        (.python, -0.6), (.swift, -0.2)])
        case .ifBare:
            return (4, [(.go, 0.6), (.rust, 0.6), (.swift, 0.6), (.c, -0.3), (.java, -0.3), (.csharp, -0.3),
                        (.javascript, -0.3)])
        case .whileBare:
            return (3, [(.rust, 0.6), (.swift, 0.6), (.go, -1)])
        case .returnSemi:
            return (4, [(.c, 0.2), (.java, 0.2), (.csharp, 0.2), (.javascript, 0.2), (.python, -0.3)])
        case .returnBare:
            return (4, [(.python, 0.2), (.go, 0.2), (.swift, 0.2), (.rust, 0.2)])
        case .slashComment:
            return (4, [(.c, 0.3), (.java, 0.3), (.csharp, 0.3), (.javascript, 0.3), (.go, 0.3), (.rust, 0.3),
                        (.swift, 0.3), (.python, -0.6), (.bash, -0.6), (.yaml, -0.6), (.toml, -0.6),
                        (.sql, -0.5), (.css, -0.3), (.markdown, -0.3), (.html, -0.5), (.xml, -0.5)])
        case .cBlockComment:
            return (4, [(.c, 0.2), (.java, 0.2), (.csharp, 0.2), (.javascript, 0.2), (.go, 0.2), (.rust, 0.2),
                        (.swift, 0.2), (.css, 0.2), (.sql, 0.1), (.python, -0.4), (.bash, -0.4), (.yaml, -0.5),
                        (.toml, -0.5)])
        case .hashComment:
            return (4, [(.python, 0.3), (.bash, 0.4), (.yaml, 0.3), (.toml, 0.3), (.c, -0.3), (.java, -0.3),
                        (.csharp, -0.2), (.javascript, -0.3), (.go, -0.3), (.rust, -0.3), (.swift, -0.3)])
        case .proseLine:
            return (40, [(.python, -0.7), (.javascript, -0.7), (.java, -0.7), (.csharp, -0.7), (.c, -0.7),
                         (.go, -0.7), (.rust, -0.7), (.swift, -0.7), (.bash, -0.7), (.sql, -0.7),
                         (.html, -0.5), (.xml, -0.5), (.css, -0.7), (.json, -0.7), (.yaml, -0.7),
                         (.toml, -0.7), (.markdown, 0.2)])
        case .tabIndent:
            return (5, [(.go, 0.3)])
        case .fatArrow:
            return (3, [(.javascript, 0.8), (.csharp, 0.4)])
        case .nilToken:
            return (3, [(.go, 0.4), (.swift, 0.4)])
        case .printCall:
            return (2, [(.python, 0.5), (.swift, 0.5)])
        case .selfDot:
            return (3, [(.python, 0.4), (.swift, 0.2), (.rust, 0.1)])
        case .bareAssign:
            return (4, [(.python, 0.4)])
        case .annotationLine:
            return (2, [(.java, 1), (.python, 0.8), (.javascript, 0.3)])
        case .braceClass:
            return (2, [(.java, 1), (.csharp, 1), (.javascript, 0.8), (.swift, 0.5), (.c, 0.5),
                        (.python, -1)])
        case .interfaceDecl:
            return (2, [(.java, 1.5), (.csharp, 1.5)])
        case .enumDecl:
            return (2, [(.java, 0.5), (.csharp, 0.5), (.rust, 0.5), (.swift, 0.5), (.javascript, 0.5), (.c, 0.5)])
        case .pascalCall:
            return (3, [(.csharp, 0.5), (.go, 0.4)])
        case .forInBrace:
            return (3, [(.rust, 0.8), (.swift, 0.8)])

        // Python
        case .pyDef:
            return (3, [(.python, 3.5), (.swift, -2), (.javascript, -1), (.rust, -1), (.go, -1), (.yaml, -1)])
        case .pyClass:
            return (2, [(.python, 3), (.swift, -1), (.yaml, -1)])
        case .pyBlock:
            return (5, [(.python, 1.5), (.yaml, -0.8)])
        case .pyElif:
            return (2, [(.python, 2)])
        case .pyImport:
            return (3, [(.python, 1.5)])
        case .pyFromImport:
            return (3, [(.python, 4), (.javascript, -1)])
        case .pyKeywordLine:
            return (3, [(.python, 1.5)])
        case .pyConstant:
            return (3, [(.python, 0.8), (.json, -1)])
        case .pyFString:
            return (2, [(.python, 2)])
        case .pyDunder:
            return (2, [(.python, 2)])
        case .pyComprehension:
            return (2, [(.python, 2.5)])
        case .pyTupleAssign:
            return (2, [(.python, 1), (.go, 0.3)])
        case .pyIndentedBody:
            return (4, [(.python, 0.8)])
        case .pyDocstring:
            return (2, [(.python, 1)])

        // JavaScript / TypeScript
        case .jsConst:
            return (4, [(.javascript, 2), (.go, 1)])
        case .jsObjectLiteral:
            return (2, [(.javascript, 1.5)])
        case .jsUseStrict:
            return (1, [(.javascript, 4)])
        case .letSemi:
            return (4, [(.javascript, 1), (.rust, 0.8)])
        case .letBare:
            return (4, [(.swift, 1), (.javascript, 0.8)])
        case .varSemi:
            return (4, [(.javascript, 0.8), (.csharp, 0.8), (.java, 0.3)])
        case .varBare:
            return (4, [(.swift, 1), (.javascript, 0.5), (.go, 0.5)])
        case .jsFunction:
            return (3, [(.javascript, 3), (.bash, 0.3)])
        case .jsStrictEq:
            return (3, [(.javascript, 2.5)])
        case .jsGlobals:
            return (3, [(.javascript, 2)])
        case .jsRequire:
            return (3, [(.javascript, 3)])
        case .jsImport:
            return (3, [(.javascript, 3), (.python, -1)])
        case .jsExport:
            return (3, [(.javascript, 2.5)])
        case .jsTemplate:
            return (3, [(.javascript, 2), (.bash, -0.5)])
        case .jsUndefined:
            return (2, [(.javascript, 2)])
        case .jsConstructor:
            return (1, [(.javascript, 3)])
        case .jsMethod:
            return (4, [(.javascript, 1.2)])
        case .jsForOf:
            return (2, [(.javascript, 2.5)])
        case .jsArrowDecl:
            return (3, [(.javascript, 2)])
        case .tsPrimAnnotation:
            return (4, [(.javascript, 2)])
        case .tsReturnType:
            return (3, [(.javascript, 2)])
        case .tsInterface:
            return (2, [(.javascript, 3)])
        case .tsTypeAlias:
            return (2, [(.javascript, 3), (.go, 0.3)])
        case .tsAsConst:
            return (1, [(.javascript, 3)])
        case .tsGenericFunction:
            return (2, [(.javascript, 3)])
        case .tsImportType:
            return (2, [(.javascript, 3)])
        case .tsMember:
            return (3, [(.javascript, 2)])
        case .tsOptionalParam:
            return (2, [(.javascript, 1.5)])
        case .tsGenericAnnotation:
            return (3, [(.javascript, 1.2), (.swift, 0.4)])
        case .jsxAttr:
            return (3, [(.javascript, 2), (.html, -1.5)])
        case .jsxComponent:
            return (3, [(.javascript, 1), (.html, -0.5)])

        // Java
        case .javaPackage:
            return (1, [(.java, 3.5)])
        case .javaImportJava:
            return (3, [(.java, 5)])
        case .javaImport:
            return (3, [(.java, 2.5)])
        case .javaMain:
            return (1, [(.java, 5)])
        case .javaPrint:
            return (2, [(.java, 4)])
        case .javaMethod:
            return (4, [(.java, 2), (.csharp, 0.5), (.c, -1)])
        case .javaField:
            return (3, [(.java, 1.5), (.c, -0.5)])
        case .javaClassDecl:
            return (2, [(.java, 2.5), (.c, -1)])
        case .javaOverride:
            return (2, [(.java, 3)])
        case .javaDiamond:
            return (2, [(.java, 3)])
        case .enhancedFor:
            return (2, [(.java, 1.5), (.c, 1)])
        case .javaStringType:
            return (3, [(.java, 1.5)])
        case .javaThrows:
            return (2, [(.java, 3)])
        case .javaLambda:
            return (2, [(.java, 1.5)])
        case .accessClassDecl:
            return (2, [(.java, 1.5), (.csharp, 1.5), (.c, -1)])
        case .javaStaticFinal:
            return (2, [(.java, 2)])
        case .extendsImplements:
            return (2, [(.java, 1), (.javascript, 0.5)])

        // C#
        case .csUsing:
            return (3, [(.csharp, 3)])
        case .csUsingSystem:
            return (1, [(.csharp, 2)])
        case .csNamespace:
            return (1, [(.csharp, 2), (.c, 0.5), (.javascript, 0.5)])
        case .csFileNamespace:
            return (1, [(.csharp, 3.5)])
        case .csProperty:
            return (3, [(.csharp, 4)])
        case .csConsole:
            return (2, [(.csharp, 4)])
        case .csInterp:
            return (2, [(.csharp, 3)])
        case .csMain:
            return (1, [(.csharp, 4)])
        case .csVerbatim:
            return (2, [(.csharp, 2)])
        case .csForeach:
            return (2, [(.csharp, 3)])
        case .csTask:
            return (2, [(.csharp, 3)])
        case .csTypeFirst:
            return (3, [(.csharp, 1), (.c, 0.4)])
        case .csDirective:
            return (2, [(.csharp, 4)])
        case .csMethod:
            return (4, [(.csharp, 2), (.java, 0.5), (.c, -1)])
        case .csField:
            return (3, [(.csharp, 1.5), (.c, -0.5)])
        case .csClassDecl:
            return (2, [(.csharp, 2.5), (.c, -1)])

        // C / C++
        case .cInclude:
            return (2, [(.c, 5)])
        case .cPreproc:
            return (3, [(.c, 2.5), (.csharp, 0.5)])
        case .cStdCall:
            return (3, [(.c, 2)])
        case .cPtrArrow:
            return (3, [(.c, 1.5)])
        case .cStruct:
            return (2, [(.c, 2), (.go, -0.5)])
        case .cTypedef:
            return (2, [(.c, 3)])
        case .cNull:
            return (2, [(.c, 1.5)])
        case .cPointerDecl:
            return (3, [(.c, 1.5)])
        case .cFuncDef:
            return (3, [(.c, 2.5), (.java, 0.3), (.csharp, 0.3)])
        case .cMain:
            return (1, [(.c, 2)])
        case .cTypedDecl:
            return (4, [(.c, 0.8), (.java, 0.6), (.csharp, 0.6)])
        case .cppHeader:
            return (2, [(.c, 1)])
        case .cppStd:
            return (3, [(.c, 2.5), (.rust, -0.5)])
        case .cppUsingNamespace:
            return (1, [(.c, 3.5)])
        case .cppTemplate:
            return (2, [(.c, 3)])
        case .cppAccess:
            return (2, [(.c, 3)])
        case .cppStream:
            return (2, [(.c, 3)])
        case .cppNullptr:
            return (2, [(.c, 2.5)])
        case .cppAuto:
            return (3, [(.c, 1.5)])
        case .cppKeyword:
            return (3, [(.c, 1.5)])
        case .cppNamespace:
            return (1, [(.c, 2)])
        case .cppRangeFor:
            return (2, [(.c, 2)])

        // Go
        case .goPackage:
            return (1, [(.go, 4)])
        case .goFunc:
            return (3, [(.go, 3), (.swift, -1)])
        case .goMethod:
            return (3, [(.go, 4)])
        case .funcEmpty:
            return (3, [(.go, 1.2), (.swift, 1.2)])
        case .goColonEq:
            return (4, [(.go, 1.5), (.python, -0.5), (.javascript, -0.5), (.swift, -0.5), (.rust, -0.5),
                        (.c, -0.5), (.java, -0.5), (.csharp, -0.5)])
        case .goErrNil:
            return (2, [(.go, 3)])
        case .goFmt:
            return (2, [(.go, 2)])
        case .goTypeDecl:
            return (3, [(.go, 4)])
        case .goImport:
            return (2, [(.go, 3)])
        case .goTypes:
            return (3, [(.go, 1.5)])
        case .deferStmt:
            return (2, [(.go, 1.5), (.swift, 1)])
        case .goRange:
            return (2, [(.go, 2)])
        case .goVarTyped:
            return (3, [(.go, 1.5)])

        // Rust
        case .rustFn:
            return (3, [(.rust, 4)])
        case .rustImpl:
            return (2, [(.rust, 4)])
        case .rustUse:
            return (3, [(.rust, 3.5), (.c, -0.5)])
        case .rustMacro:
            return (3, [(.rust, 2.5)])
        case .rustRef:
            return (3, [(.rust, 1.5)])
        case .rustTypes:
            return (3, [(.rust, 1.5)])
        case .rustAttr:
            return (2, [(.rust, 4)])
        case .rustMatch:
            return (2, [(.rust, 2.5)])
        case .rustEnumCtor:
            return (3, [(.rust, 1)])
        case .rustTry:
            return (3, [(.rust, 1.5)])
        case .rustClosure:
            return (2, [(.rust, 1.5)])
        case .rustLoop:
            return (1, [(.rust, 2)])
        case .rustPub:
            return (3, [(.rust, 1.5)])
        case .rustLetMut:
            return (2, [(.rust, 2)])
        case .rustPathCall:
            return (3, [(.rust, 1), (.c, 0.3)])
        case .rustIfLet:
            return (2, [(.rust, 2.5)])
        case .matchArm:
            return (3, [(.rust, 1)])

        // Swift
        case .swiftFunc:
            return (3, [(.swift, 4), (.go, -1)])
        case .swiftGuard:
            return (2, [(.swift, 4)])
        case .swiftIfLet:
            return (2, [(.swift, 3)])
        case .swiftTypedBinding:
            return (3, [(.swift, 1.5)])
        case .swiftInterp:
            return (2, [(.swift, 3)])
        case .swiftExtProto:
            return (2, [(.swift, 3)])
        case .swiftConformance:
            return (2, [(.swift, 2.5)])
        case .swiftAttribute:
            return (2, [(.swift, 3)])
        case .swiftDecl:
            return (3, [(.swift, 1.5)])
        case .swiftClosureArg:
            return (2, [(.swift, 2.5)])
        case .swiftOptionalCast:
            return (2, [(.swift, 2)])
        case .swiftImport:
            return (2, [(.swift, 2)])
        case .swiftFrameworkImport:
            return (1, [(.swift, 5)])

        // Bash
        case .bashIf:
            return (3, [(.bash, 2.5)])
        case .bashKeyword:
            return (4, [(.bash, 1.2)])
        case .bashFor:
            return (2, [(.bash, 2.5)])
        case .bashCase:
            return (2, [(.bash, 2)])
        case .bashVar:
            return (6, [(.bash, 0.6)])
        case .bashSubst:
            return (3, [(.bash, 1.2)])
        case .bashCommand:
            return (5, [(.bash, 1)])
        case .bashAssign:
            return (3, [(.bash, 1.2)])
        case .bashFuncDef:
            return (2, [(.bash, 1.5)])
        case .bashRedirect:
            return (3, [(.bash, 1.2)])
        case .bashTest:
            return (3, [(.bash, 2)])
        case .bashChain:
            return (3, [(.bash, 0.6)])
        case .bashFunctionKeyword:
            return (2, [(.bash, 2.5)])

        // SQL
        case .sqlKeywordUpper:
            return (8, [(.sql, 1)])
        case .sqlKeywordLower:
            return (6, [(.sql, 0.5)])
        case .sqlStructure:
            return (3, [(.sql, 4.5)])
        case .sqlComment:
            return (2, [(.sql, 1), (.python, -0.3), (.bash, -0.3), (.yaml, -0.3)])
        case .sqlColumn:
            return (4, [(.sql, 1)])

        // CSS
        case .cssSelector:
            return (4, [(.css, 2)])
        case .cssAtRule:
            return (2, [(.css, 3)])
        case .cssProperty:
            return (8, [(.css, 0.8), (.yaml, -0.5)])
        case .cssValue:
            return (6, [(.css, 0.8)])
        case .cssCustomProp:
            return (3, [(.css, 2)])
        case .cssImportant:
            return (2, [(.css, 2)])

        // HTML / XML
        case .htmlTag:
            return (8, [(.html, 1.5), (.xml, 0.3)])
        case .xmlTag:
            return (8, [(.xml, 1.2), (.html, 0.2)])
        case .xmlDecl:
            return (1, [(.xml, 4)])
        case .xmlCData:
            return (2, [(.xml, 2)])
        case .xmlNamespace:
            return (2, [(.xml, 3)])
        case .markupAttr:
            return (4, [(.html, 0.4), (.xml, 0.2)])
        case .markupComment:
            return (2, [(.html, 0.5), (.xml, 0.5), (.markdown, 0.2)])
        case .entity:
            return (2, [(.html, 0.4), (.xml, 0.4)])

        // JSON
        case .jsonKeyLine:
            return (10, [(.json, 1.2), (.yaml, -0.3)])
        case .jsonBraceLine:
            return (4, [(.json, 0.3)])
        case .nonJSONLine:
            return (10, [(.json, -1)])

        // YAML
        case .yamlKV:
            return (10, [(.yaml, 0.8), (.bash, -0.4)])
        case .yamlFlowValue:
            return (3, [(.yaml, 1)])
        case .yamlKVWeak:
            return (6, [(.yaml, 0.2)])
        case .yamlParent:
            return (4, [(.yaml, 1.5)])
        case .yamlNested:
            return (6, [(.yaml, 0.5)])
        case .yamlListMap:
            return (3, [(.yaml, 2), (.bash, -1)])
        case .dashItem:
            return (4, [(.yaml, 0.2), (.markdown, 0.3)])
        case .yamlDocStart:
            return (1, [(.yaml, 2), (.markdown, 0.5)])
        case .yamlAnchor:
            return (2, [(.yaml, 2.5)])
        case .yamlBlockScalar:
            return (2, [(.yaml, 2), (.bash, -1)])

        // TOML
        case .tomlHeader:
            return (3, [(.toml, 3)])
        case .tomlKV:
            return (8, [(.toml, 1), (.python, 0.1)])
        case .tomlBadValue:
            return (6, [(.toml, -1.5)])

        // Markdown
        case .mdFence:
            return (2, [(.markdown, 3)])
        case .mdHeading:
            return (3, [(.markdown, 2)])
        case .mdHeadingDeep:
            return (3, [(.markdown, 3)])
        case .mdLink:
            return (3, [(.markdown, 2)])
        case .mdEmphasis:
            return (2, [(.markdown, 1)])
        case .mdInlineCode:
            return (2, [(.markdown, 1)])
        case .mdTable:
            return (1, [(.markdown, 4)])
        case .mdTableRow:
            return (3, [(.markdown, 0.5)])
        case .mdQuote:
            return (2, [(.markdown, 0.5)])
        case .mdTask:
            return (2, [(.markdown, 1.5)])
        case .numberedItem:
            return (3, [(.markdown, 0.2)])
        case .mdSetext:
            return (1, [(.markdown, 2)])
        }
    }

    /// Features that only C++ has (C++ is the C family's refinement).
    static let cppOnly: [SniffFeature] = [
        .cppHeader, .cppStd, .cppUsingNamespace, .cppTemplate, .cppAccess, .cppStream, .cppNullptr,
        .cppAuto, .cppKeyword, .cppNamespace, .cppRangeFor,
    ]

    /// Type syntax that only TypeScript has, with its weight toward choosing
    /// TypeScript over JavaScript.
    static let typeScriptOnly: [(SniffFeature, Double)] = [
        (.tsPrimAnnotation, 2), (.tsReturnType, 2), (.tsInterface, 3), (.tsTypeAlias, 3), (.tsAsConst, 3),
        (.tsGenericFunction, 3), (.tsImportType, 3), (.tsMember, 2), (.tsOptionalParam, 1),
        (.tsGenericAnnotation, 1),
    ]
}

/// Precomputed effect table indexed by feature raw value.
enum SniffEffects {
    static let table: [(cap: Int, weights: SniffWeights)] = SniffFeature.allCases.map(\.effect)
}
