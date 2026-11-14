# M17 parser error-tolerance samples (T17.9)

Shared sample set for choosing / validating the M17 error-tolerant parser. Each sample is a partially-typed source file with exactly one caret marker `‸` (U+2038) where the user is typing. The marker is part of the file text; parsers should strip it (or treat it as the caret position) before parsing.

## Layout

- `python/NN-name.py`, `typescript/NN-name.ts`, `tsx/NN-name.tsx`
- one `expected.json` per language directory, an object keyed by file name
- `check.py` validates the structure (run `python3 check.py`, exit 0 on success)

## expected.json entry

- `topLevel`: top-level function / class names (TS also interface, type alias, enum) and top-level variable / const bindings, in document order. Python: module-level assignment targets that are plain names; imports excluded. Definitions after an earlier unrelated syntax error are still expected.
- `enclosing`: enclosing class / function / method names at the caret, outermost first. Anonymous arrow functions / lambdas are `"<anon>"`; `[]` at module level. A TS constructor is `"constructor"`. A caret inside a function's signature or type-parameter list is not inside that function. An arrow function bound to a const takes the binding name (TSX components).
- `params`: parameter names of the innermost enclosing function (named or anonymous), in order; `self` included for Python methods; destructured params by their bound names; `[]` if none or at module level.
- `receiver`: when the text before the caret (after an optional partial identifier) ends with `.` or `?.`, the exact source text of the receiver expression before that dot; otherwise `null`. For `a?.b?.` the receiver is `a?.b`.

## Samples


### Python (26)

| File | Incompleteness class |
|---|---|
| `python/01-eof-dot.py` | trailing `.` at end of file; subscript receiver |
| `python/02-mid-dot.py` | `.` mid-file with more code (and defs) after it |
| `python/03-partial-ident.py` | partial identifier after the dot (`cart.ite`) at end of a `for` header |
| `python/04-unclosed-call.py` | unclosed `(` in call arguments before the caret, code continues after |
| `python/05-unclosed-list.py` | unclosed `[` list literal at end of file |
| `python/06-unclosed-dict.py` | unclosed `{` dict literal at end of file |
| `python/07-half-keyword.py` | half-typed keyword `retu` |
| `python/08-unterminated-string.py` | unterminated string on the caret line |
| `python/09-missing-colon.py` | incomplete signature: missing `:` after `def ...(...)`, caret in the body |
| `python/10-indentation-error.py` | indentation error inside a function body (dedented statement then over-indented one) |
| `python/11-nested-function-in-method.py` | caret inside a nested function inside a method |
| `python/12-lambda.py` | caret inside an unclosed lambda in a call |
| `python/13-chained-receiver.py` | chained receiver with call and subscript (`a.b(c)[0].d.`) |
| `python/14-await-receiver.py` | receiver after `await` (parenthesised) |
| `python/15-incomplete-annotation.py` | incomplete type annotation (`timeout: Opt`) in a function body |
| `python/16-stray-paren.py` | stray `)` earlier in the file |
| `python/17-incomplete-import.py` | incomplete import lines (caret on a half-typed import, bare `from x import` / `import` after it) |
| `python/18-decorator-without-def.py` | decorator lines without the decorated def (caret after dangling decorators at end of file) |
| `python/19-top-syntax-error.py` | syntax error at the top of the file, valid definitions after it |
| `python/20-fstring-unterminated.py` | unterminated f-string with partial identifier inside the braces |
| `python/21-try-without-except.py` | `try:` block without `except`, call receiver, defs after |
| `python/22-module-level-dot.py` | `.` at module level inside an assignment, defs after it |
| `python/23-self-dot-in-init.py` | bare `self.` inside `__init__` followed by more methods |
| `python/24-double-subscript-receiver.py` | unclosed call with double-subscript receiver |
| `python/25-super-call.py` | receiver is a call (`super().`), star parameters |
| `python/26-comprehension-dot.py` | caret inside a comprehension element (not a function scope) |

### TypeScript (25)

| File | Incompleteness class |
|---|---|
| `typescript/01-eof-dot.ts` | trailing `.` at end of file; subscript+member receiver |
| `typescript/02-mid-dot.ts` | `.` mid-file with more code after it |
| `typescript/03-partial-ident.ts` | partial identifier after the dot (`this.items.ma`) |
| `typescript/04-unclosed-call.ts` | unclosed `(` and `{` in call arguments before the caret, defs after |
| `typescript/05-unclosed-array.ts` | unclosed `[` array literal of objects at end of file |
| `typescript/06-unclosed-object.ts` | unclosed `{` object literal at end of file |
| `typescript/07-half-keyword.ts` | half-typed keyword `retu` |
| `typescript/08-unterminated-string.ts` | unterminated string on the caret line |
| `typescript/09-missing-open-brace.ts` | function signature missing its `{`, body and `}` present |
| `typescript/10-missing-close-brace.ts` | function body's closing `}` missing at end of file |
| `typescript/11-nested-function-in-method.ts` | caret inside a nested function in a method |
| `typescript/12-arrow.ts` | caret inside an unclosed arrow function in a call |
| `typescript/13-chained-receiver.ts` | chained receiver with call and subscript (`a.b(c)[0].d.`) |
| `typescript/14-await-paren-receiver.ts` | receiver after `await` (parenthesised) |
| `typescript/15-await-call-chain.ts` | receiver after `await` without parentheses (`fetchUser(id).profile.`) |
| `typescript/16-incomplete-generic-type.ts` | incomplete type annotation `let counts: Map<string, ` |
| `typescript/17-incomplete-annotation.ts` | incomplete type annotation `let timeout: Opt` |
| `typescript/18-stray-brace-paren.ts` | stray `}` and stray `);` earlier in the file; constructor parameter properties |
| `typescript/19-incomplete-import.ts` | incomplete import lines (caret on a half-typed named import) |
| `typescript/20-top-syntax-error.ts` | syntax error at the top of the file, valid definitions after it |
| `typescript/21-generic-constraint.ts` | generics: caret in an unfinished `<T extends ` constraint at end of file (type-parameter list is outside the function) |
| `typescript/22-optional-chaining.ts` | optional chaining `a?.b?.` receiver |
| `typescript/23-ctor-param-properties.ts` | class fields and constructor parameter properties, caret in constructor body |
| `typescript/24-enum-type-alias.ts` | enum / type alias / interface top-level names, bracket receiver, missing final `}` |
| `typescript/25-async-arrow-in-method.ts` | caret inside an async arrow passed as an argument inside a method |

### TSX (7)

| File | Incompleteness class |
|---|---|
| `tsx/01-jsx-child-expr.tsx` | caret inside a JSX child expression `{user.}` |
| `tsx/02-attribute-expr.tsx` | caret inside an unclosed JSX attribute expression `value={form.` |
| `tsx/03-unclosed-jsx-element.tsx` | caret inside unclosed JSX elements at end of file |
| `tsx/04-generic-arrow-component.tsx` | generic arrow component `<T,>`, member receiver in JSX child |
| `tsx/05-arrow-component-missing-paren.tsx` | arrow component missing its closing `)`, later definition expected |
| `tsx/06-handler-arrow.tsx` | caret inside a zero-parameter arrow handler in an attribute, unclosed call |
| `tsx/07-map-callback.tsx` | caret in JSX child inside an arrow passed to `.map` |
