// Work in progress: map callback
// Notes: this module is still being drafted;
// names and signatures may change before review.
// Keep helpers small and avoid side effects at import time.
import React from "react";

type Item = { id: number; label: string };

export function Menu({ items }: { items: Item[] }) {
  return (
    <ul>
      {items.map(item => <li key={item.id}>{item.‸}</li>)}
    </ul>
  );
}
