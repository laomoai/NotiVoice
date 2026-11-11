// 增量审查 a231652..d0a4107 的四项缺陷回归测试
// P1-A 409/404 误判送达 / P1-B 文本绑定生命周期 / P2-C completed 重入 / P1-D storageFault 状态覆盖
import XCTest
import SQLite3
@testable import NotiVoice

final class ReliabilityFixTests: XCTestCase {
    var tmpDir: String!
    var dbPath: String!

    override func setUp() {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nvfix_\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        dbPath = (tmpDir as NSString).appendingPathComponent("test.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func makeMsg(seq: Int, id: String, text: String? = nil) -> IncomingMessage {
        IncomingMessage(seq: seq, id: id, title: "标题\(seq)", content: text ?? "内容\(seq)",
                        text: text ?? "内容\(seq)", priority: "normal", voiceSlot: 1,
                        createdAt: "2026-01-01T00:00:00.000Z")
    }

    // MARK: - P1-A：只有 2xx + {"ok":true} 才是送达；409/404 隔离；其余重试
    func testAckClassification() {
        let ok = "{\"ok\":true,\"status\":\"played\",\"applied\":true}".data(using: .utf8)
        XCTAssertEqual(AckClassifier.classify(statusCode: 200, body: ok), .delivered)
        XCTAssertEqual(AckClassifier.classify(statusCode: 201, body: ok), .delivered)
        XCTAssertEqual(AckClassifier.classify(statusCode: 200, body: "{\"ok\":false}".data(using: .utf8)), .retry)
        XCTAssertEqual(AckClassifier.classify(statusCode: 200, body: "<html>proxy</html>".data(using: .utf8)), .retry,
                       "代理返回 200 HTML 不得当作成功")
        XCTAssertEqual(AckClassifier.classify(statusCode: 204, body: nil), .retry)
        for code in [0, 401, 429, 500, 502] {
            XCTAssertEqual(AckClassifier.classify(statusCode: code, body: ok), .retry, "HTTP \(code) 应保留重试")
        }
        for code in [404, 409] {
            let outcome = AckClassifier.classify(statusCode: code, body: "{\"error\":\"event_conflict\"}".data(using: .utf8))
            guard case .quarantine(let reason) = outcome else { return XCTFail("HTTP \(code) 应隔离，实际 \(outcome)") }
            XCTAssertTrue(reason.contains("\(code)"))
            XCTAssertTrue(reason.contains("event_conflict"), "隔离原因必须记录响应体，供人工检查")
        }
    }

    func testQuarantinedAckIsNotDeliveredNorRetried() throws {
        let db = try Persistence(path: dbPath)
        let acks = [(messageId: "m1", status: "received", eventId: "e1")]
        _ = try db.storePageAndAcks([makeMsg(seq: 1, id: "m1")], newCursor: 1, acks: acks, deviceId: "devA")
        XCTAssertEqual(try db.undeliveredAcks().count, 1)

        try db.quarantineAck("e1", reason: "HTTP 409：event_conflict")
        XCTAssertEqual(try db.undeliveredAcks().count, 0, "隔离事件不得进入自动重试")
        XCTAssertEqual(try db.pendingAckCount(), 0, "隔离事件不得计入待发")
        XCTAssertEqual(try db.quarantinedAckCount(), 1)

        // 跨重启仍保持隔离，不会被重新当成普通待发回执
        let reopened = try Persistence(path: dbPath)
        XCTAssertEqual(try reopened.undeliveredAcks().count, 0)
        XCTAssertEqual(try reopened.quarantinedAckCount(), 1)
        XCTAssertEqual(try reopened.unquarantineAcks(), 1)
        XCTAssertEqual(try reopened.undeliveredAcks().count, 1, "人工解除后重新纳入重试")
        XCTAssertEqual(try reopened.quarantinedAckCount(), 0)
    }

    func testOldDatabaseMigratesToV2WithQuarantineColumns() throws {
        // 模拟 V1.1 老库：user_version=1、ack_outbox 无隔离列
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbPath, &h, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let ddl = """
        PRAGMA user_version=1;
        CREATE TABLE app_state(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE messages(message_id TEXT PRIMARY KEY, seq INTEGER UNIQUE, title TEXT, content TEXT, priority TEXT, voice_slot INTEGER, created_at TEXT, received_at TEXT);
        CREATE TABLE playback_jobs(message_id TEXT PRIMARY KEY, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, last_error TEXT, started_at TEXT, completed_at TEXT);
        CREATE TABLE ack_outbox(event_id TEXT PRIMARY KEY, message_id TEXT NOT NULL, device_id TEXT NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, delivered_at TEXT);
        CREATE TABLE playback_history(id TEXT PRIMARY KEY, message_id TEXT, action TEXT, engine TEXT, result TEXT, text TEXT, occurred_at REAL);
        """
        XCTAssertEqual(sqlite3_exec(h, ddl, nil, nil, nil), SQLITE_OK)
        sqlite3_close(h)

        let db = try Persistence(path: dbPath)   // 应自动迁移到 v2 且可写隔离列
        XCTAssertNoThrow(try db.insertHistory(id: "h1", messageId: "m1", action: "auto", engine: "test", result: "ok", text: "历史"))
        let acks = [(messageId: "m1", status: "received", eventId: "e-old")]
        _ = try db.storePageAndAcks([makeMsg(seq: 1, id: "m1")], newCursor: 1, acks: acks, deviceId: "devA")
        XCTAssertNoThrow(try db.quarantineAck("e-old", reason: "HTTP 404"))
        XCTAssertEqual(try db.quarantinedAckCount(), 1)
        // 重复打开不得重复 ALTER 报 duplicate column
        XCTAssertNoThrow(try Persistence(path: dbPath))
    }

    // MARK: - P1-B：SQLITE_TRANSIENT 立即复制，中文 / Emoji / 长文本 / 多次绑定必须逐字一致
    func testTextBindingHandlesUnicodeLongTextAndStatementReuse() throws {
        let db = try Persistence(path: dbPath)
        let samples = [
            "中文通知：会议将在 10 分钟后开始",
            "🚨 Emoji 告警 🔥 äöü ß 日本語 한국어",
            String(repeating: "长文本ABC123", count: 900),
            "引号 ' 与双引号 \" 与换行 \n 与制表 \t",
        ]
        for (i, s) in samples.enumerated() {
            _ = try db.storePage([makeMsg(seq: i + 1, id: "m\(i + 1)", text: s)], newCursor: i + 1)
        }
        for i in 1...100 {
            _ = try db.storePage([makeMsg(seq: 1000 + i, id: "x\(i)", text: "复用-\(i)-🍎")], newCursor: 1000 + i)
        }
        let jobs = try db.jobs(in: ["queued"])
        XCTAssertEqual(jobs.count, samples.count + 100)
        for j in jobs {
            let expected = j.seq <= samples.count ? samples[j.seq - 1] : "复用-\(j.seq - 1000)-🍎"
            XCTAssertEqual(j.text, expected, "seq=\(j.seq) 文本必须逐字一致")
        }
    }

    // MARK: - P2-C：played 事件已送达后，completed 重入不得再生成新事件
    func testCompleteAfterDeliveredDoesNotCreateNewEvent() throws {
        let db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 1)
        try db.markPlaying("m1")
        let ev1 = try db.completeAndEnqueuePlayed("m1", deviceId: "devA")
        try db.markAckDelivered(ev1)
        XCTAssertEqual(try db.undeliveredAcks().count, 0)

        let ev2 = try db.completeAndEnqueuePlayed("m1", deviceId: "devA")
        XCTAssertEqual(ev1, ev2, "已送达后重入必须返回原 event_id")
        XCTAssertEqual(try db.undeliveredAcks().count, 0, "不得生成新的待发 played 事件")

        let total: Int = try db.transaction { p in
            var s: OpaquePointer?
            defer { if let s { sqlite3_finalize(s) } }
            guard sqlite3_prepare_v2(p, "SELECT COUNT(*) FROM ack_outbox WHERE message_id='m1' AND status='played';", -1, &s, nil) == SQLITE_OK else { return -1 }
            sqlite3_step(s)
            return Int(sqlite3_column_int(s, 0))
        }
        XCTAssertEqual(total, 1, "整张表里只能有一条 played 事件")
    }

    // MARK: - P1-D：初始化 / 重连失败必须保持 storageFault 且不启动网络任务
    @MainActor
    func testCorruptDatabaseKeepsStorageFaultAndStopsNetworkTasks() throws {
        let root = URL(fileURLWithPath: tmpDir)
        let p = root.appendingPathComponent("notivoice.sqlite").path
        try Data("not-a-sqlite-file".utf8).write(to: URL(fileURLWithPath: p))
        let store = VoiceStore(sandboxRoot: root)
        guard case .storageFault = store.health else { return XCTFail("损坏库必须进入 storageFault，实际 \(store.health)") }
        XCTAssertFalse(store.storageOK)
        store.startIfNeeded()          // 故障态不得启动定时器
        store.retryStorage()           // 重连失败不得把状态覆盖为 checking
        guard case .storageFault = store.health else { return XCTFail("重连失败后不得覆盖故障态") }
        XCTAssertFalse(store.storageOK)
    }

    @MainActor
    func testHistoryReadFailurePropagatesToStorageFault() throws {
        let root = URL(fileURLWithPath: tmpDir)
        let p = root.appendingPathComponent("notivoice.sqlite").path
        // user_version=2 让迁移跳过，故意缺 playback_history 表 → loadHistoryFromDB 必抛错
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(p, &h, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let ddl = """
        PRAGMA user_version=2;
        CREATE TABLE app_state(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE messages(message_id TEXT PRIMARY KEY, seq INTEGER UNIQUE, title TEXT, content TEXT, priority TEXT, voice_slot INTEGER, created_at TEXT, received_at TEXT);
        CREATE TABLE playback_jobs(message_id TEXT PRIMARY KEY, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, last_error TEXT, started_at TEXT, completed_at TEXT);
        CREATE TABLE ack_outbox(event_id TEXT PRIMARY KEY, message_id TEXT NOT NULL, device_id TEXT NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, delivered_at TEXT, quarantined_at TEXT, quarantine_reason TEXT);
        """
        XCTAssertEqual(sqlite3_exec(h, ddl, nil, nil, nil), SQLITE_OK)
        sqlite3_close(h)

        let store = VoiceStore(sandboxRoot: root)
        guard case .storageFault = store.health else { return XCTFail("历史读取失败必须传播为 storageFault，实际 \(store.health)") }
        XCTAssertFalse(store.storageOK, "不得留半初始化状态继续拉取/播报/发回执")
    }
}
