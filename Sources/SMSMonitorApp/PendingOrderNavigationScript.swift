enum PendingOrderNavigationScript {
  static let route = PendingOrdersScript.context + #"""
    try {
      if (location.origin !== origin) fail('原平台地址已变化，未跳转');
      if (window.__smsMonitorMemoryCompacted) return { kind: 'reload' };
      const reviewer = typeof reviewerQuery !== 'undefined' && reviewerQuery;
      const path = family === 'TC' ? '/20008' : reviewer ? '/withdraw-audit-record-list' : '/withdraw-record-list';
      if (location.pathname.replace(/\/$/, '') === path) return { kind: 'ready' };
      const current = capture();
      if (current.family !== family || current.username !== username || current.country !== country || current.merchant !== merchant) fail('账号、国家或商户已变化，未跳转');
      if (routeIssued) return { kind: 'waiting' };
      const target = path + location.hash;
      const anchor = [...document.querySelectorAll('a[href]')].find(a => {
        try { const u = new URL(a.href, location.href); return u.origin === origin && u.pathname === path && !a.target && !a.hasAttribute('download'); } catch (_) { return false; }
      });
      // Reuse the router's own navigator, including its history listener. Never
      // edit browser history behind the framework or simulate payment actions.
      const seed = document.querySelector('form, main, #root > *, #app > *');
      const key = seed && Object.keys(seed).find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
      let fiber = key && seed[key];
      for (let i = 0; fiber && i < 160; i++, fiber = fiber.return) {
        const p = fiber.memoizedProps;
        const navigator = p?.navigator || p?.history;
        if (navigator && typeof navigator.push === 'function' && typeof navigator.createHref === 'function'
          && (p.location || navigator.location)) {
          navigator.push(target); return { kind: 'routed' };
        }
      }
      if (anchor) { anchor.click(); return { kind: 'routed' }; }
      return { kind: 'reload' };
    } catch (e) { return { kind: 'error', message: e.message }; }
    """#

  static let body = PendingOrdersScript.context + #"""
    try {
      const reviewer = typeof reviewerQuery !== 'undefined' && reviewerQuery;
      const wholePlatform = reviewer && typeof allReviewers !== 'undefined' && allReviewers;
      const filterID = wholePlatform ? '' : orderID;
      if (location.pathname.replace(/\/$/, '') !== (family === 'TC' ? '/20008' : reviewer ? '/withdraw-audit-record-list' : '/withdraw-record-list')) fail('页面已切换，停止搜索订单');
      const visibleAll = selector => [...document.querySelectorAll(selector)].filter(visible);
      const field = family === 'TC'
        ? visibleAll(reviewer ? '.player-withdraw-action-bar input#reviewOperator' : '.player-withdraw-action-bar input#id')[0]
        : visibleAll(reviewer ? 'input#autherIdX, input[placeholder="审核人ID过滤"], input[placeholder="Auditor Id Filter"]' : 'input[placeholder="ID"]')[0];
      if (!field) return { kind: 'waiting' };
      const current = capture();
      const identity = JSON.stringify(current);
      if (current.origin !== origin || current.family !== family || current.username !== username || current.country !== country || current.merchant !== merchant) fail('账号、国家或商户已变化，未搜索订单');
      const root = field.closest('form');
      if (!root) fail('找不到提现搜索表单');
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      const pause = () => new Promise(resolve => setTimeout(resolve, 160));
      const fiberFor = element => {
        const key = Object.keys(element).find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
        return key && element[key];
      };
      const dateRange = dates => dates.map((v, i) => {
        const [y, m, d] = (i ? endDate : startDate).split('-').map(Number);
        return v.clone().date(1).year(y).month(m - 1).date(d).hour(i ? 23 : 0).minute(i ? 59 : 0).second(i ? 59 : 0).millisecond(i ? 999 : 0);
      });
      let formFiber = fiberFor(root), form = null;
      for (let i = 0; formFiber && i < 40; i++, formFiber = formFiber.return) {
        const f = formFiber.memoizedProps?.form;
        if (f && typeof f.getFieldValue === 'function' && typeof f.getFieldsValue === 'function'
          && typeof f.setFieldsValue === 'function') { form = f; break; }
      }
      if (!form) fail('搜索表单尚未就绪，未修改筛选条件');
      const cleared = Object.fromEntries(Object.keys(form.getFieldsValue(true)).map(k => [k, family === 'NPG' ? null : undefined]));
      if (family === 'TC') {
        const titles = ['全部', 'All'];
        const tab = visibleAll('#player-withdraw-list [role="tab"]').find(e => titles.includes(e.textContent.replace(/\s+/g, '')));
        if (!tab) fail('未找到全部订单页签');
        if (tab.getAttribute('aria-selected') !== 'true') { tab.click(); await pause(); }
      }
      const pickers = [...root.querySelectorAll('.lt-date-range-picker, .ant-picker-range')].filter(visible);
      const dates = pickers[0] ? [...pickers[0].querySelectorAll('input')].filter(visible) : [];
      // Reused pages retain filters. Clear every registered filter in the form
      // store before applying the exact ID and the collection date range.
      const values = family === 'TC' ? [startDate + ' 00:00:00', endDate + ' 23:59:59'] : [startDate, endDate];
      let expectedRange = null;
      if (family === 'NPG') {
        // NPG's AntD 3 range picker has one read-only display input. Update its
        // controlled range through the existing component callback, not DOM text.
        const picker = pickers[0];
        let fiber = picker && fiberFor(picker), props = null;
        for (let i = 0; fiber && i < 40; i++, fiber = fiber.return) {
          const p = fiber.memoizedProps;
          if (p?.className?.includes('lt-date-range-picker') && typeof p.onChange === 'function') { props = p; break; }
        }
        if (!props || typeof props.format !== 'string') fail('日期组件未就绪，未自动搜索');
        const validDates = v => Array.isArray(v) && v.length === 2 && v.every(d => d && typeof d.clone === 'function' && typeof d.format === 'function');
        const selected = validDates(props.value) ? props.value : Object.values(props.ranges || {}).find(validDates);
        if (!selected) fail('日期组件未就绪，未自动搜索');
        const range = dateRange(selected);
        expectedRange = range.map(v => v.valueOf());
        form.setFieldsValue({...cleared, ...(reviewer ? {autherId:wholePlatform?null:filterID,autherIdX:filterID,countryId:country} : {id:filterID}),
          dtCreated: {start: expectedRange[0], finish: expectedRange[1]}});
        await pause();
      } else {
        // Use the site's controlled AntD Form store so both the order ID and
        // Dayjs range reach onFinish; assigning DOM input text alone is insufficient.
        const selected = form?.getFieldValue('date');
        if (!Array.isArray(selected) || selected.length !== 2 || selected.some(d => !d || typeof d.clone !== 'function')) fail('提现搜索表单尚未就绪');
        if (reviewer) {
          const addon = field.closest('.ant-input-group')?.querySelector('.ant-input-group-addon .ant-select');
          let f = addon && fiberFor(addon);
          for(let i=0;f && i<30;i++,f=f.return) {
            const p=f.memoizedProps;
            if(Array.isArray(p?.options) && p.options.some(o=>o.value==='Third_Party') && typeof p.onChange==='function') {
              p.onChange(''); await pause(); break;
            }
          }
        }
        form.setFieldsValue({...cleared, ...(reviewer ? {reviewOperator:filterID,reviewOperatorType:''} : {id:filterID}), date: dateRange(selected), searchDateMode:'requestTime',
          bankAccountIds:[], internalLevelNames:[], isFirst:'', paymentStatus:'ALL', withdrawalMethod:''});
        await pause();
        if (String(form.getFieldValue(reviewer ? 'reviewOperator' : 'id') ?? '') !== filterID) fail('查询条件未进入搜索表单');
      }
      if (family === 'NPG') {
        const previous = field.value; setter.call(field, filterID); field._valueTracker?.setValue(previous);
        field.dispatchEvent(new Event('input', { bubbles: true })); field.dispatchEvent(new Event('change', { bubbles: true }));
        field.dispatchEvent(new Event('blur', { bubbles: true })); await pause();
      }
      if (field.value !== filterID || (family === 'TC' && dates.some((e, i) => e.value.replaceAll('/', '-') !== values[i]))) fail('搜索条件未保存，请手动确认');
      // For an unfiltered platform search, an unrelated auto-refresh request
      // must not be mistaken for our submission. Check the exact server range.
      let serverRange = null;
      if (reviewer && family === 'TC') {
        const formatter = new Intl.DateTimeFormat('en-CA',{timeZone:current.timezone,year:'numeric',month:'2-digit',day:'2-digit'});
        const boundary = day => {
          let lo=day*86400000-129600000,hi=day*86400000+129600000;
          while(lo<hi){const m=Math.floor((lo+hi)/2),p=Object.fromEntries(formatter.formatToParts(new Date(m)).map(x=>[x.type,x.value]));
            if(Date.UTC(+p.year,+p.month-1,+p.day)/86400000<day)lo=m+1;else hi=m;}
          return lo;
        };
        const stamp = timestamp => {
          const p=Object.fromEntries(new Intl.DateTimeFormat('en-GB',{timeZone:['S1','S3'].includes(current.environment)?'Etc/GMT+4':'Etc/GMT-8',hourCycle:'h23',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit'}).formatToParts(new Date(timestamp)).map(x=>[x.type,x.value]));
          return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`;
        };
        serverRange=[stamp(boundary(Date.parse(startDate+'T00:00:00Z')/86400000)),stamp(boundary(Date.parse(endDate+'T00:00:00Z')/86400000+1)-1)];
      }
      if (JSON.stringify(capture()) !== identity) fail('会话已变化，未执行搜索');
      const buttons = [...root.querySelectorAll('button')].filter(b => visible(b) && !b.disabled && /^(搜索|查询|Search)$/i.test(b.textContent.replace(/\s+/g, '')));
      if (buttons.length !== 1) fail('无法唯一确认搜索按钮，未执行');
      let submitted = false, total = null, responseDone = false;
      const inspect = (url, body) => {
        let matched = false;
        try {
          const parsed = new URL(url, location.origin);
          if (parsed.origin !== location.origin) return;
          if (family === 'TC' && /^\/tac\/api\/relay\/get\/mcs-v3-player-withdraw-search(?:PendingApproval|Pending2ndApproval|PendingPayment)?$/.test(parsed.pathname)) {
            if ((parsed.searchParams.get(reviewer ? 'reviewOperator' : 'id') ?? '') === filterID && parsed.searchParams.get('merchantCode') === merchant
              && (!reviewer || (!parsed.searchParams.get('id') && !parsed.searchParams.get('reviewOperatorType') && parsed.searchParams.get('searchDateMode') === 'requestTime'))
              && (!reviewer || (parsed.pathname === '/tac/api/relay/get/mcs-v3-player-withdraw-search'
                && parsed.searchParams.get('startDate') === serverRange[0] && parsed.searchParams.get('endDate') === serverRange[1]))) matched = true;
          }
          if (family === 'NPG' && parsed.pathname === (reviewer ? '/api/withdraw_audit_record/page' : '/api/withdraw_record/page')) {
            const p = JSON.parse(body);
            if ((wholePlatform ? !p.query?.autherId && !p.query?.autherIdX && !p.query?.id && p.query?.countryId === country : String(reviewer ? p.query?.autherId : p.query?.id) === filterID)
              && (!reviewer || (!p.query?.withdrawOrderId && !p.query?.status)) && Number(p.query?.dtCreated?.start) === expectedRange?.[0]
              && Number(p.query?.dtCreated?.finish) === expectedRange?.[1]) matched = true;
          }
        } catch (_) {}
        return matched;
      };
      const inspectResponse = (status, payload) => {
        if (responseDone) return;
        responseDone = true;
        if (status < 200 || status >= 300 || (family === 'TC' ? payload?.success !== true : ![0,'0','OK','SUCCESS'].includes(payload?.status ?? payload?.code))) return;
        const raw = family === 'TC' ? payload.totalPageCount : payload.page?.totalElements;
        if (['number','string'].includes(typeof raw) && /^\d+$/.test(String(raw)) && Number.isSafeInteger(Number(raw))) total = Number(raw);
      };
      const originalFetch = window.fetch, originalOpen = XMLHttpRequest.prototype.open, originalSend = XMLHttpRequest.prototype.send;
      const urls = new WeakMap();
      function observedFetch(url, options) {
        const matched = inspect(typeof url === 'string' ? url : url.url, options?.body);
        if (matched) submitted = true;
        const response = originalFetch.apply(this, arguments);
        if (matched && reviewer) response.then(r => r.clone().json().then(p => inspectResponse(r.status, p))).catch(() => { responseDone = true; });
        return response;
      }
      function observedOpen(method, url) { urls.set(this, url); return originalOpen.apply(this, arguments); }
      function observedSend(body) {
        if (inspect(urls.get(this), body)) {
          submitted = true;
          if (reviewer) this.addEventListener('loadend', () => {
            try { inspectResponse(this.status, this.responseType === 'json' ? this.response : JSON.parse(this.responseText)); }
            catch (_) { responseDone = true; }
          }, {once:true});
        }
        return originalSend.apply(this, arguments);
      }
      window.fetch = observedFetch; XMLHttpRequest.prototype.open = observedOpen; XMLHttpRequest.prototype.send = observedSend;
      try {
        buttons[0].click();
        const responseDeadline = Date.now() + (reviewer ? 15000 : 5000);
        while (Date.now() < responseDeadline && (!submitted || (reviewer && !responseDone))) await pause();
        if (submitted) {
          if (JSON.stringify(capture()) !== identity) fail('会话已变化，请刷新订单');
          // A cold page restoration loses window globals, but the native caller
          // already validated this context before routing. Retain it for the next order.
          if (reviewer) {
            window.__smsReviewerContext = {id: contextID, snapshot: identity, startDate, endDate};
            ss.setItem('__smsReviewerContext',JSON.stringify({id:contextID,fingerprint:await fingerprint(identity),startDate,endDate}));
          }
          else window.__smsPendingOrdersContext = {id: contextID, snapshot: identity, startDate, endDate};
        }
        if (reviewer && submitted && total === null) return {kind:'error',message:'已搜索，但未取得有效的接口总条数，未更新汇总'};
        return submitted ? { kind: 'ok', ...(reviewer ? {total} : {}) } : { kind: 'error', message: '已设置查询条件，但未确认搜索请求，请在原平台检查' };
      } finally {
        if (window.fetch === observedFetch) window.fetch = originalFetch;
        if (XMLHttpRequest.prototype.open === observedOpen) XMLHttpRequest.prototype.open = originalOpen;
        if (XMLHttpRequest.prototype.send === observedSend) XMLHttpRequest.prototype.send = originalSend;
      }
    } catch (e) { return { kind: 'error', message: e.message }; }
    """#
}
