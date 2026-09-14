enum SessionLifecycleScript {
  static let body = #"""
    (() => {
      if (window.__smsMonitorSessionLifecycle) return;
      window.__smsMonitorSessionLifecycle = true;
      const marker = '__smsMonitorSignedOut';
      const usernameKey = '__smsMonitorSignedOutUsername';
      const revokedTokenKey = '__smsMonitorRevokedTokenFingerprint';
      const get = Storage.prototype.getItem;
      const set = Storage.prototype.setItem;
      const remove = Storage.prototype.removeItem;
      const clear = Storage.prototype.clear;
      const revoked = new Set();
      let pendingEnd = 0;
      let signedOutUsername = get.call(window.localStorage, usernameKey) || '';
      let revokedTokenFingerprint = get.call(window.localStorage, revokedTokenKey) || '';
      const userKey = (key) => key === 'lt-user' || String(key).endsWith('-lt-user');
      const token = (raw) => { try { return String(JSON.parse(raw)?.token || ''); } catch (_) { return ''; } };
      const username = (raw) => { try { const u = JSON.parse(raw); return String(u?.username || u?.account || u?.loginName || '').trim(); } catch (_) { return ''; } };
      const fingerprint = (value) => {
        let first = 2166136261;
        let second = 2246822507;
        for (let index = 0; index < value.length; index += 1) {
          const code = value.charCodeAt(index);
          first = Math.imul(first ^ code, 16777619);
          second = Math.imul(second ^ code, 3266489917);
        }
        return `${value.length}:${(first >>> 0).toString(16)}:${(second >>> 0).toString(16)}`;
      };
      const notify = (event) => { try { window.webkit.messageHandlers.smsSessionLifecycle.postMessage(event); } catch (_) {} };
      // Only the primary login page confirms an explicit logout. The Google
      // verification and IP-unlock pages are intermediate authentication steps
      // where the platform may legitimately rotate or temporarily remove tokens.
      const logoutRoute = () => window.location.pathname === '/login';
      const currentToken = () => {
        for (const store of [window.sessionStorage, window.localStorage]) {
          for (let index = 0; index < store.length; index++) {
            const key = store.key(index);
            if (userKey(key)) {
              const value = token(get.call(store, key));
              if (value) return value;
            }
          }
        }
        return '';
      };
      const end = (previous) => {
        if (previous) {
          revoked.add(previous);
          revokedTokenFingerprint = fingerprint(previous);
        }
        window.__smsMonitorSignedOut = true;
        set.call(window.localStorage, marker, '1');
        set.call(window.localStorage, usernameKey, signedOutUsername);
        if (revokedTokenFingerprint) set.call(window.localStorage, revokedTokenKey, revokedTokenFingerprint);
        notify({ event: 'ended', username: signedOutUsername });
      };
      const scheduleEnd = (previous) => {
        const candidate = ++pendingEnd;
        const delay = Math.max(0, Number(window.__smsMonitorSessionEndDelay) || 1200);
        window.setTimeout(() => {
          if (candidate !== pendingEnd || currentToken() || !logoutRoute()) return;
          end(previous);
        }, delay);
      };
      const startupToken = currentToken();
      const hadLogoutMarker = get.call(window.localStorage, marker) === '1';
      const startupTokenWasRevoked = Boolean(
        startupToken && revokedTokenFingerprint && fingerprint(startupToken) === revokedTokenFingerprint
      );
      window.__smsMonitorSignedOut = hadLogoutMarker && (!startupToken || startupTokenWasRevoked);
      if (hadLogoutMarker && startupToken && !startupTokenWasRevoked) {
        remove.call(window.localStorage, marker);
        remove.call(window.localStorage, usernameKey);
        remove.call(window.localStorage, revokedTokenKey);
        signedOutUsername = '';
        revokedTokenFingerprint = '';
        notify('authenticated');
      }
      Storage.prototype.removeItem = function(key) {
        const previous = userKey(key) && token(get.call(this, key));
        if (previous) signedOutUsername = username(get.call(this, key));
        const result = remove.call(this, key);
        if (previous) scheduleEnd(previous);
        return result;
      };
      Storage.prototype.clear = function() {
        let hadUser = false;
        for (let i = 0; i < this.length; i++) {
          const key = this.key(i);
          const previous = userKey(key) && token(get.call(this, key));
          if (previous) { hadUser = true; signedOutUsername = username(get.call(this, key)); }
        }
        const blocked = window.__smsMonitorSignedOut;
        const result = clear.call(this);
        if (hadUser && !blocked) scheduleEnd();
        else if (blocked) end();
        return result;
      };
      Storage.prototype.setItem = function(key, value) {
        const previous = userKey(key) && token(get.call(this, key));
        if (previous) signedOutUsername = username(get.call(this, key));
        const current = userKey(key) && token(value);
        // A response started before logout must not put the revoked token back.
        if (current && revoked.has(current)) {
          remove.call(this, key);
          end(current);
          return;
        }
        const result = set.call(this, key, value);
        if (previous && !current) scheduleEnd(previous);
        else if (current && current !== previous) {
          pendingEnd += 1;
          window.__smsMonitorSignedOut = false;
          remove.call(window.localStorage, marker);
          remove.call(window.localStorage, usernameKey);
          remove.call(window.localStorage, revokedTokenKey);
          signedOutUsername = '';
          revokedTokenFingerprint = '';
          notify('authenticated');
        }
        return result;
      };
      if (window.__smsMonitorSignedOut) notify({ event: 'ended', username: signedOutUsername });
    })();
    """#
}
