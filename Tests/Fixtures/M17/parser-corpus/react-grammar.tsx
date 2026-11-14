// T17.11a grammar coverage (valid TSX).
import type { ReactNode } from "react";
import { useState } from "react";

interface ListProps<T> {
    items: readonly T[];
    render?: (item: T, index: number) => ReactNode;
}

export function List<T extends { id: string }>({ items, render = (item) => <span>{item.id}</span> }: ListProps<T>) {
    const [selected, setSelected] = useState<string | null>(null);
    const toggle = (id: string) => setSelected(current => (current === id ? null : id));
    return (
        <ul className={selected ? "has-selection" : undefined}>
            {items.map((item, index) => (
                <li key={item.id} onClick={() => toggle(item.id)} data-index={index}>
                    {render(item, index)}
                    {selected === item.id && <strong>selected</strong>}
                </li>
            ))}
        </ul>
    );
}

export const Generic = <T,>({ value }: { value: T }) => <pre>{JSON.stringify(value satisfies T)}</pre>;
const casted = (document.getElementById("root") as HTMLElement)!;
