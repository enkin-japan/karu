# Fenced code blocks

Python, with a backtick fence:

```python
def total(prices: list[float]) -> float:
    """Docstring inside a fence."""
    return sum(prices) / len(prices)  # comment
```

JavaScript via the `js` alias:

```js
const label = `avg ${[1, 2, 3].reduce((a, b) => a + b) / 3}`;
/* block comment */ console.log(label);
```

TypeScript via `ts`, with a tilde fence:

~~~ts
interface Point { x: number; y: number }
export const origin: Point = { x: 0, y: 0 };
~~~

Bash:

```bash
cat <<EOF
heredoc inside a fence: $HOME
EOF
```

JSON:

```json
{ "fence": "json", "nested": { "ok": true }, "n": 3 }
```

A four-backtick fence that contains a three-backtick line:

````markdown
Here is how to write a fence:

```python
print("this is still inside the outer four-backtick fence")
```
````

An unknown language stays a plain code block:

```brainfuck
++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.
```

A tilde fence closed only by tildes (the backticks below do not close it):

~~~
```
still inside the tilde fence
~~~

Text between fences with `inline code` and **bold**.

An unterminated fence runs to the end of the file:

```python
def never_closed():
    return "the fence above has no closing line"
