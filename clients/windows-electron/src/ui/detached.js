import {ChevronLeft,ChevronRight,RefreshCw,PanelTopClose,createIcons} from 'lucide';
let state;
function render(s){if(!s)return;state=s;document.title=s.name;document.querySelector('#name').textContent=s.name;document.querySelector('#country').textContent=s.country||'';document.querySelector('#back').disabled=!s.back;document.querySelector('#forward').disabled=!s.forward;}
for(const command of ['back','forward','reload','return'])document.querySelector('#'+command).onclick=async()=>{
  const ok=await window.detachedApi.command(command);document.querySelector('#message').textContent=ok?'':'页面任务进行中，请稍后操作';
};
document.querySelector('#platform').ondragstart=e=>{if(!state){e.preventDefault();return;}e.dataTransfer.setData('application/x-sms-detached',JSON.stringify({id:state.id,token:state.token}));e.dataTransfer.effectAllowed='move';};
window.detachedApi.onState(render);window.detachedApi.get().then(render);
createIcons({icons:{ChevronLeft,ChevronRight,RefreshCw,PanelTopClose}});
