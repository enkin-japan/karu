# Karu Release Notes

A paragraph with *emphasis*, **strong text**, `inline code`, and a
[link](https://example.com "title"). An auto link: <https://example.com>.

## Highlights

- Item one with `code`
- Item two
  - Nested item with **bold**
1. Ordered one
2. Ordered two

> A block quote that spans
> two lines with *emphasis*.

<!--
An HTML comment in Markdown
spanning several lines, with # not a heading.
-->

### Code

Inline backticks with a fence-like sequence: `` ``` `` stays inline.

```python
def greet(name: str) -> str:
    # comment inside a fence
    return f"Hello, {name}"
```

    indented code block line one
    indented code block line two

~~~
plain tilde fence
# not a heading inside a fence
~~~

| Column | Value |
|--------|-------|
| a      | `1`   |
| b      | **2** |

---

Setext heading
==============

Final paragraph with a trailing backslash\
hard line break and an escaped \*star\*.
