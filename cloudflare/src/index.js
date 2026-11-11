const json=(obj,status=200)=>new Response(JSON.stringify(obj),{status,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store','access-control-allow-origin':'*'}});
// 所有 /api/* 只认一个 Bearer Token（API_TOKEN），不再兼容其它口令
const authorized=(req,env)=>{
 const expected=String(env.API_TOKEN||'');
 if(!expected)return false;
 const supplied=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'').trim();
 return supplied===expected;
};
const html=`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Noti Voice 控制台</title><link rel="icon" href="data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0%200%2064%2064'%3E%3Crect%20width='64'%20height='64'%20rx='15'%20fill='%230A84FF'/%3E%3Cg%20fill='white'%3E%3Crect%20x='13'%20y='27'%20width='5'%20height='10'%20rx='2.5'/%3E%3Crect%20x='22'%20y='22'%20width='5'%20height='20'%20rx='2.5'/%3E%3Crect%20x='31'%20y='16'%20width='5'%20height='32'%20rx='2.5'/%3E%3Crect%20x='40'%20y='22'%20width='5'%20height='20'%20rx='2.5'/%3E%3Crect%20x='49'%20y='27'%20width='5'%20height='10'%20rx='2.5'/%3E%3C/g%3E%3C/svg%3E"><style>body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f7;color:#1d1d1f;max-width:900px;margin:50px auto;padding:20px}main{background:white;padding:30px;border-radius:16px;box-shadow:0 8px 32px #0001}input,button,textarea{font:inherit;padding:10px;border:1px solid #ddd;border-radius:9px}input{width:260px}input[type=checkbox]{width:auto}button{background:#007aff;color:white;cursor:pointer;border:0}li{padding:12px;border-bottom:1px solid #eee;white-space:pre-wrap}.meta{font-size:12px;color:#888}.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px}.row label{display:flex;gap:5px;align-items:center;font-size:13px;color:#555}.line{display:flex;gap:10px;align-items:flex-start;flex-wrap:wrap}.badge{font-size:12px;padding:2px 9px;border-radius:20px;white-space:nowrap;font-weight:600;flex:none}.ok{background:#e5f7ec;color:#187a41}.read{background:#fff2dd;color:#9a5b00}.new{background:#eceff3;color:#666}.tip{font-size:13px;color:#666;line-height:1.6}code{font-size:12px;background:#f2f3f5;padding:6px 8px;border-radius:6px;display:inline-block;word-break:break-all}.mini{padding:6px 10px;font-size:12px}select{font:inherit;padding:10px;border:1px solid #ddd;border-radius:9px}.tools{display:none;border-top:1px solid #eee;margin-top:12px;padding-top:8px}.tools.show{display:block}.warn{color:#a05a00}</style><main><h2>🔊 Noti Voice · 消息记录</h2><p>所有接口（含后台登录）统一使用同一个 API Token（Bearer）。Token 仅保存在本机浏览器，不会写进页面代码。</p><div class="row"><input id="token" type="password" placeholder="API Token"><button id="load">查看最近 200 条</button><label><input id="auto" type="checkbox" checked> 自动刷新 5s</label><label><input id="unplayed" type="checkbox"> 仅看未播报</label></div><p id="status"></p><p class="tip">一次 POST 测试的完整状态流转：新消息「未读取」→ 客户端 /api/notifications 取走后「已读取 · 未播报」→ 播报完成回执后「已播报」。首次同步会跳过历史消息，所以它们只会停在「已读取」。测试命令仅在 Token 验证通过后显示。</p><div id="tools" class="tools"><p class="tip"><select id="slot"><option value="1">音色 #1（默认）</option><option value="2">音色 #2</option><option value="3">音色 #3</option></select> <button id="copy" class="mini">复制测试命令</button></p><p><code id="cmd"></code></p><p class="tip warn">命令包含你的 API Token，请勿外发或截图；修改 Token 后需重新验证才会重新显示。</p><p class="tip warn">清空将删除服务器上全部消息（含已播报 / 未播报），不可恢复。</p><p class="row"><button id="clear" class="mini" style="background:#c0392b">清空全部消息</button><span id="clearst" class="meta"></span></p></div><ul id="list"></ul></main><script>
const ti=document.querySelector('#token'),st=document.querySelector('#status'),ls=document.querySelector('#list'),tools=document.querySelector('#tools');
const q=String.fromCharCode(39),cmd=document.querySelector('#cmd'),copy=document.querySelector('#copy');
let verified=false;
try{ti.value=localStorage.getItem('nv_token')||''}catch(e){}
function hideTools(){verified=false;cmd.textContent='';copy.textContent='复制测试命令';tools.classList.remove('show')}
function buildCmd(){
 if(!verified)return;
 const slot=document.querySelector('#slot').value,tok=ti.value.trim();
 if(!tok){hideTools();return}
 cmd.textContent='curl -X POST '+q+location.origin+'/api/notifications'+q+' -H '+q+'Content-Type: application/json'+q+' -H '+q+'Authorization: Bearer '+tok+q+' -d '+q+'{"text":"测试消息：一条新的 BTC 提醒","voice":'+slot+'}'+q;
}
ti.addEventListener('input',()=>{try{localStorage.setItem('nv_token',ti.value.trim())}catch(e){}hideTools()});
document.querySelector('#slot').onchange=buildCmd;
copy.onclick=async()=>{if(!verified||!cmd.textContent)return;try{await navigator.clipboard.writeText(cmd.textContent);copy.textContent='已复制'}catch(e){copy.textContent='请手动复制'}};
function fmt(s){return s?String(s).replace('T',' ').replace('Z','').slice(0,19):''}
async function load(){
 try{
  const r=await fetch('/api/admin/notifications',{headers:{Authorization:'Bearer '+ti.value.trim()}});
  const j=await r.json();
  if(!r.ok){st.textContent=r.status===401?'Token 不正确或未提供（HTTP 401）':'请求被拒绝（HTTP '+r.status+'）';hideTools();ls.replaceChildren();return}
  verified=true;tools.classList.add('show');buildCmd();
  let msgs=j.messages||[];
  const played=msgs.filter(x=>x.played_at).length,read=msgs.filter(x=>x.fetched_at&&!x.played_at).length,fresh=msgs.filter(x=>!x.fetched_at).length;
  st.textContent='共 '+msgs.length+' 条  ·  已播报 '+played+'  ·  已读取未播报 '+read+'  ·  未读取 '+fresh;
  if(document.querySelector('#unplayed').checked)msgs=msgs.filter(x=>!x.played_at);
  ls.replaceChildren(...msgs.map(x=>{
   const li=document.createElement('li'),line=document.createElement('div'),badge=document.createElement('span'),txt=document.createElement('span'),meta=document.createElement('div');
   if(x.played_at){badge.className='badge ok';badge.textContent='已播报 · '+fmt(x.played_at)}
   else if(x.fetched_at){badge.className='badge read';badge.textContent='已读取 · 未播报'+(x.fetch_count>1?' · 取走 '+x.fetch_count+' 次':'')}
   else{badge.className='badge new';badge.textContent='未读取'}
   txt.textContent=x.text;line.className='line';line.append(badge,txt);
   meta.className='meta';meta.textContent='#'+x.seq+' · 音色 #'+(x.voice_slot||1)+' · 投递 '+fmt(x.created_at)+(x.fetched_at?' · 首次取走 '+fmt(x.fetched_at):'')+(x.played_at?' · 播报回执 '+fmt(x.played_at):'');
   li.append(line,meta);return li;
  }));
 }catch(e){st.textContent='请求失败：'+e.message;hideTools();ls.replaceChildren()}
}
document.querySelector('#load').onclick=load;
ti.addEventListener('keydown',e=>{if(e.key==='Enter')load()});
document.querySelector('#unplayed').onchange=load;
const clearBtn=document.querySelector('#clear'),clearSt=document.querySelector('#clearst');
clearBtn.onclick=async()=>{ if(!confirm('确定清空服务器上全部消息吗？此操作不可恢复。'))return; clearSt.textContent='清空中…'; try{ const r=await fetch('/api/admin/notifications/clear',{method:'POST',headers:{Authorization:'Bearer '+ti.value.trim()}}); const j=await r.json(); if(!r.ok){clearSt.textContent='清空失败（HTTP '+r.status+'）';return} clearSt.textContent='已清空 '+j.deleted+' 条'; load(); }catch(e){clearSt.textContent='清空失败：'+e.message} };
setInterval(()=>{if(document.querySelector('#auto').checked&&ti.value.trim())load()},5000);
</script>`;
export default {async fetch(request,env){
 const u=new URL(request.url),p=u.pathname;
 try {
  if(request.method==='OPTIONS')return new Response(null,{status:204,headers:{'access-control-allow-origin':'*','access-control-allow-methods':'GET,POST,OPTIONS','access-control-allow-headers':'Authorization,Content-Type','access-control-max-age':'86400'}});
  if(p==='/'&&request.method==='GET')return new Response(html,{headers:{'content-type':'text/html;charset=utf-8','cache-control':'no-store'}});
  // 统一鉴权：notifications 推送 / 拉取 / ack / admin 共用同一个 API_TOKEN
  if(p.startsWith('/api/')&&!authorized(request,env))return json({error:'unauthorized'},401);
  if(p==='/api/notifications'&&request.method==='POST'){
   const size=Number(request.headers.get('content-length')||0);if(size>8192)return json({error:'payload_too_large'},413);
   let b;try{b=await request.json()}catch{return json({error:'invalid_json'},400)}
   const message=typeof b.text==='string'?b.text.trim():'';
   if(!message||message.length>1000)return json({error:'invalid_text'},400);
   const rawVoice=String(b.voice??'1').replace('#','');
   const voice=Number(rawVoice);
   if(![1,2,3].includes(voice))return json({error:'invalid_voice'},400);
   const id=crypto.randomUUID();
   const result=await env.DB.prepare('INSERT INTO messages(id,text,voice_slot) VALUES (?,?,?) RETURNING seq,created_at,voice_slot').bind(id,message,voice).first();
   return json({ok:true,id,seq:result.seq,created_at:result.created_at,voice_slot:result.voice_slot},201);
  }
  if(p==='/api/notifications'&&request.method==='GET'){
   const after=Number(u.searchParams.get('after')||0);
   if(!Number.isSafeInteger(after)||after<0)return json({error:'invalid_cursor'},400);
   const limit=Math.max(1,Math.min(100,Number(u.searchParams.get('limit')||50)||50));
   const status=u.searchParams.get('status');
   let where='seq>?',binds=[after];
   if(status==='pending'){where+=' AND played_at IS NULL';}
   else if(status==='played'){where+=' AND played_at IS NOT NULL';}
   const {results}=await env.DB.prepare(`SELECT seq,id,text,created_at,fetched_at,fetch_count,played_at,voice_slot FROM messages WHERE ${where} ORDER BY seq ASC LIMIT ?`).bind(...binds,limit).all();
   if(results.length){
    const marks=results.map(()=>'?').join(',');
    await env.DB.prepare(`UPDATE messages SET fetched_at=COALESCE(fetched_at,strftime('%Y-%m-%dT%H:%M:%fZ','now')), fetch_count=fetch_count+1 WHERE seq IN (${marks})`).bind(...results.map(r=>r.seq)).run();
   }
   return json({messages:results,next_cursor:results.length?results[results.length-1].seq:after,has_more:results.length===limit});
  }
  // 客户端播报成功后回执：把「已被取走」升级为「已播报」
  if(p==='/api/notifications/ack'&&request.method==='POST'){
   let b;try{b=await request.json()}catch{return json({error:'invalid_json'},400)}
   const seqs=(Array.isArray(b.seqs)?b.seqs:[]).filter(n=>Number.isSafeInteger(n)&&n>0).slice(0,100);
   if(!seqs.length)return json({error:'invalid_seqs'},400);
   const marks=seqs.map(()=>'?').join(',');
   await env.DB.prepare(`UPDATE messages SET played_at=COALESCE(played_at,strftime('%Y-%m-%dT%H:%M:%fZ','now')) WHERE seq IN (${marks})`).bind(...seqs).run();
   return json({ok:true,acked:seqs.length});
  }
  if(p==='/api/admin/notifications'&&request.method==='GET'){
   const {results}=await env.DB.prepare('SELECT seq,id,text,created_at,fetched_at,fetch_count,played_at,voice_slot FROM messages ORDER BY seq DESC LIMIT 200').all();return json({messages:results});
  }
  // 清空全部消息（需 Token；admin 接口，仅管理员可用）
  if(p==='/api/admin/notifications/clear'&&request.method==='POST'){
   const info=await env.DB.prepare('SELECT COUNT(*) AS c FROM messages').first();
   const deleted=info?info.c:0;
   await env.DB.prepare('DELETE FROM messages').run();
   return json({ok:true,deleted});
  }
  return json({error:'not_found'},404);
 }catch(e){console.error(e);return json({error:'server_error'},500)}
}};
