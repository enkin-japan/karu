import React from "react";

interface ProfileProps { user: User; onClose: () => void }

export function Profile({ user, onClose }: ProfileProps) {
  const initials = user.name.slice(0, 2);
  return (
    <section className="profile">
      <h2>{initials}</h2>
      <p>{user.‸}</p>
      <button onClick={onClose}>Close</button>
    </section>
  );
}

export const DEFAULT_AVATAR = "/img/default.png";
