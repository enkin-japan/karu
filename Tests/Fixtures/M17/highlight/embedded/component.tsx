// Badge.tsx — TSX tags, typed props and {expression} children.
import type { ReactNode } from 'react';

type Tone = 'info' | 'warn' | 'error';

interface BadgeProps<T extends string = string> {
  label: T;
  tone?: Tone;
  count?: number;
  children?: ReactNode;
}

/* Generic arrow component: the <T,> comma keeps it from reading as a tag. */
export const Badge = <T extends string,>({ label, tone = 'info', count = 0, children }: BadgeProps<T>) => {
  const width = count > 99 ? 3 : String(count).length;
  const ratio = count / 100 / 1;
  return (
    <span className={`badge badge-${tone}`} style={{ minWidth: `${width}ch` }} data-ratio={ratio}>
      {label as string}
      {count > 0 && <sup aria-label={`${count} items`}>{count}</sup>}
      {/* comment in TSX */}
      {children}
    </span>
  );
};

export function BadgeList({ labels }: { labels: readonly string[] }): JSX.Element {
  const casted = labels as unknown as Tone[];
  return (
    <ul>
      {labels.map((l, i) => (
        <li key={l}>
          <Badge<string> label={l} tone={casted[i] ?? 'info'} count={i * 2}>
            text child with 'quotes' and a < b comparison written as text
          </Badge>
        </li>
      ))}
    </ul>
  );
}
