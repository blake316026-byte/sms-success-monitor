import fs from 'node:fs';

// Keep the injected API and controlled-form contracts identical to macOS.
export function queryScripts() {
  const blocks = (name, count) => {
    const source = fs.readFileSync(new URL('../../../Sources/SMSMonitorApp/' + name + '.swift', import.meta.url), 'utf8');
    const values = [...source.matchAll(/#"""([\s\S]*?)"""#/g)].map(match => match[1]);
    if (values.length !== count) throw new Error('Unexpected script layout: ' + name);
    return values;
  };
  const [context, pending, validate] = blocks('PendingOrdersScript', 3);
  const [reviewers, prepare] = blocks('WithdrawalReviewersScript', 2);
  const [route, search] = blocks('PendingOrderNavigationScript', 2);
  return {
    pending: context + pending, reviewers: context + reviewers,
    validate: context + validate, prepare: context + prepare,
    route: context + route, search: context + search,
    probe: context + `try { const c = capture(); return {kind:'ok', family:c.family,
      identity:JSON.stringify([c.origin,c.family,c.username,c.country,c.merchant])};
      } catch(e) { return {kind:'error',message:e.message}; }`
  };
}

export function nativeQueryFixture() {
  const source=fs.readFileSync(new URL('../../../scripts/PendingOrdersWebKitCheck.swift',import.meta.url),'utf8');
  const expression=source.split('let script = ')[1]?.split('\n    page.callAsyncJavaScript')[0];
  if(!expression)throw new Error('Missing native query fixture');
  const scripts=queryScripts(),mapping={'PendingOrdersScript.query':scripts.pending,
    'PendingOrderNavigationScript.route':scripts.route,'PendingOrderNavigationScript.body':scripts.search};
  let output='',end=0;
  for(const match of expression.matchAll(/#"""([\s\S]*?)"""#|"(?:\\.|[^"\\])*"/g)) {
    if(!/^[\s+]*$/.test(expression.slice(end,match.index)))throw new Error('Unsupported fixture expression');
    if(match[1]!==undefined)output+=match[1];
    else output+=JSON.parse(match[0].replace(/\\\(([\w.]+)\)/g,(_,key)=>{
      if(!mapping[key])throw new Error('Unknown fixture script: '+key);
      return '__SCRIPT_'+key+'__';
    })).replace(/__SCRIPT_([\w.]+)__/g,(_,key)=>mapping[key]);
    end=match.index+match[0].length;
  }
  if(expression.slice(end).trim())throw new Error('Trailing fixture expression');
  return output;
}
