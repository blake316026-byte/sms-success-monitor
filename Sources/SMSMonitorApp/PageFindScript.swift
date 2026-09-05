import Foundation

enum PageFindScript {
  static let body = #"""
    const text = String(query || '');
    const highlightAPIAvailable = Boolean(
      globalThis.CSS?.highlights && typeof globalThis.Highlight === 'function'
    );
    const allName = 'sms-monitor-find-all';
    const currentName = 'sms-monitor-find-current';

    if (!highlightAPIAvailable) {
      return { supported: false, count: 0, active: 0 };
    }

    const clear = () => {
      CSS.highlights.delete(allName);
      CSS.highlights.delete(currentName);
      delete window.__smsMonitorPageFindState;
    };
    if (!text) {
      clear();
      return { supported: true, count: 0, active: 0 };
    }

    const ensureStyles = () => {
      if (window.__smsMonitorPageFindStylesInstalled) return;
      const rules = `
        ::highlight(${allName}) {
          background-color: rgba(255, 235, 59, 0.92);
          color: #111111;
        }
        ::highlight(${currentName}) {
          background-color: #ff9800;
          color: #111111;
          text-decoration: underline 2px #b45309;
        }
      `;
      try {
        const sheet = new CSSStyleSheet();
        sheet.replaceSync(rules);
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        window.__smsMonitorPageFindSheet = sheet;
      } catch (_) {
        const style = document.createElement('style');
        style.dataset.smsMonitorPageFind = 'true';
        style.textContent = rules;
        (document.head || document.documentElement).appendChild(style);
      }
      window.__smsMonitorPageFindStylesInstalled = true;
    };

    const collectRanges = () => {
      const ranges = [];
      const needle = text.toLocaleLowerCase();
      const root = document.body || document.documentElement;
      if (!root || !needle) return ranges;
      const blockedTags = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA']);
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
          const parent = node.parentElement;
          if (!parent || blockedTags.has(parent.tagName) || !node.data.trim()) {
            return NodeFilter.FILTER_REJECT;
          }
          if (parent.closest('[hidden], [aria-hidden="true"]')) return NodeFilter.FILTER_REJECT;
          const style = getComputedStyle(parent);
          if (style.display === 'none' || style.visibility === 'hidden') {
            return NodeFilter.FILTER_REJECT;
          }
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const haystack = node.data.toLocaleLowerCase();
        let offset = 0;
        while (offset <= haystack.length - needle.length) {
          const found = haystack.indexOf(needle, offset);
          if (found < 0) break;
          const range = document.createRange();
          range.setStart(node, found);
          range.setEnd(node, found + text.length);
          ranges.push(range);
          offset = found + Math.max(needle.length, 1);
        }
      }
      return ranges;
    };

    ensureStyles();
    const previous = window.__smsMonitorPageFindState;
    const canReuse = previous?.query === text
      && previous.ranges.every((range) => range.startContainer?.isConnected);
    const ranges = canReuse ? previous.ranges : collectRanges();
    let index = canReuse ? previous.index : (backwards ? ranges.length - 1 : 0);
    if (canReuse && advance && ranges.length) {
      index = (index + (backwards ? -1 : 1) + ranges.length) % ranges.length;
    }
    if (!ranges.length) index = -1;

    const all = new Highlight();
    for (const range of ranges) all.add(range);
    CSS.highlights.set(allName, all);
    CSS.highlights.delete(currentName);
    if (index >= 0) {
      const current = new Highlight(ranges[index]);
      current.priority = 1;
      CSS.highlights.set(currentName, current);
      const target = ranges[index].startContainer.parentElement;
      if (target && (!canReuse || advance)) {
        target.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' });
      }
    }

    window.__smsMonitorPageFindState = { query: text, ranges, index };
    return { supported: true, count: ranges.length, active: index + 1 };
  """#
}
