import {createIcons,Download,RefreshCw,Square,ChevronLeft,ChevronRight} from 'lucide';
const $=selector=>document.querySelector(selector);
const icons=()=>createIcons({icons:{Download,RefreshCw,Square,ChevronLeft,ChevronRight}});
let state,tab='data',page=0,message='',working=false,navigation=0;
const number=n=>n.toLocaleString('zh-CN');
function button(text,target) {
  const b=document.createElement('button');b.className='link';b.textContent=text;
  b.addEventListener('click',async()=>{
    const request=++navigation;
    message='正在打开对应平台…';render();
    try {
      const result=await window.reportApi.navigate(target);
      if(request===navigation){message=result.message||'';render();}
    } catch(e){if(request===navigation){message=e.message;render();}}
  });return b;
}
function render() {
  if(!state)return;
  const reviewers=state.kind==='reviewers',status=tab==='status';
  $('#title').textContent=document.title=reviewers?'提现审核人员查询':'全平台待处理订单';
  $('#data-tab').textContent=reviewers?'审核人员':'订单';
  $('#data-tab').setAttribute('aria-selected',String(!status));$('#status-tab').setAttribute('aria-selected',String(status));
  const focused=document.activeElement;
  for(const [id,value] of [['from',state.start],['through',state.end],['interval',state.settings.interval]])if(focused!==$('#'+id))$('#'+id).value=value;
  $('#auto').checked=state.settings.auto;$('#auto-label').textContent=reviewers?'自动查询':'自动刷新';$('#unit').textContent=reviewers?'分钟':'秒';
  $('#interval').min=reviewers?'1':'5';$('#interval').max=reviewers?'1440':'3600';
  $('#filter').placeholder=reviewers?'平台 / 审核人员':'平台 / 订单号 / 状态';
  const filter=$('#filter').value.trim().toLowerCase(),platform=$('#platform').value;
  const options=JSON.stringify(state.platforms.map(p=>[p.id,p.name]));
  if($('#platform').dataset.options!==options) {
    $('#platform').replaceChildren(new Option('全部平台',''),...state.platforms.map(p=>new Option(p.name,p.id)));
    $('#platform').value=platform;$('#platform').dataset.options=options;
  }
  const list=(status?state.platforms:state.rows).filter(r=>(!platform||(r.platformID||r.id)===platform)
    && [r.platform,r.name,r.id,r.status,r.message].filter(Boolean).join(' ').toLowerCase().includes(filter));
  const pages=Math.max(1,Math.ceil(list.length/10));page=Math.min(page,pages-1);
  const total=reviewers?list.reduce((n,r)=>n+(status?(r.total||0):r.count),0):0;
  $('#column-two').textContent=status?'查询结果':reviewers?'审核人员名称':'订单号';
  $('#column-three').textContent=reviewers?`审核订单总数（合计 ${number(total)}）`:'订单状态 / 查询结果';
  const rows=[];
  for(const r of list.slice(page*10,page*10+10)) {
    const tr=document.createElement('tr'),cells=[0,1,2].map(()=>document.createElement('td'));
    const platformID=r.platformID||r.id;
    if(status&&reviewers)cells[0].append(button(r.name,{platformID,all:true}));else cells[0].textContent=r.platform||r.name;
    if(status) {
      cells[1].textContent=(r.savedAt?new Date(r.savedAt).toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'})+' · ':'')+(r.busy?'查询中 · ':'')+r.message;
      cells[2].textContent=reviewers?(r.total===null?'--':number(r.total)):'--';
    } else if(reviewers) {cells[1].textContent=r.name;cells[2].append(button(number(r.count),{platformID,id:r.id}));}
    else {cells[1].append(button(r.id,{platformID,id:r.id}));cells[2].textContent=r.status;}
    tr.append(...cells);rows.push(tr);
  }
  $('#rows').replaceChildren(...rows);$('#empty').hidden=list.length>0;
  const acquired=state.platforms.filter(p=>p.savedAt).length;
  $('#summary').textContent=`${reviewers?'审核人员':'待处理订单'} ${number(state.rows.length)} ${reviewers?'位':'条'} · 已获取 ${acquired}/${state.platforms.length} 平台 · ${state.running?'查询中':state.message||'未获取'}`;
  $('#message').textContent=message;
  $('#pagination').textContent=`共 ${number(list.length)} 条 · 第 ${page+1} / ${pages} 页 · 每页 10 条`;
  $('#previous').disabled=page===0;$('#next').disabled=page>=pages-1;
  $('#fetch').disabled=working;$('#fetch').innerHTML=`<i data-lucide="${state.running?'square':reviewers?'download':'refresh-cw'}"></i><span>${state.running?'停止':reviewers?'获取':'刷新'}</span>`;icons();
}
async function configure(){
  const result=await window.reportApi.configure({start:$('#from').value,end:$('#through').value,settings:{auto:$('#auto').checked,interval:Number($('#interval').value)}});
  if(result.ok===false)message=result.message;else{state=result;message='';page=0;}render();
}
for(const id of ['from','through','auto','interval'])$('#'+id).addEventListener('change',configure);
for(const id of ['filter','platform'])$('#'+id).addEventListener(id==='filter'?'input':'change',()=>{page=0;render();});
$('#data-tab').onclick=()=>{tab='data';page=0;render();};$('#status-tab').onclick=()=>{tab='status';page=0;render();};
$('#previous').onclick=()=>{page--;render();};$('#next').onclick=()=>{page++;render();};
$('#fetch').onclick=async()=>{
  working=true;message='';render();
  try{const result=state.running?await window.reportApi.cancel():await window.reportApi.fetch();if(result.ok===false)message=result.message;}
  catch(e){message=e.message;}finally{working=false;render();}
};
window.reportApi.onChange(data=>{state=data;render();});
window.reportApi.get().then(data=>{state=data;render();}).catch(e=>{$('#message').textContent=e.message;});
