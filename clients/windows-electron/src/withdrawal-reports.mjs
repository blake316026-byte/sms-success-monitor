import crypto from 'node:crypto';

export const CACHE_TTL = 86400000;
export const reportKinds = ['pending', 'reviewers'];
export const day = (now = Date.now()) => {
  const d = new Date(now);
  return [d.getFullYear(), String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0')].join('-');
};
export function validDates(start, end) {
  return [start, end].every(value => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
    && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value) && start <= end;
}
export function normalizeSettings(kind, value = {}) {
  const minimum = kind === 'pending' ? 5 : 1;
  const fallback = kind === 'pending' ? 5 : 30;
  return {auto: typeof value.auto === 'boolean' ? value.auto : kind === 'reviewers',
    interval: Math.max(minimum, Math.min(kind === 'pending' ? 3600 : 1440, Math.trunc(Number(value.interval)) || fallback))};
}
const scope = source => JSON.stringify([source.id, source.url, source.account || '']);
const retryable = message => /未就绪|尚未加载|页面验证|需登录|页面恢复|context.*destroyed|frame.*disposed/i.test(message);
const count = value => Number.isSafeInteger(value) && value >= 0;

export class WithdrawalReports {
  constructor({sources, execute, scripts, load = () => ({}), save = () => {}, changed = () => {}, now = Date.now}) {
    Object.assign(this, {sources, execute, scripts, save, changed, now});
    this.cache = []; this.locked = new Set(); this.states = {}; this.writeError = '';
    let stored;
    try { stored = load() || {}; } catch { stored = {}; }
    this.cache = (Array.isArray(stored.cache) ? stored.cache : []).filter(e => this.validCache(e));
    for (const kind of reportKinds) {
      const end = day(now()), start = kind === 'pending' ? day(new Date(end + 'T12:00:00').getTime() - 6 * 86400000) : end;
      this.states[kind] = {kind, start, end, today: end, followsToday: true, settings: normalizeSettings(kind, stored.settings?.[kind]),
        active: false, visible: false, rows: new Map(), jobs: new Map(), probes: new Set(), generation: 0,
        due: Infinity, probingAt: 0, message: ''};
    }
  }
  validCache(e) {
    return e && typeof e.scope === 'string' && typeof e.identity === 'string' && validDates(e.start, e.end)
      && count(e.total) && this.now() - e.savedAt >= 0 && this.now() - e.savedAt < CACHE_TTL
      && Array.isArray(e.people) && e.people.every(p => typeof p.id === 'string' && typeof p.name === 'string' && count(p.count));
  }
  persist() {
    this.cache = this.cache.filter(e => this.validCache(e));
    try {
      this.save({cache: this.cache, settings: Object.fromEntries(reportKinds.map(k => [k, this.states[k].settings]))});
      this.writeError = '';
    } catch { this.writeError = '本地缓存保存失败'; }
  }
  notify(kind) { this.changed(kind, this.snapshot(kind)); }
  reconcile(kind) {
    const state = this.states[kind], sources = this.sources();
    for (const [id, row] of state.rows) {
      const source = sources.find(s => s.id === id);
      if (!source || row.scope !== scope(source) || (row.savedAt && this.now() - row.savedAt >= CACHE_TTL)) {
        state.rows.delete(id);
      }
    }
    for (const source of sources) {
      if (!state.rows.has(source.id)) state.rows.set(source.id, {scope: scope(source), id: source.id, people: [], orders: [],
        message: '未获取', waiting: false, total: null});
      state.rows.get(source.id).name = source.name;
    }
  }
  snapshot(kind) {
    this.reconcile(kind);
    const s = this.states[kind];
    return {kind, start: s.start, end: s.end, settings: s.settings, running: s.jobs.size > 0,
      message: [s.message, this.writeError].filter(Boolean).join(' · '),
      platforms: [...s.rows.values()].map(r => ({id:r.id, name:r.name, message:r.message, total:r.total,
        savedAt:r.savedAt || null, cached:!!r.cached, busy:s.jobs.has(r.id)})),
      rows: [...s.rows.values()].flatMap(r => (kind === 'pending' ? r.orders : r.people).map(item => ({...item, platformID:r.id, platform:r.name}))) };
  }
  async open(kind) {
    const s = this.states[kind];
    s.visible = true;
    if (!s.active) {
      s.active = true; this.schedule(s); this.reconcile(kind);
      if (kind === 'pending') void this.fetch(kind);
      else await this.restore();
    }
    this.notify(kind);
    return this.snapshot(kind);
  }
  close(kind) {
    this.states[kind].visible = false;
    if (kind === 'pending') this.cancel(kind);
  }
  schedule(s) { s.due = this.now() + s.settings.interval * (s.kind === 'pending' ? 1000 : 60000); }
  async configure(kind, input) {
    const s = this.states[kind];
    if (!validDates(input.start, input.end)) throw new Error('日期范围无效');
    const changed = s.start !== input.start || s.end !== input.end;
    if (changed) {
      this.cancel(kind); s.start = input.start; s.end = input.end; s.rows.clear();
      s.followsToday = kind === 'reviewers' && s.start === day(this.now()) && s.end === s.start;
      await Promise.all([...s.jobs.values()].map(job=>job.done));
    }
    s.settings = normalizeSettings(kind, input.settings); this.schedule(s); this.persist();
    if (changed && kind === 'reviewers') await this.restore();
    if (changed && kind === 'pending') void this.fetch(kind);
    this.notify(kind); return this.snapshot(kind);
  }
  args(source, s) {
    return {expectedUsername:source.account || '', allowNPG:source.allowNPG !== false,
      requiredNPGPermission:s.kind === 'pending' ? 'WITHDRAW_RECORD_LIST' : 'WITHDRAW_AUDIT_RECORD_LIST',
      startDate:s.start, endDate:s.end, requestID:crypto.randomUUID()};
  }
  async probe(source, s) {
    if (!source.ready) return {kind:'error',message:'页面未就绪，就绪后自动补查'};
    return this.execute(source, 'probe', this.args(source, s));
  }
  async restore() {
    const s = this.states.reviewers, generation = s.generation;
    this.reconcile('reviewers');
    await Promise.all(this.sources().map(async source => {
      try {
        const identity = await this.probe(source, s);
        if (generation !== s.generation || !this.current(source)) return;
        const row = s.rows.get(source.id);
        if (identity.kind !== 'ok') { row.restorePending=true; row.message=identity.message; return; }
        const entry = this.cache.find(e => this.validCache(e) && e.scope === scope(source) && e.identity === identity.identity && e.start === s.start && e.end === s.end);
        if (entry) Object.assign(row, {identity:entry.identity, family:entry.family, people:entry.people, total:entry.total,
          savedAt:entry.savedAt, cached:true, message:'本地缓存', contextID:''});
      } catch {
        if(generation===s.generation&&this.current(source)) {
          const row=s.rows.get(source.id);if(row){row.restorePending=true;row.message='页面未就绪';}
        }
      }
      finally { if (generation === s.generation) this.notify('reviewers'); }
    }));
  }
  current(source) { return this.sources().some(s => s.id === source.id && scope(s) === scope(source)); }
  cancel(kind, id) {
    const s = this.states[kind];
    if (!id) {s.generation++;s.message='已停止获取，保留已有结果';for(const row of s.rows.values())row.waiting=false;}
    for (const [key, job] of s.jobs) if (!id || key === id) {
      job.cancelled = true;
      void this.execute(job.source, 'cancel', {kind}).catch(() => {});
    }
  }
  async fetch(kind, ids = null) {
    const s = this.states[kind], generation=s.generation;
    this.reconcile(kind);
    if (!validDates(s.start, s.end)) throw new Error('日期范围无效');
    s.message = '查询中';
    await Promise.all(this.sources().filter(source => !ids || ids.includes(source.id)).map(source => this.fetchOne(kind, source)));
    if(generation===s.generation) {
      s.message = s.jobs.size ? '查询中' : '查询完成';
      if (!ids) this.schedule(s);
    }
    this.notify(kind);
    return this.snapshot(kind);
  }
  async fetchOne(kind, source) {
    const s = this.states[kind];
    if (s.jobs.has(source.id) || this.locked.has(source.id)) return;
    const generation = s.generation, job = {source, cancelled:false};
    let finish;job.done=new Promise(resolve=>{finish=resolve;});
    s.jobs.set(source.id, job);
    const valid = () => !job.cancelled && generation === s.generation && this.current(source);
    let row = s.rows.get(source.id);
    try {
      this.notify(kind);
      const p = await this.probe(source, s);
      if (!valid()) return;
      if (p.kind !== 'ok') throw new Error(p.message);
      if (row.identity && row.identity !== p.identity) Object.assign(row, {people:[],orders:[],total:null,savedAt:null,contextID:''});
      row.identity = p.identity; row.waiting = false;
      const args = this.args(source, s);
      if (kind === 'reviewers') {
        const first = await this.execute(source, kind, {...args, totalsOnly:true});
        if (!valid()) return;
        if (first.kind === 'ok' && count(first.platformTotal)) { row.total = first.platformTotal; this.notify(kind); }
      }
      const result = await this.execute(source, kind, args);
      if (!valid()) return;
      if (!['ok','partial'].includes(result.kind)) throw new Error(result.message || '查询失败');
      Object.assign(row, {family:result.family, contextID:result.contextID, waiting:false, cached:false, savedAt:this.now(),
        message: result.kind === 'partial' ? '结果不完整：' + result.message : '已获取'});
      if (kind === 'pending') {
        row.orders = result.orders;
        if(result.kind==='ok'&&!row.orders.length)row.message='无待处理订单';
      }
      else {
        if (!count(result.platformTotal)) throw new Error('接口总条数无效');
        row.people = result.reviewers; row.total = result.platformTotal;
        this.storeRow(s, row);
      }
    } catch (error) {
      if (valid()) {
        row.waiting = retryable(error.message);
        row.message = (kind === 'reviewers' && row.savedAt ? '刷新失败，保留上次结果：' : '未获取：') + error.message;
        if (kind === 'pending') {row.orders=[];row.contextID='';}
      }
    } finally {
      if (s.jobs.get(source.id) === job) s.jobs.delete(source.id);
      finish();
      this.notify(kind);
    }
  }
  storeRow(s, row) {
    if (!row.identity || !count(row.total)) return;
    this.cache = this.cache.filter(e => !(e.scope === row.scope && e.start === s.start && e.end === s.end));
    this.cache.push({scope:row.scope,identity:row.identity,start:s.start,end:s.end,family:row.family,
      people:row.people,total:row.total,savedAt:row.savedAt});
    this.persist();
  }
  async tick() {
    for (const kind of reportKinds) {
      const s = this.states[kind];
      if (!s.active) continue;
      const today = day(this.now());
      if (s.followsToday && s.today !== today && !this.locked.size) {
        this.cancel(kind); s.today=today; s.end=today;
        s.start=kind==='pending'?day(new Date(today+'T12:00:00').getTime()-6*86400000):today;
        s.rows.clear(); this.schedule(s);
      }
      this.reconcile(kind);
      if (kind === 'reviewers' && this.now() >= s.probingAt) {
        s.probingAt = this.now() + 5000;
        for (const source of this.sources()) {
          if (s.probes.has(source.id) || s.jobs.has(source.id) || this.locked.has(source.id)) continue;
          const row = s.rows.get(source.id), generation=s.generation;
          if (!row.waiting && !row.savedAt && !row.restorePending) continue;
          s.probes.add(source.id);
          void this.probe(source, s).then(p => {
            if (generation !== s.generation || !this.current(source)) return;
            if(row.restorePending&&p.kind==='ok') {
              row.restorePending=false;
              const entry=this.cache.find(e=>this.validCache(e)&&e.scope===scope(source)&&e.identity===p.identity&&e.start===s.start&&e.end===s.end);
              if(entry)Object.assign(row,{identity:entry.identity,family:entry.family,people:entry.people,total:entry.total,savedAt:entry.savedAt,cached:true,message:'本地缓存',contextID:''});
            }
            if (row.identity && p.kind === 'ok' && row.identity !== p.identity) {
              Object.assign(row,{people:[],orders:[],total:null,savedAt:null,contextID:'',identity:p.identity,waiting:true,message:'账号、国家或商户已变化，等待查询'});
            }
            if (row.waiting && s.settings.auto && p.kind === 'ok') void this.fetch(kind,[source.id]);
          }).catch(() => {}).finally(() => {s.probes.delete(source.id);this.notify(kind);});
        }
      }
      if (s.settings.auto && !s.jobs.size && (kind === 'reviewers' || s.visible) && this.now() >= s.due) {
        this.schedule(s); void this.fetch(kind);
      }
      this.notify(kind);
    }
    if (this.cache.some(e => !this.validCache(e))) this.persist();
  }
  target(kind, platformID, id, all = false) {
    this.reconcile(kind);
    const s = this.states[kind], row = s.rows.get(platformID);
    if (!row) throw new Error('平台已删除');
    const item = all ? null : (kind === 'pending' ? row.orders : row.people).find(item => item.id === id);
    if (!all && !item) throw new Error('列表已变化，请刷新后重试');
    const today = day(this.now());
    return {platformID, kind, id:all?'':id, all, contextID:row.contextID || '', family:row.family,
      identity:row.identity, start:all?today:s.start, end:all?today:s.end, scope:row.scope};
  }
  updateTotal(target, total) {
    const s=this.states.reviewers, row=s.rows.get(target.platformID);
    if (!row || row.scope!==target.scope || s.start!==target.start || s.end!==target.end || !count(total)) return;
    if (target.all) row.total=total;
    else {const person=row.people.find(p=>p.id===target.id);if(person)person.count=total;}
    row.savedAt=this.now();row.message='已按原平台搜索结果更新';
    this.storeRow(s,row);this.notify('reviewers');
  }
  dispose() { for(const kind of reportKinds)this.cancel(kind); }
}
