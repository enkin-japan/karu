import React from "react";

type SearchProps = { form: FormState; onChange: (e: Event) => void };

export function SearchBox({ form, onChange }: SearchProps) {
  return (
    <form className="search">
      <input
        type="text"
        value={form.‸
        onChange={onChange}
      />
      <button type="submit">Go</button>
    </form>
  );
}
