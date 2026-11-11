import Foundation
import SQLite3

// NotiVoice V1.1 本地持久层（FIX-01/FIX-02 加固版）
// 系统 SQLite C API；WAL + busy_timeout + foreign_keys；单一串行执行器；user_version 迁移。
// 不引入 GRDB：所有访问经由 queue.sync 串行进出，UI 不直接持有数据库连接。
//
// FIX-01：所有关键写入严格检查返回码——prepare/bind/step 全部 checked，失败携带 SQLite 错误码与 errmsg 上抛；
//         关键写路径无 try?/try!；迁移与 user_version 同一事务原子完成；deviceId 创建后必须回读验证。
// FIX-02：播放完成（completed）与 played 回执 Outbox 必须同一事务提交，杜绝"完成已落库、回执丢失"的窗口。

enum NVError: Error {
    case openFailed(Int)
    case execFailed(String)
    case prepareFailed(Int, String)
    case bindFailed(Int, String)
    case stepFailed(Int, String)
    case unknownJob(String)
    case notPlaying(String)
    case verifyFailed(String)
}

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
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch { throw NVError.openFailed(-1) }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let h = handle else {
            if let h = handle { sqlite3_close(h) }   // 打开半成功也要释放
            throw NVError.openFailed(Int(rc))
        }
        db = h
        try execNow("PRAGMA journal_mode=WAL;")      // busy_timeout：SQLITE_BUSY 的有界等待（瞬态锁冲突不至于直接失败）
        try execNow("PRAGMA busy_timeout=5000;")
        try execNow("PRAGMA foreign_keys=ON;")
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

    // MARK: - Checked helpers（FIX-01：返回码一律检查，错误带码带信息）
    private func prepareChecked(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else {
            throw NVError.prepareFailed(Int(rc), String(cString: sqlite3_errmsg(db)))
        }
        return s
    }

    private enum Bind { case text(String), int(Int64), dbl(Double), nul }

    // P1-B：SQLITE_TRANSIENT 让 SQLite 立即复制字符串，不再依赖 (s as NSString).utf8String 临时指针的生命周期
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, _ b: Bind) throws {
        let rc: Int32
        switch b {
        case .text(let s):
            rc = s.withCString { ptr in
                sqlite3_bind_text(stmt, idx, ptr, -1, Self.transientDestructor)
            }
        case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
        case .dbl(let v): rc = sqlite3_bind_double(stmt, idx, v)
        case .nul: rc = sqlite3_bind_null(stmt, idx)
        }
        guard rc == SQLITE_OK else {
            throw NVError.bindFailed(Int(rc), String(cString: sqlite3_errmsg(db)))
        }
    }

    /// 写操作：要求 SQLITE_DONE
    private func stepDoneChecked(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw NVError.stepFailed(Int(rc), String(cString: sqlite3_errmsg(db)))
        }
    }

    /// 读操作：返回是否有行，显式区分 ROW / DONE / 错误
    @discardableResult
    private func stepRowChecked(_ stmt: OpaquePointer) throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw NVError.stepFailed(Int(rc), String(cString: sqlite3_errmsg(db)))
    }

    private func errorMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "db closed"
    }

    // MARK: - user_version 迁移（与 DDL 同一事务，原子完成；FIX-01）
    private func userVersionNow() throws -> Int {
        let stmt = try prepareChecked("PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        guard try stepRowChecked(stmt) else { throw NVError.stepFailed(-1, "PRAGMA user_version 无行") }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func setUserVersionNow(_ v: Int) throws {
        try execNow("PRAGMA user_version=\(v);")
        guard try userVersionNow() == v else { throw NVError.verifyFailed("user_version 写入后回读不一致") }
    }

    private func columnExistsNow(_ table: String, _ column: String) throws -> Bool {
        let s = try prepareChecked("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(s) }
        while try stepRowChecked(s) {
            if let c = sqlite3_column_text(s, 1), String(cString: c) == column { return true }
        }
        return false
    }

    private func migrate() throws {
        let v = try userVersionNow()
        guard v < 2 else { return }
        if v == 0 {
            // DDL 与版本号写入同事务：版本写不进去就整体回滚，绝不“假装迁移成功”。
            // 新库一步到 v2：ack_outbox 直接带隔离列（P1-A：409/404 异常回执落库隔离）。
            try transaction { _ in
                try execNow("""
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
                    attempts INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, delivered_at TEXT,
                    quarantined_at TEXT, quarantine_reason TEXT);
                CREATE TABLE IF NOT EXISTS playback_history(
                    id TEXT PRIMARY KEY, message_id TEXT, action TEXT, engine TEXT, result TEXT, text TEXT, occurred_at REAL);
                CREATE INDEX IF NOT EXISTS idx_jobs_state ON playback_jobs(state, next_retry_at);
                CREATE INDEX IF NOT EXISTS idx_ack ON ack_outbox(delivered_at, next_retry_at);
                """)
                try setUserVersionNow(2)
            }
            return
        }
        // v == 1：老库补齐隔离列，条件 ALTER 保证重复执行/半迁移状态也安全
        try transaction { _ in
            if !(try columnExistsNow("ack_outbox", "quarantined_at")) {
                try execNow("ALTER TABLE ack_outbox ADD COLUMN quarantined_at TEXT;")
            }
            if !(try columnExistsNow("ack_outbox", "quarantine_reason")) {
                try execNow("ALTER TABLE ack_outbox ADD COLUMN quarantine_reason TEXT;")
            }
            try setUserVersionNow(2)
        }
    }

    // MARK: - 事务封装（BEGIN IMMEDIATE；COMMIT 失败上抛；事务体内禁止再 queue.sync）
    func transaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            try execNow("BEGIN IMMEDIATE;")
            do { let r = try body(db!); try execNow("COMMIT;"); return r }
            catch { try? execNow("ROLLBACK;"); throw error }
        }
    }

    // MARK: - app_state / device_id / cursor（关键读写全部 checked）
    private func getStateNow(_ key: String) throws -> String? {
        let stmt = try prepareChecked("SELECT value FROM app_state WHERE key=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, 1, .text(key))
        guard try stepRowChecked(stmt), let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    func getState(_ key: String) throws -> String? {
        try queue.sync { try getStateNow(key) }
    }

    private func setStateNow(_ key: String, _ value: String) throws {
        let stmt = try prepareChecked("INSERT INTO app_state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;")
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, 1, .text(key))
        try bind(stmt, 2, .text(value))
        try stepDoneChecked(stmt)
    }

    func setState(_ key: String, _ value: String) throws {
        try queue.sync { try setStateNow(key, value) }
    }

    /// deviceId：不存在则创建并**回读验证**；验证失败不得返回未持久化的 ID（FIX-01）
    func ensureDeviceId() throws -> String {
        if let existing = try getState("device_id"), !existing.isEmpty { return existing }
        let new = UUID().uuidString
        try setState("device_id", new)
        guard let back = try getState("device_id"), back == new else {
            throw NVError.verifyFailed("device_id 写入后回读不一致，拒绝使用未持久化的设备 ID")
        }
        return new
    }

    func readCursor() throws -> Int {
        guard let s = try getState("cursor") else { return 0 }
        guard let v = Int(s) else { throw NVError.verifyFailed("cursor 值非法：\(s)") }
        return v
    }

    private func setCursorNow(_ c: Int) throws {
        try setStateNow("cursor", String(c))
    }

    func setCursor(_ c: Int) throws {
        try queue.sync { try setCursorNow(c) }
    }

    // MARK: - 入库 + 推进游标（同一事务；T02/T03 核心保证）
    /// 在一笔事务中：幂等插入消息 → 建待播任务 → 更新持久化 cursor。
    /// 事务提交前崩溃：消息与 cursor 都不落盘（T02）；提交后 cursor 已前进（T03）。
    @discardableResult
    func storePage(_ messages: [IncomingMessage], newCursor: Int) throws -> Int {
        try transaction { _ in try storePageBody(messages, newCursor: newCursor) }
    }

    // MARK: - 回执 Outbox
    /// 与 storePage 同事务创建 received 回执（T03：提交后本地任务与 Outbox 一同落盘，崩溃可恢复）
    @discardableResult
    func storePageAndAcks(_ messages: [IncomingMessage], newCursor: Int, acks: [(messageId: String, status: String, eventId: String)], deviceId: String) throws -> Int {
        var inserted = 0
        try transaction { _ in
            inserted = try storePageBody(messages, newCursor: newCursor)
            let stmt = try prepareChecked("INSERT INTO ack_outbox(event_id,message_id,device_id,status) VALUES(?,?,?,?) ON CONFLICT(event_id) DO NOTHING;")
            defer { sqlite3_finalize(stmt) }
            for r in acks {
                try bind(stmt, 1, .text(r.eventId))
                try bind(stmt, 2, .text(r.messageId))
                try bind(stmt, 3, .text(deviceId))
                try bind(stmt, 4, .text(r.status))
                try stepDoneChecked(stmt)
                sqlite3_reset(stmt)
            }
        }
        return inserted
    }

    /// 独立批量入队（非事务复用场景；每条 checked）
    func enqueueAcks(_ rows: [(messageId: String, status: String, eventId: String)], deviceId: String) throws {
        try queue.sync {
            let stmt = try prepareChecked("INSERT INTO ack_outbox(event_id,message_id,device_id,status) VALUES(?,?,?,?) ON CONFLICT(event_id) DO NOTHING;")
            defer { sqlite3_finalize(stmt) }
            for r in rows {
                try bind(stmt, 1, .text(r.eventId))
                try bind(stmt, 2, .text(r.messageId))
                try bind(stmt, 3, .text(deviceId))
                try bind(stmt, 4, .text(r.status))
                try stepDoneChecked(stmt)
                sqlite3_reset(stmt)
            }
        }
    }

    // storePage 的纯事务体（供 storePage / storePageAndAcks 复用）
    private func storePageBody(_ messages: [IncomingMessage], newCursor: Int) throws -> Int {
        var inserted = 0
        for m in messages {
            let u = try prepareChecked("INSERT INTO messages(message_id,seq,title,content,priority,voice_slot,created_at,received_at) VALUES(?,?,?,?,?,?,?,strftime('%Y-%m-%dT%H:%M:%fZ','now')) ON CONFLICT(message_id) DO NOTHING;")
            defer { sqlite3_finalize(u) }
            try bind(u, 1, .text(m.id))
            try bind(u, 2, .int(Int64(m.seq)))
            try bind(u, 3, .text(m.title))
            try bind(u, 4, .text(m.content))
            try bind(u, 5, .text(m.priority))
            try bind(u, 6, .int(Int64(m.voiceSlot)))
            try bind(u, 7, .text(m.createdAt))
            try stepDoneChecked(u)
            // ON CONFLICT DO NOTHING 的重复写入也返回 SQLITE_DONE，必须以 sqlite3_changes 判定“真正新增”。
            if sqlite3_changes(db) > 0 { inserted += 1 }
            let j = try prepareChecked("INSERT INTO playback_jobs(message_id,state) VALUES(?,'queued') ON CONFLICT(message_id) DO NOTHING;")
            defer { sqlite3_finalize(j) }
            try bind(j, 1, .text(m.id))
            try stepDoneChecked(j)
        }
        try setCursorNow(newCursor)
        return inserted
    }

    // MARK: - 任务状态机
    func jobs(in states: [String]) throws -> [PlaybackJob] {
        try queue.sync {
            let ph = states.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT j.message_id, m.seq, j.state, j.attempts, j.next_retry_at, j.last_error, COALESCE(NULLIF(m.content,''), m.title), m.voice_slot FROM playback_jobs j JOIN messages m ON m.message_id=j.message_id WHERE j.state IN (\(ph)) ORDER BY m.seq ASC;"
            let stmt = try prepareChecked(sql)
            defer { sqlite3_finalize(stmt) }
            for (i, s) in states.enumerated() { try bind(stmt, Int32(i + 1), .text(s)) }
            var out: [PlaybackJob] = []
            while try stepRowChecked(stmt) {
                guard let midC = sqlite3_column_text(stmt, 0), let stateC = sqlite3_column_text(stmt, 2),
                      let txtC = sqlite3_column_text(stmt, 6) else {
                    throw NVError.stepFailed(-1, "jobs 行数据含 NULL 必填列")
                }
                out.append(PlaybackJob(
                    messageId: String(cString: midC),
                    seq: Int(sqlite3_column_int64(stmt, 1)),
                    state: String(cString: stateC),
                    attempts: Int(sqlite3_column_int(stmt, 3)),
                    nextRetryAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : TimeInterval(sqlite3_column_double(stmt, 4)),
                    lastError: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 5)!),
                    text: String(cString: txtC),
                    voiceSlot: Int(sqlite3_column_int(stmt, 7))))
            }
            return out
        }
    }

    /// 到期可播任务（queued + retry_wait 且已到 next_retry_at）
    func dueJobs(now: TimeInterval = Date().timeIntervalSince1970) throws -> [PlaybackJob] {
        try jobs(in: ["queued", "retry_wait"]).filter { $0.nextRetryAt == nil || $0.nextRetryAt! <= now }
    }

    func needAttentionJobs() throws -> [PlaybackJob] { try jobs(in: ["needs_attention"]) }

    func markPlaying(_ messageId: String) throws {
        try setJobState(messageId, "playing", nil)
    }

    /// FIX-02：播放完成与 played 回执同一事务。completed 与 Outbox 同生同灭。
    /// - 幂等：任务已 completed 时不生成第二个有效事件——回读既有 played 事件 ID 返回；
    ///   若历史数据只有 completed 没有 Outbox（旧版本窗口），自愈补一条。
    /// - 顺序：校验任务存在且处于 playing（或 completed 幂等路径）→ 标记 completed → 插入 played Outbox → 提交。
    /// - COMMIT 前崩溃：整体回滚，重启后重播（At-Least-Once 取舍）。
    @discardableResult
    func completeAndEnqueuePlayed(_ messageId: String, deviceId: String) throws -> String {
        try transaction { _ in
            let s = try prepareChecked("SELECT state FROM playback_jobs WHERE message_id=?;")
            defer { sqlite3_finalize(s) }
            try bind(s, 1, .text(messageId))
            guard try stepRowChecked(s), let stateC = sqlite3_column_text(s, 0) else {
                throw NVError.unknownJob(messageId)
            }
            let state = String(cString: stateC)
            if state != "playing" && state != "completed" {
                throw NVError.notPlaying("任务状态为 \(state)，拒绝完成")
            }
            if state == "completed" {
                // 幂等重入：不得产生第二个有效 played 事件
                // P2-C：查全部 played 事件（含已送达），否则已送达后重入会误判为「无事件」并新建第二条
                let e = try prepareChecked("SELECT event_id FROM ack_outbox WHERE message_id=? AND status='played' ORDER BY event_id LIMIT 1;")
                defer { sqlite3_finalize(e) }
                try bind(e, 1, .text(messageId))
                if try stepRowChecked(e), let evC = sqlite3_column_text(e, 0) {
                    return String(cString: evC)
                }
                // 自愈：completed 却完全没有 played 回执（旧版本数据），补建
            }
            let u = try prepareChecked("UPDATE playback_jobs SET state='completed', completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), next_retry_at=NULL, started_at=NULL WHERE message_id=?;")
            defer { sqlite3_finalize(u) }
            try bind(u, 1, .text(messageId))
            try stepDoneChecked(u)
            let eventId = UUID().uuidString
            let a = try prepareChecked("INSERT INTO ack_outbox(event_id,message_id,device_id,status) VALUES(?,?,?,'played') ON CONFLICT(event_id) DO NOTHING;")
            defer { sqlite3_finalize(a) }
            try bind(a, 1, .text(eventId))
            try bind(a, 2, .text(messageId))
            try bind(a, 3, .text(deviceId))
            try stepDoneChecked(a)
            return eventId
        }
    }

    /// 失败：attempts+1；达阈值转 needs_attention（保留，不删除，T08）；否则 retry_wait + 指数退避（封顶 60s）
    func markFailed(_ messageId: String, error: String, threshold: Int, now: TimeInterval = Date().timeIntervalSince1970) throws {
        try queue.sync {
            let cur = try currentAttemptsNow(messageId)
            let next = cur + 1
            let isAttention = next >= threshold
            let state = isAttention ? "needs_attention" : "retry_wait"
            let backoff = isAttention ? 0.0 : min(pow(2.0, Double(next)), 60.0)
            let nrt: TimeInterval? = isAttention ? nil : (now + backoff)
            let stmt = try prepareChecked("UPDATE playback_jobs SET state=?, attempts=?, next_retry_at=?, last_error=?, started_at=NULL WHERE message_id=?;")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, .text(state))
            try bind(stmt, 2, .int(Int64(next)))
            if let t = nrt { try bind(stmt, 3, .dbl(t)) } else { try bind(stmt, 3, .nul) }
            try bind(stmt, 4, .text(error))
            try bind(stmt, 5, .text(messageId))
            try stepDoneChecked(stmt)
        }
    }

    func retryAttention(_ messageId: String) throws {
        try setJobState(messageId, "queued", nil)
    }

    /// 崩溃恢复：playing 视为结果不确定，重排为 queued（允许少量重复播报，T04）
    func recoverInterrupted() throws {
        try exec("UPDATE playback_jobs SET state='queued', started_at=NULL WHERE state='playing';")
    }

    private func currentAttemptsNow(_ messageId: String) throws -> Int {
        let stmt = try prepareChecked("SELECT attempts FROM playback_jobs WHERE message_id=?;")
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, 1, .text(messageId))
        return try stepRowChecked(stmt) ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func setJobState(_ messageId: String, _ state: String, _ error: String?) throws {
        try queue.sync {
            let stmt = try prepareChecked("UPDATE playback_jobs SET state=?, last_error=?, started_at=NULL WHERE message_id=?;")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, .text(state))
            if let e = error { try bind(stmt, 2, .text(e)) } else { try bind(stmt, 2, .nul) }
            try bind(stmt, 3, .text(messageId))
            try stepDoneChecked(stmt)
        }
    }

    // MARK: - ACK Outbox 处理（T05：失败持续重试，不改变本地已播放事实）
    func undeliveredAcks() throws -> [AckRow] {
        try queue.sync {
            // P1-A：被隔离的异常回执（409/404）不参与自动重试，等待人工检查
            let stmt = try prepareChecked("SELECT event_id,message_id,device_id,status FROM ack_outbox WHERE delivered_at IS NULL AND quarantined_at IS NULL;")
            defer { sqlite3_finalize(stmt) }
            var out: [AckRow] = []
            while try stepRowChecked(stmt) {
                guard let c0 = sqlite3_column_text(stmt, 0), let c1 = sqlite3_column_text(stmt, 1),
                      let c2 = sqlite3_column_text(stmt, 2), let c3 = sqlite3_column_text(stmt, 3) else {
                    throw NVError.stepFailed(-1, "ack_outbox 行含 NULL")
                }
                out.append(AckRow(eventId: String(cString: c0), messageId: String(cString: c1),
                                  deviceId: String(cString: c2), status: String(cString: c3)))
            }
            return out
        }
    }

    func markAckDelivered(_ eventId: String) throws {
        try queue.sync {
            let stmt = try prepareChecked("UPDATE ack_outbox SET delivered_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE event_id=?;")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, .text(eventId))
            try stepDoneChecked(stmt)
        }
    }

    func bumpAckAttempt(_ eventId: String, nextRetryAt: TimeInterval) throws {
        try queue.sync {
            let stmt = try prepareChecked("UPDATE ack_outbox SET attempts=attempts+1, next_retry_at=? WHERE event_id=?;")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, .dbl(nextRetryAt))
            try bind(stmt, 2, .text(eventId))
            try stepDoneChecked(stmt)
        }
    }

    func pendingAckCount() throws -> Int {
        try queue.sync {
            let stmt = try prepareChecked("SELECT COUNT(*) FROM ack_outbox WHERE delivered_at IS NULL AND quarantined_at IS NULL;")
            defer { sqlite3_finalize(stmt) }
            guard try stepRowChecked(stmt) else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    // MARK: - 异常回执隔离（P1-A：409/404 不能当成功，也不能无限重试）
    func quarantineAck(_ eventId: String, reason: String) throws {
        try queue.sync {
            let stmt = try prepareChecked("UPDATE ack_outbox SET quarantined_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), quarantine_reason=? WHERE event_id=? AND delivered_at IS NULL;")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, .text(reason))
            try bind(stmt, 2, .text(eventId))
            try stepDoneChecked(stmt)
        }
    }

    func quarantinedAckCount() throws -> Int {
        try queue.sync {
            let stmt = try prepareChecked("SELECT COUNT(*) FROM ack_outbox WHERE delivered_at IS NULL AND quarantined_at IS NOT NULL;")
            defer { sqlite3_finalize(stmt) }
            guard try stepRowChecked(stmt) else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// 人工检查后解除隔离，重新纳入自动重试（清空累计 attempts，避免立刻又被隔离）
    func unquarantineAcks() throws -> Int {
        try queue.sync {
            let stmt = try prepareChecked("UPDATE ack_outbox SET quarantined_at=NULL, quarantine_reason=NULL, attempts=0, next_retry_at=NULL WHERE delivered_at IS NULL AND quarantined_at IS NOT NULL;")
            defer { sqlite3_finalize(stmt) }
            try stepDoneChecked(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    var failedCount: Int { (try? needAttentionJobs().count) ?? 0 }

    // MARK: - 播放历史（SQLite，替代原 history.json）
    func insertHistory(id: String, messageId: String, action: String, engine: String, result: String, text: String, at: TimeInterval = Date().timeIntervalSince1970) throws {
        try queue.sync {
            let stmt = try prepareChecked("INSERT INTO playback_history(id,message_id,action,engine,result,text,occurred_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET result=excluded.result;")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, .text(id))
            try bind(stmt, 2, .text(messageId))
            try bind(stmt, 3, .text(action))
            try bind(stmt, 4, .text(engine))
            try bind(stmt, 5, .text(result))
            try bind(stmt, 6, .text(text))
            try bind(stmt, 7, .dbl(at))
            try stepDoneChecked(stmt)
        }
    }

    func recentHistory(limit: Int = 500) throws -> [[String: Any]] {
        try queue.sync {
            let stmt = try prepareChecked("SELECT id,message_id,action,engine,result,text,occurred_at FROM playback_history ORDER BY occurred_at DESC LIMIT ?;")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, .int(Int64(limit)))
            var out: [[String: Any]] = []
            while try stepRowChecked(stmt) {
                guard let c0 = sqlite3_column_text(stmt, 0), let c1 = sqlite3_column_text(stmt, 1),
                      let c2 = sqlite3_column_text(stmt, 2), let c3 = sqlite3_column_text(stmt, 3),
                      let c4 = sqlite3_column_text(stmt, 4), let c5 = sqlite3_column_text(stmt, 5) else {
                    throw NVError.stepFailed(-1, "playback_history 行含 NULL")
                }
                out.append([
                    "id": String(cString: c0),
                    "messageId": String(cString: c1),
                    "action": String(cString: c2),
                    "engine": String(cString: c3),
                    "result": String(cString: c4),
                    "text": String(cString: c5),
                    "occurredAt": sqlite3_column_double(stmt, 6)
                ])
            }
            return out
        }
    }

    /// 存储健康探针：FIX-03「重新连接数据库」用——一次写入 + 回读验证
    func healthProbe() throws {
        try setState("storage_probe", "ok")
        guard try getState("storage_probe") == "ok" else { throw NVError.verifyFailed("存储探针回读失败") }
    }

    func close() { if let d = db { sqlite3_close(d); db = nil } }
}
