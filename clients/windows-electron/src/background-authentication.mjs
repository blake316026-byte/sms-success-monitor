export function sameOrigin(configured, current) {
  try { return new URL(configured).origin === new URL(current).origin; } catch { return false; }
}

export function mayMaintainAuthentication({profile, blocked, loading, configuredURL, currentURL}) {
  return Boolean(profile?.autoLoginEnabled && profile?.username && profile?.password
    && !blocked && !loading && sameOrigin(configuredURL, currentURL));
}

export async function withDeadline(operation, milliseconds = 15000) {
  let timer;
  try {
    return await Promise.race([Promise.resolve().then(operation), new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Authentication page operation timed out')), milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}

// Compute the clock inside the runtime, after it is ready, not before queued work.
export function currentTotpExpression(secret, offsetMs = 0) {
  if (!Number.isFinite(offsetMs) || Math.abs(offsetMs) > 43260000) throw new Error('Invalid clock offset');
  return `(async()=>{const offset=${JSON.stringify(offsetMs)};
    const position=((Date.now()+offset)%30000+30000)%30000;
    if(position>24000)await new Promise(resolve=>setTimeout(resolve,31000-position));
    return globalThis.localAutomationRuntime.generateTotp(${JSON.stringify(secret)},Date.now()+offset);
  })()`;
}

export class TianchengAuthentication {
  constructor({call, sessionCall, profile, valid, generateCode, changed, now = Date.now, timeoutMs = 15000}) {
    Object.assign(this, {call, sessionCall, profile, valid, generateCode, changed, now, timeoutMs});
    this.generation = 0; this.busy = false; this.paused = false; this.stage = '';
    this.submittedAt = 0; this.preparingAt = null; this.nextAt = 0; this.stopped = false;
  }
  stop() { this.stopped = true; this.generation++; this.busy = false; }
  async reset() {
    this.stop(); this.stopped = false; this.paused = false; this.stage = '';
    this.preparingAt = null; this.nextAt = 0;
    const epoch = this.generation;
    this.busy = true;
    try {
      await withDeadline(() => this.call('reset'), this.timeoutMs);
      if (epoch === this.generation && this.sessionCall) {
        await withDeadline(() => this.sessionCall('reset'), this.timeoutMs);
      }
    }
    catch { this.paused = true; }
    finally { if (epoch === this.generation) this.busy = false; }
  }
  pause(message) {
    this.paused = true;
    this.changed('auth', message);
  }
  async checkSession(profile, current) {
    if (!this.sessionCall) {
      this.changed('disabled', '天成已登录'); this.nextAt = this.now() + 10000;
      return;
    }
    const call = (action, args) => withDeadline(() => this.sessionCall(action, args), this.timeoutMs);
    const snapshot = await call('snapshot', {username: profile.username});
    if (!current()) return;
    switch (snapshot?.kind) {
      case 'none': case 'verified':
        this.changed('disabled', '天成已登录'); this.nextAt = this.now() + 10000;
        return;
      case 'required': {
        if (!profile.totpSecret || !snapshot.challenge) {
          this.changed('auth', '天成定期身份验证需要 Google 密钥，请检查自动登录配置');
          this.nextAt = this.now() + 10000; return;
        }
        this.changed('starting', '天成：正在完成定期 Google 身份验证');
        const code = await this.generateCode(profile.totpSecret);
        if (!current()) return;
        // The page adapter persists its marker before clicking. Never replay an
        // uncertain submission or resume a payment/configuration request here.
        try {
          await call('submit', {username: profile.username, code, challengeID: snapshot.challenge});
        } catch {
          if (current()) this.changed('auth', '天成定期验证结果未确认，等待回读；不会自动重试');
        }
        return;
      }
      case 'waiting':
        this.changed('starting', '天成：等待定期身份验证完成并回读'); return;
      case 'operation':
        this.changed('auth', '天成操作验证待人工确认；不会自动重试支付或配置操作');
        this.nextAt = this.now() + 10000; return;
      case 'manual':
        this.changed('auth', '天成定期验证已暂停，请检查弹窗；不会自动重试');
        this.nextAt = this.now() + 10000; return;
      default:
        this.changed('auth', '天成定期验证状态暂不可确认，未提交验证码');
        this.nextAt = this.now() + 30000;
    }
  }
  async tick() {
    if (this.stopped || this.busy || !this.valid() || this.now() < this.nextAt) return;
    this.busy = true;
    const epoch = this.generation, profile = this.profile();
    const current = () => !this.stopped && epoch === this.generation && this.valid() && this.profile() === profile;
    const call = (action, args) => withDeadline(() => this.call(action, args), this.timeoutMs);
    let submitting = false;
    try {
      const snapshot = await call('snapshot');
      if (!current()) return;
      if (snapshot?.kind === 'authenticated') {
        this.paused = false; this.stage = ''; this.preparingAt = null;
        await this.checkSession(profile, current);
        return;
      }
      if (snapshot?.kind === 'manual') {
        this.pause('天成自动登录已暂停，请检查登录页；不会自动绑定 Google 或修改密码');
        return;
      }
      if (this.paused) return;
      let action, args;
      if (snapshot?.kind === 'password' && !this.stage) {
        action = 'submitPassword'; args = {username: profile.username, password: profile.password};
      } else if (snapshot?.kind === 'totp' && this.stage !== 'totp') {
        if (!profile.totpSecret) { this.changed('auth', '请配置 Google 密钥或人工完成动态码验证'); return; }
        const code = await this.generateCode(profile.totpSecret);
        if (!current()) return;
        action = 'submitTotp'; args = {code};
      } else {
        if (this.stage && this.now() - this.submittedAt > 20000) {
          this.pause('天成登录结果未确认，已暂停自动重试，请检查账号后保存配置');
        }
        return;
      }
      this.changed('starting', action === 'submitPassword' ? '天成：正在提交账号密码' : '天成：正在提交 Google 动态码');
      submitting = true;
      const result = await call(action, args);
      if (!current()) return;
      if (result?.submitted === false && result.retryable === true) {
        this.preparingAt ??= this.now();
        this.changed('starting', '天成登录表单尚未就绪，正在等待页面完成加载');
        if (this.now() - this.preparingAt > 30000) { this.nextAt = this.now() + 30000; this.preparingAt = null; }
        return;
      }
      if (result?.submitted !== true) { this.pause('天成登录提交结果未确认或人工接管，已暂停'); return; }
      this.stage = action === 'submitPassword' ? 'password' : 'totp';
      this.submittedAt = this.now(); this.preparingAt = null;
    } catch {
      if (current() && submitting) this.pause('天成登录提交结果未确认，已停止自动重试');
      else if (current()) this.changed('starting', '天成登录页面读取超时，等待重新检查');
    } finally {
      if (epoch === this.generation) {
        this.busy = false;
        this.nextAt = Math.max(this.nextAt, this.now() + 3000);
      }
    }
  }
}
