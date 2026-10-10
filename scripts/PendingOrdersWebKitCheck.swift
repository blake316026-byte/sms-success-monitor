import AppKit
import WebKit

@MainActor final class PendingOrdersWebKitCheck: NSObject, WKNavigationDelegate {
  private var page: WKWebView!
  func start() {
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    page = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 500), configuration: config)
    page.navigationDelegate = self
    page.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://orders-test.invalid/20008")!)
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
      self.page.evaluateJavaScript("window.fixtureStep") { value, _ in print("Timeout at \(value ?? "unknown")"); self.finish(false) }
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let script = #"""
      sessionStorage.setItem('merchants', JSON.stringify([{merchantCode:'m'}]));
      sessionStorage.setItem('merchantParam', 'm'); sessionStorage.setItem('user', '{"operatorName":"fixture"}');
      sessionStorage.setItem('tabIsLogin', '1'); sessionStorage.setItem('token', 'fixture-token');
      localStorage.setItem('TOKEN', 'fixture-token');
      localStorage.setItem('operatorCustomization', '{"customTimezone":"Etc/GMT-8"}');
      let requests = [];
      const momentFixture = (timestamp=Date.UTC(2026,9,10)) => {
        let d=new Date(timestamp);
        const obj={clone:()=>momentFixture(d.getTime()),valueOf:()=>d.getTime(),format:()=>d.toISOString().slice(0,19).replace('T',' ').replaceAll('-','/')};
        for (const [name,method] of [['date','setUTCDate'],['year','setUTCFullYear'],['month','setUTCMonth'],['hour','setUTCHours'],['minute','setUTCMinutes'],['second','setUTCSeconds'],['millisecond','setUTCMilliseconds']]) obj[name]=v=>{d[method](v);return obj};
        return obj;
      };
      window.fetch = async (url, options) => { requests.push(url); return new Response(JSON.stringify({status:0,page:{totalElements:355},success:true,totalPageCount:1,value:[{id:123,status:'NEW',merchantCode:'m'}]}),{status:200}); };
      const expectedUsername='fixture',allowNPG=true,requestID='fixture',contextID='fixture',startDate='2026-10-04',endDate='2026-10-10';
      window.fixtureStep='pending';
      """# + "\nconst result = await (async()=> {\(PendingOrdersScript.query)})();\n" + #"""
      if(result.kind!=='ok'||result.orders.length!==1||requests.length!==3) return false;
      document.body.innerHTML='<form><div class="player-withdraw-action-bar"><input id="id"></div><div class="ant-picker-range"><input><input></div><button type="button">搜 索</button></form><div id="player-withdraw-list"><div role="tab" aria-selected="true">全部</div></div>';
      const formState={date:[momentFixture(),momentFixture()], username:'old-user', status:['PAID'], amountFromStr:'99999'};
      document.querySelector('form').__reactFiber$fixture={memoizedProps:{form:{
        getFieldValue:k=>formState[k], getFieldsValue:()=>({...formState}), submit:()=>{}, setFieldsValue:values=>{Object.assign(formState,values);
          document.querySelector('#id').value=values.id;
          document.querySelectorAll('.ant-picker-range input').forEach((e,i)=>e.value=values.date[i].format().replaceAll('/','-'));
        }
      }}};
      document.querySelector('button').onclick = () => fetch('https://orders-test.invalid/tac/api/relay/get/mcs-v3-player-withdraw-search?id='+formState.id+'&merchantCode=m', {method:'GET'});
      const family='TC',username='fixture',country='',merchant='m',orderStatus='待处理',origin='https://orders-test.invalid',routeIssued=false;
      let orderID='123';
      const originalFetch=window.fetch;
      window.reuseSentinel=12345;
      """# + "\nconst readyRoute = await (async()=> {\(PendingOrderNavigationScript.route)})();\n" + #"""
      if(readyRoute.kind!=='ready') return false;
      window.__smsPendingOrdersContext=null;
      """# + "\nconst navigation = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
      if (!(navigation.kind==='ok' && document.querySelector('#id').value==='123'
        && window.fetch===originalFetch && requests.length===4 && !formState.username && !formState.status && !formState.amountFromStr
        && window.__smsPendingOrdersContext?.id===contextID)) return false;
      orderID='456'; formState.username='another-stale-user';
      """# + "\nconst secondNavigation = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
      if(secondNavigation.kind!=='ok'||formState.id!=='456'||formState.username||window.reuseSentinel!==12345||requests.length!==5) return false;
      history.replaceState({},'', '/reports');
      let routeMoves=0;
      document.querySelector('form').__reactFiber$fixture.return={memoizedProps:{location:{pathname:'/reports'},navigator:{createHref:x=>x,push:path=>{routeMoves++;history.replaceState({},'',path)}}}};
      """# + "\nconst internalRoute = await (async()=> {\(PendingOrderNavigationScript.route)})();\n" + #"""
      if(internalRoute.kind!=='routed'||routeMoves!==1||location.pathname!=='/20008'||window.reuseSentinel!==12345) return false;
      window.__smsMonitorMemoryCompacted=true;
      """# + "\nconst coldRoute = await (async()=> {\(PendingOrderNavigationScript.route)})();\n" + #"""
      if(coldRoute.kind!=='reload') return false;
      window.__smsMonitorMemoryCompacted=false;
      sessionStorage.clear(); localStorage.clear();
      sessionStorage.setItem('lt-user', JSON.stringify({username:'fixture',token:'fixture-token',root:true}));
      sessionStorage.setItem('COUNTRY', 'PH');
      history.replaceState({},'', '/withdraw-record-list');
      document.body.innerHTML='<form><input placeholder="ID"><span class="lt-date-range-picker"><input readonly></span><button type="button">搜索</button></form>';
      let dateQuery=null;
      const npgState={id:'old-order',status:'PAID',userName:'old-user',amountRange:{min:9999},dtPaidTime:{start:1,finish:2}};
      document.querySelector('form').__reactFiber$fixture={memoizedProps:{form:{getFieldValue:k=>npgState[k],getFieldsValue:()=>({...npgState}),setFieldsValue:values=>{
        Object.assign(npgState,values); dateQuery=values.dtCreated; document.querySelector('input').value=values.id;
      }}}};
      document.querySelector('.lt-date-range-picker').__reactFiber$fixture={memoizedProps:{className:'lt-date-range-picker',format:'YYYY/MM/DD HH:mm:ss',value:[momentFixture(),momentFixture()],onChange:range=>{dateQuery={start:range[0].valueOf(),finish:range[1].valueOf()}}}};
      document.querySelector('button').onclick=()=>fetch('https://orders-test.invalid/api/withdraw_record/page',{body:JSON.stringify({query:{id:document.querySelector('input').value,dtCreated:dateQuery}})});
      {
        const family='NPG',username='fixture',country='PH',merchant='',orderID='W123',orderStatus='待审核',origin='https://orders-test.invalid';
      """# + "\nconst npgNavigation = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
        if (!(npgNavigation.kind==='ok' && document.querySelector('input').value==='W123' && requests.length===6
          && !npgState.userName && !npgState.status && !npgState.amountRange && !npgState.dtPaidTime
          && dateQuery.start===Date.UTC(2026,9,4) && dateQuery.finish===Date.UTC(2026,9,10,23,59,59,999))) return false;
      }
      history.replaceState({},'', '/withdraw-audit-record-list');
      window.fixtureStep='NPG reviewer';
      document.querySelector('input').id='autherIdX';
      npgState.withdrawOrderId='old-withdrawal'; npgState.autherId='old-reviewer'; npgState.status='PENDING';
      document.querySelector('form').__reactFiber$fixture.memoizedProps.form.setFieldsValue=values=>{
        Object.assign(npgState,values);dateQuery=values.dtCreated;document.querySelector('#autherIdX').value=values.autherIdX;
      };
      document.querySelector('button').onclick=()=>fetch('https://orders-test.invalid/api/withdraw_audit_record/page',{body:JSON.stringify({query:npgState})});
      {
        const family='NPG',username='fixture',country='PH',merchant='',origin='https://orders-test.invalid',reviewerQuery=true;
        let orderID='auditor-a';
      """# + "\nconst firstReviewer = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
        if(firstReviewer.kind!=='ok'||npgState.autherId!=='auditor-a'||npgState.withdrawOrderId||npgState.status||npgState.countryId!=='PH')return false;
        orderID='auditor-b';
      """# + "\nconst nextReviewer = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
        if(nextReviewer.kind!=='ok'||npgState.autherId!=='auditor-b'||window.__smsReviewerContext?.id!==contextID||window.reuseSentinel!==12345)return false;
        {
          const allReviewers=true,startDate='2026-10-10',endDate='2026-10-10';
      """# + "\nconst npgPlatform = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
          if(npgPlatform.kind!=='ok'||npgPlatform.total!==355||npgState.autherId||npgState.autherIdX||npgState.withdrawOrderId||npgState.status||npgState.id
            ||dateQuery.start!==Date.UTC(2026,9,10)||dateQuery.finish!==Date.UTC(2026,9,10,23,59,59,999)||window.reuseSentinel!==12345)return false;
        }
        orderID='auditor-a';
      """# + "\nconst npgReturnToReviewer = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
        if(npgReturnToReviewer.kind!=='ok'||npgState.autherId!=='auditor-a')return false;
        const nativeXHR=window.XMLHttpRequest;
        window.fixtureStep='XHR';
        class FixtureXHR extends EventTarget {
          open(method,url){this.url=url;}
          send(body){this.status=200;this.responseType='json';this.response={status:0,page:{totalElements:777}};setTimeout(()=>this.dispatchEvent(new Event('loadend')),50);}
        }
        window.XMLHttpRequest=FixtureXHR;
        document.querySelector('button').onclick=()=>{const x=new XMLHttpRequest();x.open('POST','https://orders-test.invalid/api/withdraw_audit_record/page');x.send(JSON.stringify({query:npgState}));};
      """# + "\nconst xhrReviewer = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
        if(xhrReviewer.kind!=='ok'||xhrReviewer.total!==777)return false;
        window.XMLHttpRequest=nativeXHR;
        const previousFetch=window.fetch;
        window.fetch=async()=>new Response(JSON.stringify({status:0,page:{totalElements:0}}));
        document.querySelector('button').onclick=()=>fetch('https://orders-test.invalid/api/withdraw_audit_record/page',{body:JSON.stringify({query:npgState})});
      """# + "\nconst zeroReviewer = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
        if(zeroReviewer.kind!=='ok'||zeroReviewer.total!==0)return false;
        window.fetch=async()=>new Response(JSON.stringify({status:0,page:{totalElements:null}}));
      """# + "\nconst invalidReviewer = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
        if(invalidReviewer.kind!=='error')return false;
        window.fetch=previousFetch;
      }
      sessionStorage.clear();localStorage.clear();
      window.fixtureStep='TC reviewer';
      sessionStorage.setItem('merchants','[{"merchantCode":"m"}]');sessionStorage.setItem('merchantParam','m');
      sessionStorage.setItem('user','{"operatorName":"fixture"}');sessionStorage.setItem('tabIsLogin','1');sessionStorage.setItem('token','fixture-token');
      localStorage.setItem('TOKEN','fixture-token');
      localStorage.setItem('operatorCustomization','{"customTimezone":"Etc/GMT-8"}');sessionStorage.setItem('environment','S1');
      history.replaceState({},'', '/20008');
      document.body.innerHTML='<form><div class="player-withdraw-action-bar"><div class="ant-input-group"><div class="ant-input-group-addon"><div class="ant-select"></div></div><input id="reviewOperator" disabled></div></div><div class="ant-picker-range"><input><input></div><button type="button">搜 索</button></form><div id="player-withdraw-list"><div role="tab" aria-selected="true">全部</div></div>';
      let reviewerType='Third_Party';
      document.querySelector('.ant-select').__reactFiber$fixture={memoizedProps:{options:[{value:'Third_Party'},{value:''}],onChange:v=>{reviewerType=v;document.querySelector('#reviewOperator').disabled=false}}};
      const reviewerState={id:'old-order',username:'old-user',status:['PAID'],reviewOperator:'old-person',date:[momentFixture(),momentFixture()]};
      document.querySelector('form').__reactFiber$fixture={memoizedProps:{form:{getFieldValue:k=>reviewerState[k],getFieldsValue:()=>({...reviewerState}),setFieldsValue:values=>{
        Object.assign(reviewerState,values);document.querySelector('#reviewOperator').value=values.reviewOperator;
        document.querySelectorAll('.ant-picker-range input').forEach((e,i)=>e.value=values.date[i].format().replaceAll('/','-'));
      }}}};
      document.querySelector('button').onclick=()=>fetch('https://orders-test.invalid/tac/api/relay/get/mcs-v3-player-withdraw-search?'+new URLSearchParams({reviewOperator:reviewerType?'':reviewerState.reviewOperator,merchantCode:'m',searchDateMode:reviewerState.searchDateMode,startDate:'2026-10-03 12:00:00',endDate:'2026-10-10 11:59:59'}),{});
      {
        const reviewerQuery=true; let orderID='alice';
      """# + "\nconst tcReviewer = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
        if(tcReviewer.kind!=='ok'||reviewerType||reviewerState.id||reviewerState.username||reviewerState.status||reviewerState.reviewOperator!=='alice')return false;
        orderID='bob';
      """# + "\nconst tcNextReviewer = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
        if(tcNextReviewer.kind!=='ok'||reviewerState.reviewOperator!=='bob'||window.reuseSentinel!==12345)return false;
        {
          const allReviewers=true,startDate='2026-10-10',endDate='2026-10-10';
          window.fixtureStep='TC platform';
          reviewerType='Third_Party';reviewerState.id='stale-order';reviewerState.status=['PAID'];
          document.querySelector('button').onclick=()=>fetch('https://orders-test.invalid/tac/api/relay/get/mcs-v3-player-withdraw-search?'+new URLSearchParams({
            reviewOperator:reviewerType?'stale-third-party':reviewerState.reviewOperator,merchantCode:'m',searchDateMode:reviewerState.searchDateMode,
            startDate:'2026-10-09 12:00:00',endDate:'2026-10-10 11:59:59'}),{});
      """# + "\nconst tcPlatform = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
          if(tcPlatform.kind!=='ok'||tcPlatform.total!==1||reviewerState.reviewOperator||reviewerState.id||reviewerState.status||reviewerType||window.reuseSentinel!==12345)return false;
          document.querySelector('button').onclick=()=>fetch('https://orders-test.invalid/tac/api/relay/get/mcs-v3-player-withdraw-search?'+new URLSearchParams({
            merchantCode:'m',searchDateMode:'requestTime',startDate:'2026-10-01 12:00:00',endDate:'2026-10-02 11:59:59'}),{});
          window.fixtureStep='wrong date';
      """# + "\nconst tcWrongDates = await (async()=> {\(PendingOrderNavigationScript.body)})();\n" + #"""
          if(tcWrongDates.kind!=='error')return false;
        }
      }
      return true;
      """#
    page.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
      if case .failure(let error) = result { print(error.localizedDescription) }
      if (try? result.get()) as? Bool == true { self.finish(true) }
      else { self.page.evaluateJavaScript("window.fixtureStep") { value, _ in print("Failed at \(value ?? "unknown")"); self.finish(false) } }
    }
  }
  private func finish(_ passed: Bool) {
    print("\(passed ? "PASS" : "FAIL"): native WebKit orders, reviewer and whole-platform searches without payment actions")
    exit(passed ? 0 : 1)
  }
}
@main struct PendingOrdersWebKitCheckMain {
  @MainActor static func main() {
    let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
    let check = PendingOrdersWebKitCheck(); check.start(); app.run()
  }
}
