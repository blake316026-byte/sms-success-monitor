const $=id=>document.getElementById(id);
let snapshot,view='records',saving=false,selecting=false,revision=0;
const display=value=>new Date(value).toLocaleString('zh-CN',{timeZone:'Asia/Shanghai',hour12:false});
function render() {
  if(!snapshot)return;
  const count=snapshot.platforms.filter(p=>p.selected).length;
  $('alerts-status').textContent=snapshot.message+` · 已勾选 ${count}/${snapshot.platforms.length} 平台`;
  $('alerts-save').disabled=saving||selecting||snapshot.blocked;
  $('alerts-records').setAttribute('aria-selected',String(view==='records'));
  $('alerts-platforms').setAttribute('aria-selected',String(view==='platforms'));
  const platformView=view==='platforms';
  const headers=platformView?['TG 报警','平台','查询结果']:['平台','订单号','时间（北京时间）','结果'];
  const head=document.createElement('tr');
  for(const title of headers){const th=document.createElement('th');th.textContent=title;head.append(th);}
  $('alerts-columns').replaceChildren(head);
  document.querySelector('.alerts-table').classList.toggle('platform-selection',platformView);
  const rows=!platformView?snapshot.records.map(r=>[r.platform,r.orderID,display(r.at),r.state])
    :snapshot.platforms.map(r=>[r.name,r.message]);
  $('alerts-rows').replaceChildren(...rows.map((row,index)=>{
    const tr=document.createElement('tr');
    if(platformView) {
      const platform=snapshot.platforms[index],td=document.createElement('td'),checkbox=document.createElement('input');
      checkbox.type='checkbox';checkbox.checked=platform.selected===true;
      checkbox.disabled=saving||selecting||snapshot.blocked;
      checkbox.setAttribute('aria-label',platform.name+' TG 报警');
      checkbox.title='是否向 TG 发送此平台的挂单报警';
      checkbox.onchange=async()=>{
        const selected=checkbox.checked;revision++;selecting=true;$('alerts-error').textContent='';render();
        try {
          const result=await window.reportApi.selectAlertPlatform(platform.id,selected);
          if(result.ok===false)$('alerts-error').textContent=result.message;else snapshot=result;
        }catch{$('alerts-error').textContent='平台选择保存失败，仍使用原来的选择';}
        finally{selecting=false;render();}
      };
      td.append(checkbox);tr.append(td);
    }
    for(const value of row){const td=document.createElement('td');td.textContent=value;tr.append(td);}
    return tr;
  }));
  $('alerts-empty').hidden=rows.length>0;
}
async function refresh(fill=false) {
  const request=revision;
  try {
    const result=await window.reportApi.alerts();
    if(request!==revision||saving||selecting||!$('alerts-dialog').open)return;
    snapshot=result;
    if(fill) {
      $('alerts-enabled').checked=snapshot.settings.enabled;
      $('alerts-minutes').value=snapshot.settings.minutes;
      $('alerts-days').value=snapshot.settings.lookbackDays;
      $('alerts-group').value=snapshot.settings.chatID;
      $('alerts-token').value='';
      $('alerts-token').placeholder=snapshot.settings.hasToken?'已保存，留空保持不变':'机器人 Token';
    }
    render();
  }catch{$('alerts-status').textContent='无法读取报警状态';}
}
$('alerts-open').onclick=async()=>{
  revision++;
  $('alerts-dialog').showModal();$('alerts-error').textContent='';
  await refresh(true);
};
$('alerts-close').onclick=()=>{$('alerts-token').value='';$('alerts-dialog').close();};
$('alerts-dialog').addEventListener('cancel',()=>{$('alerts-token').value='';});
$('alerts-dialog').addEventListener('close',()=>{$('alerts-token').value='';});
$('alerts-records').onclick=()=>{view='records';render();};
$('alerts-platforms').onclick=()=>{view='platforms';render();};
$('alerts-form').onsubmit=async event=>{
  event.preventDefault();if(saving||selecting)return;revision++;saving=true;render();$('alerts-error').textContent='';
  try {
    const result=await window.reportApi.saveAlerts({enabled:$('alerts-enabled').checked,minutes:Number($('alerts-minutes').value),
      lookbackDays:Number($('alerts-days').value),chatID:$('alerts-group').value,token:$('alerts-token').value});
    if(result.ok===false)$('alerts-error').textContent=result.message;
    else{snapshot=result;$('alerts-token').value='';$('alerts-token').placeholder=snapshot.settings.hasToken?'已保存，留空保持不变':'机器人 Token';}
  }catch{$('alerts-error').textContent='保存失败，请检查本地报警状态';}
  finally{saving=false;render();}
};
setInterval(()=>{if($('alerts-dialog').open&&!saving&&!selecting)void refresh();},3000);
