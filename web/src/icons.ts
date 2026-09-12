const paths: Record<string, string> = {
  arrow: '<path d="M7 17 17 7M7 7h10v10"/>',
  down: '<path d="M12 5v14m-6-6 6 6 6-6"/>',
  up: '<path d="M12 19V5m-6 6 6-6 6 6"/>',
  back: '<path d="m14 6-6 6 6 6"/>',
  chevron: '<path d="m9 5 7 7-7 7"/>',
  menu: '<path d="M5 7h14M5 12h14M5 17h14"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  terminal: '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="m7 9 3 3-3 3m6 0h4"/>',
  files: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8Z"/><path d="M14 3v5h5M9 13h6M9 17h4"/>',
  diff: '<path d="M12 3v7m-3-3h6M9 17h6"/><path d="M5 4v16M19 4v16" opacity=".45"/>',
  shield: '<path d="m12 3 8 3v5c0 5-8 10-8 10S4 16 4 11V6Z"/><path d="m8 11 3 3 5-5"/>',
  phone: '<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10 5h4m-3 14h2"/>',
  laptop: '<path d="M5 16V5a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v11M3 17h18l-1 3H4Z"/>',
  lock: '<rect x="5" y="10" width="14" height="11" rx="3"/><path d="M8 10V7a4 4 0 0 1 8 0v3m-4 4v3"/>',
  cpu: '<rect x="6" y="6" width="12" height="12" rx="3"/><rect x="9" y="9" width="6" height="6" rx="1"/><path d="M9 3v3m6-3v3M9 18v3m6-3v3M3 9h3m-3 6h3m12-6h3m-3 6h3"/>',
  github: '<path d="M9 19c-4 1-4-2-6-2m12 5v-4a3.5 3.5 0 0 0-1-3c3 0 6-1.5 6-5a4.5 4.5 0 0 0-1.3-3.2c.1-1 .1-2-.2-2.8 0 0-1-.3-3.2 1a11 11 0 0 0-6.6 0C6.5 3.7 5.5 4 5.5 4c-.3.8-.3 1.8-.2 2.8A4.5 4.5 0 0 0 4 10c0 3.5 3 5 6 5a3.5 3.5 0 0 0-1 3v4"/>',
};

export function icon(name: string, className = ""): string {
  return `<svg class="icon ${className}" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] ?? ""}</svg>`;
}
