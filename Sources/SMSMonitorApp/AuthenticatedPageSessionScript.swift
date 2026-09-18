enum AuthenticatedPageSessionScript {
  static let body = #"""
    const expected = String(expectedUsername || '').trim();
    const users = [];
    const identities = new Set();
    for (const store of [window.sessionStorage, window.localStorage]) {
      for (let index = 0; index < store.length; index += 1) {
        const key = store.key(index);
        if (!key || (key !== 'lt-user' && !key.endsWith('-lt-user'))) continue;
        let value;
        try { value = JSON.parse(store.getItem(key)); } catch (_) { value = null; }
        if (!value || typeof value !== 'object') continue;
        const username = String(value.username || value.account || value.loginName || '').trim();
        const token = String(value.token || '').trim();
        if (username) identities.add(username);
        users.push({ username, token });
      }
    }

    const signedOut = window.__smsMonitorSignedOut === true
      || window.localStorage.getItem('__smsMonitorSignedOut') === '1';
    if (signedOut) return { kind: 'signedOut' };
    if (identities.size > 1) return { kind: 'accountConflict' };

    const username = identities.values().next().value || '';
    if (expected && username !== expected) return { kind: 'accountMismatch', username };
    const session = users.find((candidate) => candidate.token && (!expected || candidate.username === expected));
    if (!session) return { kind: 'missingToken', username };
    return { kind: 'authenticated', username: session.username || username, token: session.token };
    """#
}
