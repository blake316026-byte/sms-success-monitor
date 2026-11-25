// A platform may be visible in the main window or in a detached window.
export class NPGNoticePresentation {
  constructor(source) {
    this.source = source;
    this.visible = new Map();
  }

  sync(pages) {
    const previous = this.visible;
    this.visible = new Map(pages.map(page => [page.view.webContents, page.url]));
    for (const contents of previous.keys()) {
      if (!this.visible.has(contents) && !contents.isDestroyed()) {
        void contents.executeJavaScript('window.__smsNPGAutomaticNotice?.stop();void 0').catch(() => {});
      }
    }
    for (const [contents, url] of this.visible) {
      if (previous.get(contents) !== url) void this.onLoad(contents);
    }
  }

  async onLoad(contents) {
    const expected = this.visible.get(contents);
    if (!expected || contents.isDestroyed()) return;
    try {
      const origin = new URL(expected).origin;
      const current = new URL(contents.getURL());
      if (!['https:', 'http:'].includes(current.protocol) || current.origin !== origin) return;
      await contents.executeJavaScript('(async (expectedOrigin) => {\n' + this.source
        + '\n})(' + JSON.stringify(origin) + ')');
    } catch {
      // Navigation can replace the document while the same-origin check is running.
    }
  }
}
