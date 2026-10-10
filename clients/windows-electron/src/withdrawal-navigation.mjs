import crypto from 'node:crypto';

export class WithdrawalNavigation {
  constructor({reports, source, execute, show, selected, load, now = Date.now, pause = ms => new Promise(resolve => setTimeout(resolve, ms))}) {
    Object.assign(this,{reports,source,execute,show,selected,load,now,pause});
    this.serial=Promise.resolve();this.current='';this.previous=null;
  }
  open(target) {
    const navID=crypto.randomUUID();this.current=navID;
    if(this.previous) void this.execute(this.previous,'invalidateNavigation',{navID}).catch(()=>{});
    const task=this.serial.catch(()=>{}).then(()=>this.run(target,navID));
    this.serial=task;return task;
  }
  async run(target,navID) {
    const check=()=>{
      const source=this.source(target.platformID);
      if(this.current!==navID)throw new Error('已切换到新的查询');
      if(!source || JSON.stringify([source.id,source.url,source.account||''])!==target.scope)throw new Error('平台或账号配置已变化');
      if(this.selected()!==source.id)throw new Error('平台已切换，停止搜索');
      return source;
    };
    if(this.current!==navID)throw new Error('已切换到新的查询');
    this.show(target.platformID);
    let source=check();this.previous=source;
    await this.execute(source,'invalidateNavigation',{navID});check();
    this.reports.locked.add(source.id);
    for(const kind of ['pending','reviewers'])this.reports.cancel(kind,source.id);
    const deadline=this.now()+90000;
    const args={expectedUsername:source.account||'',allowNPG:source.allowNPG!==false,
      requiredNPGPermission:target.kind==='reviewers'?'WITHDRAW_AUDIT_RECORD_LIST':'WITHDRAW_RECORD_LIST',
      startDate:target.start,endDate:target.end,contextID:target.contextID,requestID:navID,
      reviewerQuery:target.kind==='reviewers',allReviewers:target.all,orderID:target.id,navID};
    try {
      // Wait for cancellation cleanup before sharing this page with a form search.
      while(['pending','reviewers'].some(k=>this.reports.states[k].jobs.has(source.id))) {
        check();if(this.now()>deadline)throw new Error('原查询未结束，请稍后重试');await this.pause(100);
      }
      for(;;) {
        source=check();
        if(this.now()>deadline)throw new Error('平台加载超时，请完成登录后重试');
        if(!source.ready){await this.pause(250);continue;}
        const probe=await this.execute(source,'probe',args);check();
        if(probe.kind!=='ok') {
          if(/未就绪|尚未加载|页面验证/.test(probe.message)){await this.pause(500);continue;}
          throw new Error(probe.message);
        }
        if(target.identity && probe.identity!==target.identity)throw new Error('账号、国家或商户已变化，请重新获取');
        args.family=probe.family;
        if(target.kind==='reviewers' && (!target.contextID || target.all)) {
          const prepared=await this.execute(source,'prepare',args);check();
          if(prepared.kind!=='ok')throw new Error(prepared.message);
          args.contextID=navID;
        }
        break;
      }
      const context=await this.execute(source,'validate',args);check();
      if(context.kind!=='ok')throw new Error(context.message);
      Object.assign(args,context,{routeIssued:false});
      const destination=new URL(source.currentURL);
      destination.pathname=args.family==='TC'?'/20008':args.reviewerQuery?'/withdraw-audit-record-list':'/withdraw-record-list';
      destination.search='';
      let reloaded=false;
      for(;;) {
        source=check();
        if(this.now()>deadline)throw new Error('跳转或搜索超时');
        if(!source.ready){await this.pause(200);continue;}
        const route=await this.execute(source,'route',args);check();
        if(route.kind==='ready') {
          const result=await this.execute(source,'search',args);check();
          if(result.kind==='waiting'){await this.pause(250);continue;}
          if(result.kind!=='ok')throw new Error(result.message);
          if(args.reviewerQuery)this.reports.updateTotal(target,result.total);
          return {ok:true,message:target.all?'已查询今天的记录（不限审核人员）':'已在原平台搜索对应记录'};
        }
        if(route.kind==='reload' && !reloaded){reloaded=true;await this.load(source,destination.href);check();}
        else if(!['routed','waiting'].includes(route.kind))throw new Error(route.message||'页面未就绪');
        args.routeIssued=true;await this.pause(150);
      }
    } finally {this.reports.locked.delete(target.platformID);}
  }
}
