import Testing
@testable import KaruCore

// T16.3a sniffer rules: shebangs, Go, Rust, Java, C#, C++, Swift, TypeScript —
// positives plus collision / negative cases. Existing rules stay covered by
// LanguageSnifferTests.swift.

@Suite("Language sniffer — code rules")
struct LanguageSnifferCodeRulesTests {
    private func sniff(_ text: String) -> String? { LanguageSniffer.sniff(text) }

    // MARK: Shebangs

    @Test func typeScriptShebangs() {
        #expect(sniff("#!/usr/bin/env ts-node\nconsole.log(1)") == "typescript")
        #expect(sniff("#!/usr/bin/env tsx\nconsole.log(1)") == "typescript")
    }

    @Test func denoAndBunAreTypeScriptOnlyWithTypes() {
        #expect(sniff("#!/usr/bin/env -S deno run\nconst n: number = 1\n") == "typescript")
        #expect(sniff("#!/usr/bin/env -S deno run\nconsole.log('hi')\n") == "javascript")
        #expect(sniff("#!/usr/bin/env bun\nconsole.log('hi')\n") == "javascript")
    }

    @Test func swiftShebang() {
        #expect(sniff("#!/usr/bin/swift\nprint(1)") == "swift")
        #expect(sniff("#!/usr/bin/env swift\nprint(1)") == "swift")
    }

    @Test func existingShebangsUnchanged() {
        #expect(sniff("#!/usr/bin/env python3\nx") == "python")
        #expect(sniff("#!/bin/zsh\nx") == "bash")
        #expect(sniff("#!/usr/bin/env node\nx") == "javascript")
        #expect(sniff("#!/usr/bin/env node\nconst n: number = 1") == "javascript")
    }

    // MARK: Go

    @Test func go() {
        #expect(sniff("package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"hi\")\n}\n") == "go")
        #expect(sniff("package main\n\nimport (\n\t\"fmt\"\n\t\"os\"\n)\n") == "go")
        #expect(sniff("package util\n\nfunc Add(a, b int) int { return a + b }\n") == "go")
    }

    @Test func goNeedsPackageLine() {
        #expect(sniff("func main() {\n\tx := 1\n}\n") == nil)
        // Java's dotted, semicolon-terminated package line is not Go.
        #expect(sniff("package com.example;\n\nclass A {}\n") == nil)
        // A lone package line is not enough.
        #expect(sniff("package main\n\nvar x = 1\n") == nil)
    }

    // MARK: Rust

    @Test func rust() {
        #expect(sniff("fn main() {\n    println!(\"Hello\");\n}\n") == "rust")
        #expect(sniff("use std::io;\n\nfn read() -> String {\n    let mut s = String::new();\n    s\n}\n") == "rust")
        #expect(sniff("pub fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n") == "rust")
        #expect(sniff("#![allow(dead_code)]\nstruct P;\nimpl P {\n    fn new() -> Self { P }\n}\n") == "rust")
    }

    @Test func rustNeedsFnPlusAnotherSignal() {
        #expect(sniff("fn helper(x) {\n  return x\n}\n") == nil)
        #expect(sniff("let mut a = 1;\nlet mut b = 2;\n") != "rust")
    }

    // MARK: Java vs C#

    @Test func java() {
        #expect(sniff("public class Main {\n    public static void main(String[] args) {\n        System.out.println(\"hi\");\n    }\n}\n") == "java")
        #expect(sniff("import java.util.List;\nimport java.util.ArrayList;\n\nclass A {}\n") == "java")
        #expect(sniff("package com.example;\n\npublic final class Util {\n}\n") == "java")
        #expect(sniff("class A {\n  void f() { System.out.println(1); }\n}\npublic class B {}\n") == "java")
    }

    @Test func csharp() {
        #expect(sniff("using System;\n\nConsole.WriteLine(\"Hello\");\n") == "csharp")
        #expect(sniff("namespace Demo\n{\n    class Program\n    {\n        static void Main(string[] args)\n        {\n            Console.WriteLine(\"hi\");\n        }\n    }\n}\n") == "csharp")
        #expect(sniff("var name = \"Karu\";\nConsole.WriteLine($\"Hi {name}\");\n") == "csharp")
        #expect(sniff("#:package Humanizer@2.14.1\nusing Humanizer;\nConsole.WriteLine(1);\n") == "csharp")
    }

    @Test func javaAndCSharpDoNotCollide() {
        // C# with `public class` must not be read as Java…
        #expect(sniff("using System;\n\npublic class Program\n{\n    public static void Main()\n    {\n        Console.WriteLine(1);\n    }\n}\n") == "csharp")
        // …and Java with `System.out` must not be read as C#.
        #expect(sniff("public class Program {\n    public static void main(String[] args) {\n        System.out.println(1);\n    }\n}\n") == "java")
        // A lone `public class` is neither.
        #expect(sniff("public class Foo {\n}\n") == nil)
    }

    @Test func csharpNeedsAnAnchor() {
        // TypeScript namespaces with `var …;` lines are not C#.
        #expect(sniff("namespace Shapes {\n  var count = 0;\n}\n") != "csharp")
        #expect(sniff("Console.WriteLine(\"one line\");\n") == nil)
    }

    // MARK: C vs C++

    @Test func cppHeaders() {
        #expect(sniff("#include <iostream>\nint main() { return 0; }") == "cpp")
        #expect(sniff("#include <vector>\n#include <algorithm>\n") == "cpp")
        #expect(sniff("#include <string>\nint main() {}") == "cpp")
        #expect(sniff("#include <bits/stdc++.h>\n") == "cpp")
    }

    @Test func cIncludeWithCppSignalsIsCpp() {
        #expect(sniff("#include <stdio.h>\nint main() { std::printf(\"x\"); }") == "cpp")
        #expect(sniff("#include <stdlib.h>\nclass A {\npublic:\n  int x;\n};\n") == "cpp")
    }

    @Test func plainCStaysC() {
        #expect(sniff("#include <stdio.h>\n#include <string.h>\nint main(void) {\n  printf(\"hi\\n\");\n  return 0;\n}\n") == "c")
        #expect(sniff("#include <stdlib.h>\nstruct point { int x; };\n") == "c")
    }

    @Test func cppWithoutIncludeNeedsTwoSignals() {
        #expect(sniff("using namespace std;\nint main() { cout << 1; }") == "cpp")
        #expect(sniff("template <typename T>\nT id(T v) { return v; }\nauto p = nullptr;\n") == "cpp")
        #expect(sniff("auto p = nullptr;\n") == nil)
    }

    @Test func includeOutranksPythonKeywords() {
        // Previously `class` / `import`-like lines could make this Python.
        #expect(sniff("#include <iostream>\nclass A {};\nclass B {};\n") == "cpp")
    }

    // MARK: Swift

    @Test func swift() {
        #expect(sniff("import Foundation\n\nprint(\"Hello\")\n") == "swift")
        #expect(sniff("import SwiftUI\n\nstruct ContentView: View {\n    var body: some View { Text(\"hi\") }\n}\n") == "swift")
        #expect(sniff("func greet(name: String) -> String {\n    guard !name.isEmpty else { return \"\" }\n    return \"Hi \\(name)\"\n}\n") == "swift")
        #expect(sniff("let names = [\"a\", \"b\"]\nfor n in names {\n    print(\"\\(n)!\")\n}\n") == "swift")
        #expect(sniff("@main\nstruct App {\n    static func main() -> Void {}\n}\n") == "swift")
    }

    @Test func swiftDoesNotCollideWithGoRustKotlinPython() {
        #expect(sniff("package main\n\nfunc main() {\n\tvar x = 1\n\tprint(x)\n}\n") == "go")
        #expect(sniff("fn main() {\n    let x = 5;\n    println!(\"{}\", x);\n}\n") == "rust")
        // Kotlin-like text is not claimed as Swift.
        #expect(sniff("fun main() {\n    val x = 1\n    println(x)\n}\n") == nil)
        // PyObjC also imports Foundation; Python definitions veto Swift.
        #expect(sniff("import Foundation\nimport objc\n\ndef main():\n    print(1)\n") == "python")
        // `print(` alone (Python 3 style) is not Swift.
        #expect(sniff("print(\"hello\")\nprint(\"world\")\n") == nil)
    }

    // MARK: TypeScript vs JavaScript

    @Test func typeScript() {
        #expect(sniff("const a: number = 1\nfunction greet(name: string) {}\n") == "typescript")
        #expect(sniff("import { x } from './x'\nimport type { Y } from './y'\n") == "typescript")
        #expect(sniff("interface User {\n  name: string\n}\ntype Id = string | number\n") == "typescript")
        #expect(sniff("const COLORS = ['red', 'blue'] as const\nlet i = 0\n") == "typescript")
        #expect(sniff("function first<T>(xs: T[]): T {\n  return xs[0]\n}\nconst y = 1\n") == "typescript")
    }

    @Test func javaScriptStaysJavaScript() {
        #expect(sniff("const a = 1\nfunction greet() {}") == "javascript")
        #expect(sniff("const obj = { name: 'x', count: 2 }\nlet z = cond ? a : b\n") == "javascript")
        #expect(sniff("function f({ a: b }) { return b }\nconst x = f({ a: 1 })\n") == "javascript")
        #expect(sniff("import React from 'react'\nimport { useState } from 'react'\n") == "javascript")
    }

    @Test func singleTypeScriptSignalAloneIsNotEnough() {
        #expect(sniff("type Id = string\n") == nil)
    }

    // MARK: Markup / data still win over code rules

    @Test func structuredFormatsKeepPriority() {
        #expect(sniff("{\n  \"package\": \"main\",\n  \"fn\": 1\n}") == "json")
        #expect(sniff("# Title\n```go\npackage main\nfunc main() {}\n```\n") == "markdown")
    }
}
