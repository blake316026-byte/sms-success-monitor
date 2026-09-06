(() => {
  if (globalThis.smsPersistentHighlighter) {
    globalThis.webkit?.messageHandlers?.smsPersistentHighlightReady?.postMessage('ready');
    return;
  }

  const highlightName = 'sms-monitor-persistent-highlight';
  const styleId = 'sms-monitor-persistent-highlight-style';
  const blockedTags = new Set([
    'SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'INPUT', 'SELECT', 'OPTION'
  ]);
  const maximumMatches = 10_000;
  let settings = { enabled: false, terms: [], color: '#fff176', wholeWords: false };
  let observer;
  let refreshTimer;

  const normalize = (input = {}) => {
    const seen = new Set();
    const terms = [];
    for (const value of Array.isArray(input.terms) ? input.terms : []) {
      const term = String(value || '').trim().slice(0, 100);
      const key = term.toLocaleLowerCase();
      if (!term || seen.has(key)) continue;
      seen.add(key);
      terms.push(term);
      if (terms.length >= 200) break;
    }
    const color = /^#[0-9a-f]{6}$/i.test(String(input.color || ''))
      ? String(input.color).toLowerCase()
      : '#fff176';
    return {
      enabled: Boolean(input.enabled),
      terms,
      color,
      wholeWords: Boolean(input.wholeWords)
    };
  };

  const foregroundFor = (color) => {
    const value = Number.parseInt(color.slice(1), 16);
    const red = (value >> 16) & 255;
    const green = (value >> 8) & 255;
    const blue = value & 255;
    return red * 0.299 + green * 0.587 + blue * 0.114 > 150 ? '#111111' : '#ffffff';
  };

  const ensureStyle = () => {
    let style = document.getElementById(styleId);
    if (!style) {
      style = document.createElement('style');
      style.id = styleId;
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = `
      ::highlight(${highlightName}) {
        background-color: ${settings.color};
        color: ${foregroundFor(settings.color)};
        text-decoration: none;
      }
    `;
  };

  const isWordCharacter = (value) => Boolean(value && /[\p{L}\p{N}_]/u.test(value));
  const hasWholeWordBoundary = (text, start, length) => (
    !isWordCharacter(text[start - 1]) && !isWordCharacter(text[start + length])
  );

  const collectRanges = () => {
    const root = document.body || document.documentElement;
    if (!root) return [];
    const needles = settings.terms.map((term) => ({
      original: term,
      folded: term.toLocaleLowerCase()
    })).sort((left, right) => right.folded.length - left.folded.length);
    const ranges = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const parent = node.parentElement;
        if (!parent || blockedTags.has(parent.tagName) || !node.data.trim()) {
          return NodeFilter.FILTER_REJECT;
        }
        if (parent.closest('[hidden], [aria-hidden="true"], [contenteditable="true"]')) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    for (let node = walker.nextNode(); node && ranges.length < maximumMatches; node = walker.nextNode()) {
      const foldedText = node.data.toLocaleLowerCase();
      for (const needle of needles) {
        let offset = 0;
        while (offset <= foldedText.length - needle.folded.length && ranges.length < maximumMatches) {
          const found = foldedText.indexOf(needle.folded, offset);
          if (found < 0) break;
          offset = found + Math.max(needle.folded.length, 1);
          if (settings.wholeWords
            && !hasWholeWordBoundary(foldedText, found, needle.folded.length)) continue;
          const range = document.createRange();
          range.setStart(node, found);
          range.setEnd(node, found + needle.original.length);
          ranges.push(range);
        }
      }
    }
    return ranges;
  };

  const clear = () => {
    globalThis.CSS?.highlights?.delete(highlightName);
    return { supported: Boolean(globalThis.CSS?.highlights), count: 0 };
  };

  const refresh = () => {
    clearTimeout(refreshTimer);
    refreshTimer = undefined;
    clear();
    if (!settings.enabled || !settings.terms.length) {
      return { supported: Boolean(globalThis.CSS?.highlights), count: 0 };
    }
    if (!globalThis.CSS?.highlights || typeof globalThis.Highlight !== 'function') {
      return { supported: false, count: 0 };
    }
    ensureStyle();
    const ranges = collectRanges();
    const highlight = new Highlight();
    for (const range of ranges) highlight.add(range);
    CSS.highlights.set(highlightName, highlight);
    return { supported: true, count: ranges.length };
  };

  const scheduleRefresh = () => {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(refresh, 120);
  };

  const observe = () => {
    observer?.disconnect();
    const root = document.body || document.documentElement;
    if (!root || typeof MutationObserver !== 'function') return;
    observer = new MutationObserver(scheduleRefresh);
    observer.observe(root, { childList: true, characterData: true, subtree: true });
  };

  const configure = (input) => {
    settings = normalize(input);
    ensureStyle();
    observe();
    return refresh();
  };

  globalThis.smsPersistentHighlighter = { configure, refresh, clear };
  globalThis.webkit?.messageHandlers?.smsPersistentHighlightReady?.postMessage('ready');
})();
