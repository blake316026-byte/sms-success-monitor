enum SessionLifecycleScript {
  static let body = #"""
    (() => {
      if (window.__smsMonitorSessionLifecycle) return;
      window.__smsMonitorSessionLifecycle = true;
      const marker = '__smsMonitorSignedOut';
      const usernameKey = '__smsMonitorSignedOutUsername';
      const get = Storage.prototype.getItem;
      const set = Storage.prototype.setItem;
      const remove = Storage.prototype.removeItem;
      const clear = Storage.prototype.clear;
      const revoked = new Set();
      let signedOutUsername = get.call(window.localStorage, usernameKey) || '';
      const userKey = (key) => key === 'lt-user' || String(key).endsWith('-lt-user');
      const token = (raw) => { try { return String(JSON.parse(raw)?.token || ''); } catch (_) { return ''; } };
      const username = (raw) => { try { const u = JSON.parse(raw); return String(u?.username || u?.account || u?.loginName || '').trim(); } catch (_) { return ''; } };
      const notify = (event) => { try { window.webkit.messageHandlers.smsSessionLifecycle.postMessage(event); } catch (_) {} };
      const end = (previous) => {
        if (previous) revoked.add(previous);
        window.__smsMonitorSignedOut = true;
        set.call(window.localStorage, marker, '1');
        set.call(window.localStorage, usernameKey, signedOutUsername);
        notify({ event: 'ended', username: signedOutUsername });
      };
      window.__smsMonitorSignedOut = get.call(window.localStorage, marker) === '1';
      Storage.prototype.removeItem = function(key) {
        const previous = userKey(key) && token(get.call(this, key));
        if (previous) signedOutUsername = username(get.call(this, key));
        const result = remove.call(this, key);
        if (previous) end(previous);
        return result;
      };
      Storage.prototype.clear = function() {
        let hadUser = false;
        for (let i = 0; i < this.length; i++) {
          const key = this.key(i);
          const previous = userKey(key) && token(get.call(this, key));
          if (previous) { hadUser = true; revoked.add(previous); signedOutUsername = username(get.call(this, key)); }
        }
        const blocked = window.__smsMonitorSignedOut;
        const result = clear.call(this);
        if (hadUser || blocked) end();
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
        if (previous && !current) end(previous);
        else if (current && current !== previous) {
          window.__smsMonitorSignedOut = false;
          remove.call(window.localStorage, marker);
          remove.call(window.localStorage, usernameKey);
          signedOutUsername = '';
          notify('authenticated');
        }
        return result;
      };
      if (window.__smsMonitorSignedOut) notify({ event: 'ended', username: signedOutUsername });
    })();
    """#
}
