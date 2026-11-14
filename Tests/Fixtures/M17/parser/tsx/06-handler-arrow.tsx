// Work in progress: handler arrow
// Notes: this module is still being drafted;
// names and signatures may change before review.
import { useState } from "react";

export function Counter({ step = 1 }: { step?: number }) {
  const [count, setCount] = useState(0);
  const label = `Count: ${count}`;
  return (
    <div>
      <span>{label}</span>
      <button onClick={() => setCount(count.‸)}>+</button>
    </div>
  );
}
