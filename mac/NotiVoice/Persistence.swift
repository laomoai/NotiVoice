import Foundation
import SQLite3

// NotiVoice V1.1 本地持久层
// 系统 SQLite C API；WAL + busy_timeout + foreign_keys；单一串行执行器；user_version 迁移。
// 不引入 GRDB：所有访问经由 queue.sync 串行进出，UI 不直接持有数据库连接。

enum NVError: Error { case openFailed(Int), execFailed(String), stepFailed(Int) }

struct IncomingMessage {
    let seq: Int
    let id: String
    let title: String
    let content: String
    let text: String
    let priority: String
    let voiceSlot: Int
    let createdAt: String
}

struct PlaybackJob {
    let messageId: String
    let seq: Int
    let state: String          // queued | playing | retry_wait | needs_attention | completed
    let attempts: Int
    let nextRetryAt: TimeInterval?
    let lastError: String?
    let text: String
    let voiceSlot: Int
}

struct AckRow {
    let eventId: String
    let messageId: String
    let deviceId: String
    let status: String
}

final class Persistence {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "cn.lemoai.notivoice.db")
    let dbPath: String

    init(path: String) throws {
        dbPath = path
        try open()
        try migrate()
    }

    // MARK: - 打开与 PRAGMA
    private func open() throws {
        let dir = (dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let h = handle else { throw NVError.openFailed(Int(rc)) }
        db = h
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA busy_timeout=5000;")
        try exec("PRAGMA foreign_keys=ON;")
    }

    // 直接执行（调用方须已在 queue 上，避免串行队列嵌套 sync 死锁）
    private func execNow(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(err)
            throw NVError.execFailed(msg)
        }
    }

    // 对外/跨线程入口：派发到串行队列后执行
    func exec(_ sql: String) throws {
        try queue.sync { try execNow(sql) }
    }

    private var userVersion: Int {
        get {
            queue.sync {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
                return Int(sqlite3_column_int(stmt, 0))
            }
        }
        set { try? exec("PRAGMA user_version=\(newValue);") }
    }

    // user_version 迁移：增量、可重复执行。现有生产库升级时只需提升版本号追加建表/改表。
    private func migrate() throws {
        let v = userVersion
        guard v < 1 else { return }
        try exec("""
        CREATE TABLE IF NOT EXISTS app_state(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS messages(
            message_id TEXT PRIMARY KEY, seq INTEGER UNIQUE, title TEXT, content TEXT,
            priority TEXT, voice_slot INTEGER, created_at TEXT, received_at TEXT);
        CREATE TABLE IF NOT EXISTS playback_jobs(
            message_id TEXT PRIMARY KEY, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
            next_retry_at REAL, last_error TEXT, started_at TEXT, completed_at TEXT,
            FOREIGN KEY(message_id) REFERENCES messages(message_id));
        CREATE TABLE IF NOT EXISTS ack_outbox(
            event_id TEXT PRIMARY KEY, message_id TEXT NOT NULL, device_id TEXT NOT NULL, status TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, delivered_at TEXT);
        CREATE TABLE IF NOT EXISTS playback_history(
            id TEXT PRIMARY KEY, message_id TEXT, action TEXT, engine TEXT, result TEXT, text TEXT, occurred_at REAL);
        CREATE INDEX IF NOT EXISTS idx_jobs_state ON playback_jobs(state, next_retry_at);
        CREATE INDEX IF NOT EXISTS idx_ack ON ack_outbox(delivered_at, next_retry_at);
        """)
        userVersion = 1
    }

    // MARK: - 事务封装（可抛错回滚，用于 T02/T17）
    // 注意：本方法已在 queue 上执行，内部必须用 execNow（直接执行），不得再 dispatch 到 queue，否则串行队列嵌套 sync 死锁。
    func transaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            try execNow("BEGIN IMMEDIATE;")
            do { let r = try body(db!); try execNow("COMMIT;"); return r }
            catch { try? execNow("ROLLBACK;"); throw error }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw NVError.execFailed("prepare: \(sql)")
        }
        return s
    }

    // MARK: - app_state / device_id / cursor
    private func getStateNow(_ key: String) -> String? {
        guard let stmt = try? prepare("SELECT value FROM app_state WHERE key=?;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    func getState(_ key: String) -> String? {
        queue.sync { getStateNow(key) }
    }

    private func setStateNow(_ key: String, _ value: String) {
        let stmt = try! prepare("INSERT INTO app_state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;")
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, nil)
        sqlite3_step(stmt); sqlite3_finalize(stmt)
    }

    func setState(_ key: String, _ value: String) {
        try? queue.sync { setStateNow(key, value) }
    }

    var deviceId: String {
        if let existing = getState("device_id"), !existing.isEmpty { return existing }
        let new = UUID().uuidString
        setState("device_id", new)
        return new
    }

    var cursor: Int { getState("cursor").flatMap { Int($0) } ?? 0 }
    private func setCursorNow(_ c: Int) { setStateNow("cursor", String(c)) }
    func setCursor(_ c: Int) { setState("cursor", String(c)) }

    // MARK: - 入库 + 推进游标（同一事务；T02/T03 核心保证）
    /// 在一笔事务中：幂等插入消息 → 建待播任务 → 更新持久化 cursor。
    /// 事务提交前崩溃：消息与 cursor 都不落盘（T02）；提交后 cursor 已前进（T03）。
    @discardableResult
    func storePage(_ messages: [IncomingMessage], newCursor: Int) throws -> Int {
        try transaction { _ in try storePageBody(messages, newCursor: newCursor) }
    }

    // MARK: - 回执 Outbox
    /// 与 storePage 同事务创建 received 回执（T03：提交后本地任务与 Outbox 一同落盘，崩溃可恢复）
    func storePageAndAcks(_ messages: [IncomingMessage], newCursor: Int, acks: [(messageId: String, status: String, eventId: String)], deviceId: String) throws -> Int {
        var inserted = 0
        try transaction { _ in
            inserted = try storePageBody(messages, newCursor: newCursor)
            let stmt = try prepare("INSERT INTO ack_outbox(event_id,message_id,device_id,status) VALUES(?,?,?,?) ON CONFLICT(event_id) DO NOTHING;")
            for r in acks {
                sqlite3_bind_text(stmt, 1, (r.eventId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (r.messageId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (deviceId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (r.status as NSString).utf8String, -1, nil)
                sqlite3_step(stmt); sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
        }
        return inserted
    }

    func enqueueAcks(_ rows: [(messageId: String, status: String, eventId: String)], deviceId: String) {
        queue.sync {
            guard let stmt = try? prepare("INSERT INTO ack_outbox(event_id,message_id,device_id,status) VALUES(?,?,?,?) ON CONFLICT(event_id) DO NOTHING;") else { return }
            for r in rows {
                sqlite3_bind_text(stmt, 1, (r.eventId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (r.messageId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (deviceId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (r.status as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // storePage 的纯事务体（供 storePage / storePageAndAcks 复用）
    private func storePageBody(_ messages: [IncomingMessage], newCursor: Int) throws -> Int {
        var inserted = 0
        for m in messages {
            let u = try prepare("INSERT INTO messages(message_id,seq,title,content,priority,voice_slot,created_at,received_at) VALUES(?,?,?,?,?,?,?,strftime('%Y-%m-%dT%H:%M:%fZ','now')) ON CONFLICT(message_id) DO NOTHING;")
            sqlite3_bind_text(u, 1, (m.id as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(u, 2, Int64(m.seq))
            sqlite3_bind_text(u, 3, (m.title as NSString).utf8String, -1, nil)
            sqlite3_bind_text(u, 4, (m.content as NSString).utf8String, -1, nil)
            sqlite3_bind_text(u, 5, (m.priority as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(u, 6, Int64(m.voiceSlot))
            sqlite3_bind_text(u, 7, (m.createdAt as NSString).utf8String, -1, nil)
            // ON CONFLICT(message_id) DO NOTHING 的重复写入也会返回 SQLITE_DONE，但 sqlite3_changes()==0；
            // 必须以 sqlite3_changes 判定“真正新增”的行数（T02 幂等：重复 source/external_id 不新增）。
            if sqlite3_step(u) == SQLITE_DONE {
                if sqlite3_changes(db) > 0 { inserted += 1 }
            } else { throw NVError.stepFailed(Int(sqlite3_errcode(db))) }
            sqlite3_finalize(u)
            let j = try prepare("INSERT INTO playback_jobs(message_id,state) VALUES(?,'queued') ON CONFLICT(message_id) DO NOTHING;")
            sqlite3_bind_text(j, 1, (m.id as NSString).utf8String, -1, nil)
            sqlite3_step(j); sqlite3_finalize(j)
        }
        setCursorNow(newCursor)
        return inserted
    }

    // MARK: - 任务状态机
    func jobs(in states: [String]) -> [PlaybackJob] {
        queue.sync {
            let ph = states.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT j.message_id, m.seq, j.state, j.attempts, j.next_retry_at, j.last_error, COALESCE(NULLIF(m.content,''), m.title), m.voice_slot FROM playback_jobs j JOIN messages m ON m.message_id=j.message_id WHERE j.state IN (\(ph)) ORDER BY m.seq ASC;"
            guard let stmt = try? prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            for (i, s) in states.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), (s as NSString).utf8String, -1, nil) }
            var out: [PlaybackJob] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let mid = String(cString: sqlite3_column_text(stmt, 0)!)
                let seq = Int(sqlite3_column_int64(stmt, 1))
                let state = String(cString: sqlite3_column_text(stmt, 2)!)
                let attempts = Int(sqlite3_column_int(stmt, 3))
                let nrt = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : TimeInterval(sqlite3_column_double(stmt, 4))
                let le = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 5)!)
                let txt = String(cString: sqlite3_column_text(stmt, 6)!)
                let vs = Int(sqlite3_column_int(stmt, 7))
                out.append(PlaybackJob(messageId: mid, seq: seq, state: state, attempts: attempts, nextRetryAt: nrt, lastError: le, text: txt, voiceSlot: vs))
            }
            return out
        }
    }

    /// 到期可播任务（queued + retry_wait 且已到 next_retry_at）
    func dueJobs(now: TimeInterval = Date().timeIntervalSince1970) -> [PlaybackJob] {
        jobs(in: ["queued", "retry_wait"]).filter { $0.nextRetryAt == nil || $0.nextRetryAt! <= now }
    }

    func needAttentionJobs() -> [PlaybackJob] { jobs(in: ["needs_attention"]) }

    func markPlaying(_ messageId: String) {
        setJobState(messageId, "playing", nil)
    }

    func markCompleted(_ messageId: String) {
        queue.sync {
            guard let stmt = try? prepare("UPDATE playback_jobs SET state='completed', completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), next_retry_at=NULL, started_at=NULL WHERE message_id=?;") else { return }
            sqlite3_bind_text(stmt, 1, (messageId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

    /// 失败：attempts+1；达阈值转 needs_attention（保留，不删除，T08）；否则 retry_wait + 指数退避（封顶 60s）
    func markFailed(_ messageId: String, error: String, threshold: Int, now: TimeInterval = Date().timeIntervalSince1970) {
        queue.sync {
            let cur = currentAttemptsNow(messageId)
            let next = cur + 1
            let isAttention = next >= threshold
            let state = isAttention ? "needs_attention" : "retry_wait"
            let backoff = isAttention ? 0.0 : min(pow(2.0, Double(next)), 60.0)
            let nrt: TimeInterval? = isAttention ? nil : (now + backoff)
            guard let stmt = try? prepare("UPDATE playback_jobs SET state=?, attempts=?, next_retry_at=?, last_error=?, started_at=NULL WHERE message_id=?;") else { return }
            sqlite3_bind_text(stmt, 1, (state as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(next))
            if let t = nrt { sqlite3_bind_double(stmt, 3, t) } else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_text(stmt, 4, (error as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (messageId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

    func retryAttention(_ messageId: String) {
        setJobState(messageId, "queued", nil)
    }

    /// 崩溃恢复：playing 视为结果不确定，重排为 queued（允许少量重复播报，T04）
    func recoverInterrupted() {
        try? exec("UPDATE playback_jobs SET state='queued', started_at=NULL WHERE state='playing';")
    }

    private func currentAttemptsNow(_ messageId: String) -> Int {
        guard let stmt = try? prepare("SELECT attempts FROM playback_jobs WHERE message_id=?;") else { return 0 }
        sqlite3_bind_text(stmt, 1, (messageId as NSString).utf8String, -1, nil)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func currentAttempts(_ messageId: String) -> Int {
        queue.sync { currentAttemptsNow(messageId) }
    }

    private func setJobState(_ messageId: String, _ state: String, _ error: String?) {
        queue.sync {
            guard let stmt = try? prepare("UPDATE playback_jobs SET state=?, last_error=?, started_at=NULL WHERE message_id=?;") else { return }
            sqlite3_bind_text(stmt, 1, (state as NSString).utf8String, -1, nil)
            if let e = error { sqlite3_bind_text(stmt, 2, (e as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 2) }
            sqlite3_bind_text(stmt, 3, (messageId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

    // MARK: - ACK Outbox 处理（T05：失败持续重试，不改变本地已播放事实）
    func undeliveredAcks() -> [AckRow] {
        queue.sync {
            guard let stmt = try? prepare("SELECT event_id,message_id,device_id,status FROM ack_outbox WHERE delivered_at IS NULL;") else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [AckRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(AckRow(
                    eventId: String(cString: sqlite3_column_text(stmt, 0)!),
                    messageId: String(cString: sqlite3_column_text(stmt, 1)!),
                    deviceId: String(cString: sqlite3_column_text(stmt, 2)!),
                    status: String(cString: sqlite3_column_text(stmt, 3)!)))
            }
            return out
        }
    }

    func markAckDelivered(_ eventId: String) {
        queue.sync {
            guard let stmt = try? prepare("UPDATE ack_outbox SET delivered_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE event_id=?;") else { return }
            sqlite3_bind_text(stmt, 1, (eventId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

    func bumpAckAttempt(_ eventId: String, nextRetryAt: TimeInterval) {
        queue.sync {
            guard let stmt = try? prepare("UPDATE ack_outbox SET attempts=attempts+1, next_retry_at=? WHERE event_id=?;") else { return }
            sqlite3_bind_double(stmt, 1, nextRetryAt)
            sqlite3_bind_text(stmt, 2, (eventId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

    func pendingAckCount() -> Int {
        queue.sync {
            guard let stmt = try? prepare("SELECT COUNT(*) FROM ack_outbox WHERE delivered_at IS NULL;") else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    var failedCount: Int { jobs(in: ["needs_attention"]).count }

    // MARK: - 播放历史（SQLite，替代原 history.json）
    func insertHistory(id: String, messageId: String, action: String, engine: String, result: String, text: String, at: TimeInterval = Date().timeIntervalSince1970) {
        queue.sync {
            guard let stmt = try? prepare("INSERT INTO playback_history(id,message_id,action,engine,result,text,occurred_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET result=excluded.result;") else { return }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (messageId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (action as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (engine as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (result as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, (text as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 7, at)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

    func recentHistory(limit: Int = 500) -> [[String: Any]] {
        queue.sync {
            guard let stmt = try? prepare("SELECT id,message_id,action,engine,result,text,occurred_at FROM playback_history ORDER BY occurred_at DESC LIMIT ?;") else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            defer { sqlite3_finalize(stmt) }
            var out: [[String: Any]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append([
                    "id": String(cString: sqlite3_column_text(stmt, 0)!),
                    "messageId": String(cString: sqlite3_column_text(stmt, 1)!),
                    "action": String(cString: sqlite3_column_text(stmt, 2)!),
                    "engine": String(cString: sqlite3_column_text(stmt, 3)!),
                    "result": String(cString: sqlite3_column_text(stmt, 4)!),
                    "text": String(cString: sqlite3_column_text(stmt, 5)!),
                    "occurredAt": sqlite3_column_double(stmt, 6)
                ])
            }
            return out
        }
    }

    func close() { if let d = db { sqlite3_close(d); db = nil } }
}
