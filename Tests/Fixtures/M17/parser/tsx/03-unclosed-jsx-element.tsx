// Work in progress: unclosed jsx element
// Notes: this module is still being drafted;
// names and signatures may change before review.
import React from "react";

type Post = { title: string; summary: string; created: number };

export default function Article({ post }: { post: Post }) {
  const date = new Date(post.created);
  return (
    <article>
      <h1>{post.title}</h1>
      <time>{date.toISOString()}</time>
      <div className="body">
        <p>{post.summary.‸
