enum WithdrawalReviewersScript {
  static let query = PendingOrdersScript.context + #"""
    window.__smsReviewerAbort?.abort();
    window.__smsReviewerRun = requestID;
    try {
      const current = capture(), snapshot = JSON.stringify(current), deadline = Date.now() + 180000;
      const check = () => {
        if (window.__smsReviewerRun !== requestID || JSON.stringify(capture()) !== snapshot) fail('会话或查询已变化，请重新获取');
        if (Date.now() > deadline) fail('查询超时，未确认完整人员总数');
      };
      const request = async (path, params, method = 'GET') => {
        check();
        const url = new URL(path, location.origin);
        const headers = current.family === 'TC'
          ? {Accept:'application/json', Authorization:current.token, Merchant:current.merchant, merchantCode:current.merchant,
             platform:current.platform, environment:current.environment, customTimezone:current.timezone, Language:text(read(ls,'language')) || 'zh_CN'}
          : {Accept:'application/json', 'Content-Type':'application/json', Auth:current.token, COUNTRY:current.country,
             LANGUAGE:current.language, ...(current.tkk ? {Tkk:String(current.tkk)} : {})};
        if (method === 'GET') url.search = new URLSearchParams(params).toString();
        const controller = new AbortController(); window.__smsReviewerAbort = controller;
        const timer = setTimeout(() => controller.abort(), 15000);
        try {
          const response = await fetch(url.href, {method, headers, credentials:'include', cache:'no-store', signal:controller.signal,
            ...(method === 'POST' ? {body:JSON.stringify(params)} : {})});
          check();
          if (response.status === 401) fail('需登录');
          if (response.status === 403) fail('无查询权限');
          if (!response.ok) fail('查询 HTTP ' + response.status);
          const p = await response.json(); check();
          if (current.family === 'TC' ? p?.success !== true : ![0,'0','OK','SUCCESS'].includes(p?.status ?? p?.code)) fail('接口拒绝查询，请检查登录或权限');
          return p;
        } finally { clearTimeout(timer); if (window.__smsReviewerAbort === controller) window.__smsReviewerAbort = null; }
      };
      const zone = current.family === 'TC' ? current.timezone : (await request('/api/auth/timezone_with_country', {countryId:current.country}, 'POST')).model;
      if (!zone || typeof zone !== 'string') fail('后台时区未就绪');
      const dayNumber = value => {
        if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) fail('日期无效');
        const n = Date.parse(value + 'T00:00:00Z');
        if (!Number.isFinite(n) || new Date(n).toISOString().slice(0,10) !== value) fail('日期无效');
        return n / 86400000;
      };
      if (startDate > endDate) fail('日期范围无效');
      const formatter = new Intl.DateTimeFormat('en-CA', {timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit'});
      const boundary = day => {
        let lo=day*86400000-129600000, hi=day*86400000+129600000;
        while(lo<hi) { const m=Math.floor((lo+hi)/2), p=Object.fromEntries(formatter.formatToParts(new Date(m)).map(x=>[x.type,x.value]));
          if (Date.UTC(+p.year,+p.month-1,+p.day)/86400000 < day) lo=m+1; else hi=m; }
        return lo;
      };
      const start=boundary(dayNumber(startDate)), finish=boundary(dayNumber(endDate)+1)-1;
      const serverDate = timestamp => {
        const timeZone=['S1','S3'].includes(current.environment)?'Etc/GMT+4':'Etc/GMT-8';
        const p=Object.fromEntries(new Intl.DateTimeFormat('en-GB',{timeZone,hourCycle:'h23',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit'}).formatToParts(new Date(timestamp)).map(x=>[x.type,x.value]));
        return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`;
      };
      const users = current.family === 'NPG' ? JSON.parse(current.users) : [];
      const auth = key => users.some(u => u.root === true || u.resources?.some(r => r === key || (typeof r === 'string' && r.endsWith('_') && key.startsWith(r))));
      const invitedCountType = auth('WITHDRAW_AUDIT_USER') && !auth('WITHDRAW_AUDIT_CHANNEL') ? 0
        : !auth('WITHDRAW_AUDIT_USER') && auth('WITHDRAW_AUDIT_CHANNEL') ? 1 : -1;
      const base = current.family === 'TC'
        ? {merchantCode:current.merchant,startDate:serverDate(start),endDate:serverDate(finish),searchDateMode:'requestTime',paymentStatus:'ALL',pid:20009}
        : {countryId:current.country,dtCreated:{start,finish},invitedCountType};
      const page = async (pageNo, pageSize, reviewer) => {
        const params = {...base,pageNo,pageSize,...(reviewer ? current.family === 'TC' ? {reviewOperator:reviewer} : {autherId:reviewer} : {})};
        const p = current.family === 'TC'
          ? await request('/tac/api/relay/get/mcs-v3-player-withdraw-search',params)
          : await request('/api/withdraw_audit_record/page',{query:params},'POST');
        const rows=current.family==='TC'?p.value:p.page?.content;
        const rawTotal=current.family==='TC'?p.totalPageCount:p.page?.totalElements;
        if (!Array.isArray(rows) || !['number','string'].includes(typeof rawTotal) || !/^\d+$/.test(String(rawTotal))
          || !Number.isSafeInteger(Number(rawTotal))) fail('分页数据格式异常');
        return {rows,total:Number(rawTotal)};
      };
      const reviewers = new Set(), seenPages = new Set();
      if (typeof totalsOnly !== 'undefined' && totalsOnly) {
        const p = await page(1, 1); check();
        return {kind:'ok',platformTotal:p.total};
      }
      let fetched=0, complete=false, platformTotal=null;
      for(let n=1;n<=500;n++) {
        const p=await page(n,100);
        if(n===1) platformTotal=p.total;
        const signature=JSON.stringify(p.rows.map(r=>r.id));
        if(p.rows.length && seenPages.has(signature)) fail('分页未前进，未确认完整总数');
        seenPages.add(signature); fetched+=p.rows.length;
        for(const row of p.rows) {
          if (current.family === 'NPG') {
            const id=String(row.autherId ?? '').trim();
            if(id && !['SYSTEM','SYS','AUTO','0','-1'].includes(id.toUpperCase())) reviewers.add(id);
          } else {
            if(row.merchantCode && row.merchantCode !== current.merchant) fail('接口返回其他商户记录');
            for(const key of ['approveAudit','reviewAudit','rejectAudit','paidAudit','rjPaidAudit']) {
              const name=text(row[key]?.lastUpdatedBy);
              if(name && !['SYSTEM','SYS','AUTO','THIRD_PARTY'].includes(name.toUpperCase())) reviewers.add(name);
            }
          }
        }
        if(fetched>=p.total) {complete=true;break;}
        if(!p.rows.length) fail('订单数量变化，请重新获取');
      }
      if(!complete) fail('超过 50000 条，未确认完整人员总数，请缩小日期范围');
      const names = new Map();
      if (current.family === 'NPG' && reviewers.size) {
        const p=await request('/api/account/accounts',{},'POST');
        const list=p.list ?? p.model;
        if(!Array.isArray(list)) fail('审核人员列表格式异常');
        for(const a of list) if(a.id != null && text(a.name || a.username)) names.set(String(a.id),text(a.name || a.username));
      }
      const results=[];
      // Use the same personnel filter's server total as the drill-down page.
      // Never present a partially scanned list or current-page row count as total.
      for(const id of [...reviewers].sort()) {
        const p=await page(1,1,id);
        if(p.total) results.push({id,name:names.get(id)||id,count:p.total});
      }
      check();
      window.__smsReviewerContext={id:requestID,snapshot,startDate,endDate};
      const stamp={id:requestID,fingerprint:await fingerprint(snapshot),startDate,endDate};
      check(); ss.setItem('__smsReviewerContext',JSON.stringify(stamp));
      return {kind:'ok',reviewers:results,platformTotal,family:current.family,contextID:requestID};
    } catch(e) { return {kind:'error',message:e.name==='AbortError'?'请求超时，未确认完整总数':e.message,reviewers:[]}; }
    """#
  static let navigationContext = PendingOrdersScript.context + #"""
    try {
      const current = capture(), snapshot = JSON.stringify(current);
      const permissions = read(ss, 'permission');
      if (current.family === 'TC' && Array.isArray(permissions) && !permissions.map(Number).includes(20009)) fail('无全部提现记录查询权限');
      const stamp = {id:requestID,fingerprint:await fingerprint(snapshot),startDate,endDate};
      if (JSON.stringify(capture()) !== snapshot) fail('账号、国家或商户已变化，请重试');
      window.__smsReviewerContext = {id:requestID,snapshot,startDate,endDate};
      ss.setItem('__smsReviewerContext',JSON.stringify(stamp));
      return {kind:'ok',family:current.family};
    } catch(e) { return {kind:'error',message:e.message}; }
    """#
}
