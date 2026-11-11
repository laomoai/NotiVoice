const json=(obj,status=200)=>new Response(JSON.stringify(obj),{status,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store','access-control-allow-origin':'*'}});
// 所有 /api/* 只认一个 Bearer Token（API_TOKEN），不再兼容其它口令
const authorized=(req,env)=>{
 const expected=String(env.API_TOKEN||'');
 if(!expected)return false;
 const supplied=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'').trim();
 return supplied===expected;
};

// 以下两个 HTML 在部署前由 build.mjs 注入（源文件见 src/views/landing.html 与 src/views/admin.html）。
// 占位符写法为「裸标识符」，注入后由 JSON.stringify 提供带引号的字符串字面量；请勿直接运行未构建的源文件。
const LANDING_HTML = __LANDING_HTML__;
const ADMIN_HTML = __ADMIN_HTML__;

export default {async fetch(request,env){
 const u=new URL(request.url),p=u.pathname;
 try {
  if(request.method==='OPTIONS')return new Response(null,{status:204,headers:{'access-control-allow-origin':'*','access-control-allow-methods':'GET,POST,OPTIONS','access-control-allow-headers':'Authorization,Content-Type','access-control-max-age':'86400'}});
  // 公开页面（无需 Token）：/ 首页、/admin 后台入口
  if(p==='/'&&request.method==='GET')return new Response(LANDING_HTML,{headers:{'content-type':'text/html;charset=utf-8','cache-control':'no-store'}});
  if(p==='/admin'&&request.method==='GET')return new Response(ADMIN_HTML,{headers:{'content-type':'text/html;charset=utf-8','cache-control':'no-store'}});
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
