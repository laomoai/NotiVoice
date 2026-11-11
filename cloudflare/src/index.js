// NotiVoice V1.1 Worker
// 双 Token 鉴权：API_TOKEN（提交/读取/回执） + ADMIN_TOKEN（后台管理）
// 设备级回执：received / played 幂等、单调、多设备隔离
// 兼容旧接口别名：/api/post（=POST /api/notifications）、/api/play（=GET /api/notifications）

const json = (obj, status = 200) => new Response(JSON.stringify(obj), {
  status,
  headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'access-control-allow-origin': '*' }
});

// 常量时间比较，避免时序侧信道
function ctEq(a, b) {
  const sa = String(a ?? ''), sb = String(b ?? '');
  if (sa.length !== sb.length) return false;
  let r = 0;
  for (let i = 0; i < sa.length; i++) r |= sa.charCodeAt(i) ^ sb.charCodeAt(i);
  return r === 0;
}
// 校验某类操作的 Token；secret 缺失时拒绝（不允许“无密钥即可用”）
function auth(req, expected) {
  if (!expected) return false;
  const sup = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim();
  return ctEq(sup, expected);
}
const nowIso = () => new Date().toISOString().replace('.000Z', 'Z');

// 基础限流：模块级滑动窗口（同一 isolate 内有效，作为第一道防线；非持久化）
const RATE = new Map(); // key -> number[] (timestamps)
function rateLimited(key, max, windowMs) {
  const t = Date.now();
  const arr = (RATE.get(key) || []).filter(x => t - x < windowMs);
  arr.push(t);
  RATE.set(key, arr);
  return arr.length > max;
}

// 以下两个 HTML 在部署前由 build.mjs 注入（源文件见 src/views/landing.html 与 src/views/admin.html）。
// 占位符写法为「裸标识符」，注入后由 JSON.stringify 提供带引号的字符串字面量；请勿直接运行未构建的源文件。
const LANDING_HTML = __LANDING_HTML__;
const ADMIN_HTML = __ADMIN_HTML__;

// 状态单调秩：pending(0) < received(1) < played(2)

export default {
  async fetch(request, env) {
    const u = new URL(request.url), p = u.pathname;
    const ip = request.headers.get('cf-connecting-ip') || 'unknown';
    try {
      if (request.method === 'OPTIONS') return new Response(null, {
        status: 204,
        headers: { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET,POST,OPTIONS', 'access-control-allow-headers': 'Authorization,Content-Type', 'access-control-max-age': '86400' }
      });
      // 公开页面（无需 Token）：/ 首页、/admin 后台入口
      if (p === '/' && request.method === 'GET') return new Response(LANDING_HTML, { headers: { 'content-type': 'text/html;charset=utf-8', 'cache-control': 'no-store' } });
      if (p === '/admin' && request.method === 'GET') return new Response(ADMIN_HTML, { headers: { 'content-type': 'text/html;charset=utf-8', 'cache-control': 'no-store' } });

      const isAdmin = p.startsWith('/api/admin/');
      const isApi = p.startsWith('/api/');
      if (!isApi) return json({ error: 'not_found' }, 404);

      // Token 分离：后台管理只用 ADMIN_TOKEN；业务接口只用 API_TOKEN。互相拒绝。
      if (isAdmin) {
        if (!auth(request, env.ADMIN_TOKEN)) return json({ error: 'unauthorized' }, 401);
      } else {
        if (!auth(request, env.API_TOKEN)) return json({ error: 'unauthorized' }, 401);
      }

      // ---- 消息提交（POST） ----
      // 兼容：/api/post 别名，以及旧 {text,voice} 与新 {source,external_id,title,content,priority,voice_slot}
      if ((p === '/api/notifications' || p === '/api/post') && request.method === 'POST') {
        if (rateLimited('post:' + ip, 60, 60_000)) return json({ error: 'rate_limited' }, 429);
        const size = Number(request.headers.get('content-length') || 0);
        if (size > 8192) return json({ error: 'payload_too_large' }, 413);
        let b; try { b = await request.json(); } catch { return json({ error: 'invalid_json' }, 400); }
        const text = typeof b.text === 'string' ? b.text.trim() : '';
        const title = typeof b.title === 'string' ? b.title.trim() : '';
        const content = typeof b.content === 'string' ? b.content.trim() : '';
        const bodyText = content || title || text;
        if (!bodyText || bodyText.length > 1000) return json({ error: 'invalid_text' }, 400);
        const rawVoice = String(b.voice ?? b.voice_slot ?? '1').replace('#', '');
        const voice = Number(rawVoice);
        if (![1, 2, 3].includes(voice)) return json({ error: 'invalid_voice' }, 400);
        const source = typeof b.source === 'string' ? b.source.slice(0, 64) : '';
        const externalId = typeof b.external_id === 'string' && b.external_id.trim() ? b.external_id.trim().slice(0, 128) : null;
        const priority = ['low', 'normal', 'high'].includes(b.priority) ? b.priority : 'normal';

        // 幂等：source + external_id 重复提交不生成新消息
        if (externalId) {
          const dup = await env.DB.prepare('SELECT seq,id,created_at,voice_slot FROM messages WHERE source=? AND external_id=?').bind(source, externalId).first();
          if (dup) return json({ ok: true, id: dup.id, seq: dup.seq, created_at: dup.created_at, voice_slot: dup.voice_slot, duplicate: true }, 200);
        }
        const id = crypto.randomUUID();
        const result = await env.DB.prepare(
          'INSERT INTO messages(id,text,title,content,priority,source,external_id,voice_slot) VALUES (?,?,?,?,?,?,?,?) RETURNING seq,created_at,voice_slot'
        ).bind(id, bodyText, title || content || text, content || title || text, priority, source, externalId, voice).first();
        return json({ ok: true, id, seq: result.seq, created_at: result.created_at, voice_slot: result.voice_slot, text: bodyText }, 201);
      }

      // ---- 消息拉取（GET，增量，按 seq 升序） ----
      // 注意：GET 本身不写 fetched_at（不证明客户端已收到）；received 只能由显式回执确认。
      if ((p === '/api/notifications' || p === '/api/play') && request.method === 'GET') {
        const after = Number(u.searchParams.get('after') || 0);
        if (!Number.isSafeInteger(after) || after < 0) return json({ error: 'invalid_cursor' }, 400);
        const limit = Math.max(1, Math.min(200, Number(u.searchParams.get('limit') || 50) || 50));
        const status = u.searchParams.get('status');
        let where = 'seq>?', binds = [after];
        if (status === 'pending') where += ' AND played_at IS NULL';
        else if (status === 'played') where += ' AND played_at IS NOT NULL';
        const { results } = await env.DB.prepare(
          `SELECT seq,id,text,title,content,priority,voice_slot,created_at,fetched_at,fetch_count,played_at,source,external_id FROM messages WHERE ${where} ORDER BY seq ASC LIMIT ?`
        ).bind(...binds, limit).all();
        // 保留旧 fetched_at 作为“曾被请求”诊断，但本接口不再更新（不视为已接收）
        return json({ messages: results, next_cursor: results.length ? results[results.length - 1].seq : after, has_more: results.length === limit });
      }

      // ---- 回执（received / played），设备级、幂等、单调、多设备隔离 ----
      if (p === '/api/notifications/ack' && request.method === 'POST') {
        let b; try { b = await request.json(); } catch { return json({ error: 'invalid_json' }, 400); }

        // 旧客户端兼容：{seqs:[...]} → 直接标记 played_at（按 seq）
        if (Array.isArray(b.seqs)) {
          const seqs = b.seqs.filter(n => Number.isSafeInteger(n) && n > 0).slice(0, 100);
          if (!seqs.length) return json({ error: 'invalid_seqs' }, 400);
          const marks = seqs.map(() => '?').join(',');
          await env.DB.prepare(`UPDATE messages SET played_at=COALESCE(played_at,?) WHERE seq IN (${marks})`).bind(nowIso(), ...seqs).run();
          return json({ ok: true, acked: seqs.length });
        }

        // 新回执：device_id + message_id + status + event_id
        // FIX-04：消除 JS 层“先 SELECT 判重再 INSERT”竞态——
        //   ① 事件落库 + 设备回执推进放在 D1 batch() 同一事务；
        //   ② 同 event_id 同载荷 → ON CONFLICT DO NOTHING 幂等成功；
        //   ③ 同 event_id 异载荷 → trg_ack_events_payload_conflict 触发器 RAISE(ABORT) → 返回 409；
        //   ④ 设备回执用条件 UPSERT 单调推进（received < played 不倒退），多设备天然隔离。
        const statusVal = b.status;
        if (!['received', 'played'].includes(statusVal)) return json({ error: 'invalid_status' }, 400);
        const messageId = typeof b.message_id === 'string' && b.message_id ? b.message_id : null;
        const deviceId = typeof b.device_id === 'string' && b.device_id ? b.device_id : null;
        const eventId = typeof b.event_id === 'string' && b.event_id ? b.event_id : null;
        if (!messageId || !deviceId || !eventId) return json({ error: 'missing_fields' }, 400);
        // 校验 message 存在
        const msg = await env.DB.prepare('SELECT id FROM messages WHERE id=?').bind(messageId).first();
        if (!msg) return json({ error: 'unknown_message' }, 404);

        const ts = nowIso();
        const playedTs = typeof b.played_at === 'string' && b.played_at ? b.played_at : ts;
        let results;
        try {
          results = await env.DB.batch([
            // ① 事件写入（幂等：同载荷 DO NOTHING；异载荷被触发器中止，整个 batch 回滚）
            env.DB.prepare(
              'INSERT INTO ack_events(event_id,message_id,device_id,status) VALUES (?,?,?,?) ON CONFLICT(event_id) DO NOTHING'
            ).bind(eventId, messageId, deviceId, statusVal),
            // ② 设备回执条件 UPSERT：received_at 沿用最早值，played 覆盖时间戳；落后状态不倒退
            env.DB.prepare(
              `INSERT INTO device_receipts(message_id,device_id,status,received_at,played_at) VALUES (?,?,?,?,?)
               ON CONFLICT(message_id,device_id) DO UPDATE SET
                 status=excluded.status,
                 received_at=COALESCE(device_receipts.received_at, excluded.received_at),
                 played_at=COALESCE(device_receipts.played_at, excluded.played_at)
               WHERE CASE excluded.status WHEN 'played' THEN 2 ELSE 1 END
                   > CASE device_receipts.status WHEN 'played' THEN 2 ELSE 1 END`
            ).bind(messageId, deviceId, statusVal, ts, statusVal === 'played' ? playedTs : null)
          ]);
        } catch (e) {
          if (String((e && e.message) || '').includes('event_conflict')) {
            // 同 event_id 携带不同载荷：读取已提交事件，显式 409，不静默视为成功
            const existing = await env.DB.prepare('SELECT message_id,device_id,status FROM ack_events WHERE event_id=?').bind(eventId).first();
            return json({
              error: 'event_conflict',
              existing: existing || null,
              submitted: { message_id: messageId, device_id: deviceId, status: statusVal }
            }, 409);
          }
          throw e;
        }
        const eventChanges = results?.[0]?.meta?.changes ?? 1;
        const applied = (results?.[1]?.meta?.changes ?? 0) > 0;
        return json({ ok: true, duplicate: eventChanges === 0, status: statusVal, applied });
      }

      // ---- 后台：查询（含设备回执） ----
      if (p === '/api/admin/notifications' && request.method === 'GET') {
        const { results: msgs } = await env.DB.prepare(
          'SELECT seq,id,text,title,content,priority,voice_slot,created_at,fetched_at,fetch_count,played_at,source,external_id FROM messages ORDER BY seq DESC LIMIT 200'
        ).all();
        const ids = msgs.map(m => m.id);
        let receipts = {};
        if (ids.length) {
          const marks = ids.map(() => '?').join(',');
          const { results: rcpts } = await env.DB.prepare(
            `SELECT message_id,device_id,status,received_at,played_at FROM device_receipts WHERE message_id IN (${marks})`
          ).bind(...ids).all();
          for (const r of rcpts) (receipts[r.message_id] ||= []).push(r);
        }
        return json({ messages: msgs.map(m => ({ ...m, receipts: receipts[m.id] || [] })) });
      }

      // ---- 后台：审计日志 ----
      if (p === '/api/admin/audit' && request.method === 'GET') {
        const { results } = await env.DB.prepare('SELECT id,action,created_at,result,metadata FROM admin_audit ORDER BY id DESC LIMIT 100').all();
        return json({ audit: results });
      }

      // ---- 后台：清空全部消息（需 ADMIN_TOKEN，已在上游校验；普通 API_TOKEN 已被拒） ----
      if (p === '/api/admin/notifications/clear' && request.method === 'POST') {
        const info = await env.DB.prepare('SELECT COUNT(*) AS c FROM messages').first();
        const deleted = info ? info.c : 0;
        await env.DB.prepare('DELETE FROM messages').run();
        await env.DB.prepare('DELETE FROM device_receipts').run();
        await env.DB.prepare('DELETE FROM ack_events').run();
        const meta = JSON.stringify({ deleted, by: (request.headers.get('cf-connecting-ip') || 'unknown') });
        await env.DB.prepare("INSERT INTO admin_audit(action,result,metadata) VALUES ('clear','ok',?)").bind(meta).run();
        return json({ ok: true, deleted });
      }

      return json({ error: 'not_found' }, 404);
    } catch (e) {
      // 日志脱敏：不打印 Token 与完整正文
      console.error('server_error:', e && e.message ? e.message : e);
      return json({ error: 'server_error' }, 500);
    }
  }
};
