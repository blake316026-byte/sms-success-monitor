import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import crypto from 'node:crypto';

export function openAlertStore(directory,safeStorage) {
  const root=path.join(directory,'withdrawal-alerts-v1');fs.mkdirSync(root,{recursive:true,mode:0o700});
  const lock=path.join(root,'sender.lock'),file=path.join(root,'state.encrypted'),nonce=crypto.randomUUID();
  let fd;
  try{fd=fs.openSync(lock,'wx',0o600);}catch(error){
    if(error.code!=='EEXIST')throw error;
    const owner=JSON.parse(fs.readFileSync(lock,'utf8'));
    if(!Number.isInteger(owner.pid)||owner.pid<=0)throw new Error('报警发送锁损坏');
    try{process.kill(owner.pid,0);throw new Error('另一个客户端正在使用此报警配置');}
    catch(e){if(e.code!=='ESRCH')throw e;}
    fs.unlinkSync(lock);fd=fs.openSync(lock,'wx',0o600);
  }
  fs.writeFileSync(fd,JSON.stringify({pid:process.pid,nonce}));fs.fsyncSync(fd);fs.closeSync(fd);
  const encryption=()=>{if(!safeStorage.isEncryptionAvailable()||safeStorage.getSelectedStorageBackend?.()==='basic_text')throw new Error('系统加密不可用');};
  return {
    load(){encryption();return fs.existsSync(file)?JSON.parse(safeStorage.decryptString(fs.readFileSync(file))):null;},
    save(data){
      encryption();const temporary=path.join(root,crypto.randomUUID()+'.tmp');let handle;
      try{
        handle=fs.openSync(temporary,'wx',0o600);fs.writeFileSync(handle,safeStorage.encryptString(JSON.stringify(data)));
        fs.fsyncSync(handle);fs.closeSync(handle);handle=undefined;fs.renameSync(temporary,file);
      }finally{if(handle!==undefined)fs.closeSync(handle);if(fs.existsSync(temporary))fs.unlinkSync(temporary);}
    },
    close(){try{if(JSON.parse(fs.readFileSync(lock,'utf8')).nonce===nonce)fs.unlinkSync(lock);}catch{}}
  };
}

export function telegramSend(settings,text,request=https.request) {
  return new Promise(resolve=>{
    let settled=false,timer;
    const done=value=>{if(settled)return;settled=true;clearTimeout(timer);resolve(value);};
    const unknown=()=>done({state:'发送待确认'});
    const body=JSON.stringify({chat_id:settings.chatID,text});
    let req;
    try {
      req=request({hostname:'api.telegram.org',port:443,path:'/bot'+settings.token+'/sendMessage',method:'POST',agent:false,
        headers:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},res=>{
        let body='',bytes=0;
        res.on('data',chunk=>{bytes+=chunk.length;if(bytes>65536){unknown();req.destroy();return;}body+=chunk;});
        res.on('error',unknown);res.on('aborted',unknown);
        res.on('end',()=>{
          try {
            const result=JSON.parse(body);
            if(res.statusCode===200&&result.ok===true&&Number.isSafeInteger(result.result?.message_id)) {
              done({state:'已发送',messageID:String(result.result.message_id)});
            }else if(res.statusCode>=400&&res.statusCode<500&&result.ok===false)done({state:'发送失败（当天不重发）'});
            else unknown();
          }catch{unknown();}
        });
      });
      req.on('error',unknown);timer=setTimeout(()=>{unknown();req.destroy();},20000);req.end(body);
    }catch{unknown();req?.destroy();}
  });
}
