// Work in progress: incomplete annotation
// Notes: this module is still being drafted;
// names and signatures may change before review.
// Keep helpers small and avoid side effects at import time.
export interface Settings { theme: string; fontSize: number }

export function applySettings(settings: Settings, force = false) {
  let timeout: Opt‸
  const root = document.body;
  root.dataset.theme = settings.theme;
  if (force) {
    root.style.fontSize = settings.fontSize + "px";
  }
  return root;
}
