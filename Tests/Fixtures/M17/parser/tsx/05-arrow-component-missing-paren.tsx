// Work in progress: arrow component missing paren
// Notes: this module is still being drafted;
import React from "react";

type CardProps = { title: string; body: string };

export const Card = ({ title, body }: CardProps) => (
  <div className="card">
    <h3>{title}</h3>
    <p>{body.‸}</p>
  </div>

export const Footer = () => <footer>done</footer>;

export const VERSION = "2";
