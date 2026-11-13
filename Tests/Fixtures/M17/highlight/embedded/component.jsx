// TodoList.jsx — tags, attributes and {expression} children.
import { useState } from 'react';

/* A block comment before the component:
   <div>not JSX</div> */
export function TodoList({ initial = [], title }) {
  const [items, setItems] = useState(initial);
  const done = items.filter((t) => t.done).length;
  const ratio = items.length ? done / items.length / 1 : 0;

  return (
    <section className="todo" data-ratio={ratio.toFixed(2)} aria-label={`${title} list`}>
      <h2 title="Todo items: a < b is text in an attribute string">{title ?? 'Todos'}</h2>
      {/* JSX comment inside braces */}
      <ul>
        {items.map((item) => (
          <li key={item.id} className={item.done ? 'done' : undefined}>
            <input
              type="checkbox"
              checked={item.done}
              onChange={() => setItems(items.map((t) => (t.id === item.id ? { ...t, done: !t.done } : t)))}
            />
            {item.label} — {`${item.label.length} chars`}
          </li>
        ))}
      </ul>
      <p>
        Plain JSX text with an apostrophe's and "quotes" is not a string.
        {done} of {items.length} done ({Math.round(ratio * 100)}%)
      </p>
      <Footer count={items.length} render={(n) => <span>{n / 2}</span>} />
    </section>
  );
}

function Footer({ count, render }) {
  return <footer>{count > 0 ? render(count) : <em>empty</em>}</footer>;
}
