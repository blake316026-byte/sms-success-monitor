export const DEFAULT_PERSISTENT_HIGHLIGHT_SETTINGS = Object.freeze({
  enabled: false,
  terms: [],
  color: '#fff176',
  wholeWords: false
});

export function normalizePersistentHighlightSettings(input = {}) {
  const values = Array.isArray(input.terms)
    ? input.terms
    : String(input.terms || '').split(/\r?\n/);
  const seen = new Set();
  const terms = [];
  for (const value of values) {
    const term = String(value || '').trim().slice(0, 100);
    const key = term.toLocaleLowerCase();
    if (!term || seen.has(key)) continue;
    seen.add(key);
    terms.push(term);
    if (terms.length >= 200) break;
  }
  const color = /^#[0-9a-f]{6}$/i.test(String(input.color || ''))
    ? String(input.color).toLowerCase()
    : DEFAULT_PERSISTENT_HIGHLIGHT_SETTINGS.color;
  return {
    enabled: Boolean(input.enabled),
    terms,
    color,
    wholeWords: Boolean(input.wholeWords)
  };
}
