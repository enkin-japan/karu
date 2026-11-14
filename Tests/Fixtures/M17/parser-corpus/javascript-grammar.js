// T17.11a grammar coverage (valid JavaScript, JS mode with JSX).
"use strict";
const path = require("path");
module.exports = { helper, Widget };

let a = 1, b = 2;
[a, b] = [b, a];
({ a, b } = { a: 3, b: 4 });

const less = a < b > (a);
const pick = a ? (b) : c => c;
const typed = a ? (b) : (c);
const regex = /ab+c/gi.test("abbc") ? /[/]/ : a / b / 2;
label: for (const key in object) { if (key) continue label; else break label; }
type = 5;
let interface_ = { type: 1, interface: 2, declare: 3, as: 4 };
const as = 1, satisfies = as;
async function helper(x = {}, ...rest) {
    for await (const chunk of stream()) { await chunk; }
    return x?.y?.[0]?.(...rest) ?? null;
}

function* counter(start) {
    let n = start;
    while (true) yield n++;
}

class Widget extends Base {
    static count = 0;
    #secret = 1;
    static #registry = new Map();
    get secret() { return this.#secret; }
    set secret(v) { this.#secret = v; }
    async *items() { yield* [1, 2]; }
    static { Widget.count++; }
    render() {
        return (
            <div className="widget" onClick={() => this.secret++} {...this.props}>
                {this.props.items.map((item, i) => <Item key={i} {...item} />)}
                <>fragment text</>
                <input disabled />
            </div>
        );
    }
}

export default function App({ title, children }) {
    const [state, setState] = useState(null);
    return <Layout title={title}>{children ?? <span>{state}</span>}</Layout>;
}
export const memo = (x) => x, other = function named() { return new.target; };
export * from "./widgets.js";
export { default as Widget2 } from "./widget.js";
import def, * as all from "./all.js";
const lazy = import("./lazy.js");
console.log(import.meta.url, typeof lazy, void 0, delete interface_.as);
