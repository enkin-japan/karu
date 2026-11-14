// Work in progress: generic arrow component
// Notes: this module is still being drafted;
// names and signatures may change before review.
import React from "react";

interface ListProps<T> { items: T[]; render: (item: T) => JSX.Element }

export const List = <T,>(props: ListProps<T>) => {
  const count = props.items.length;
  return (
    <ul data-count={count}>
      {props.items.‸}
    </ul>
  );
};
