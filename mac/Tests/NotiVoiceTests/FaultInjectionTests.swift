// NotiVoice V1.1.2 物理/引擎级故障注入（FIX-01 / FIX-03 验证）
// 全部在临时目录用真实 SQLite 文件，不触碰用户真实数据库与 Keychain。
// 覆盖：权限拒绝、库文件损坏、SQLITE_FULL（磁盘满等价）、COMMIT 阶段延迟约束失败、
//       事务中途 ABORT 整批回滚、device_id 写入失败不得返回未持久化 ID。
import XCTest
import SQLite3
@testable import NotiVoice

final class FaultInjectionTests: XCTestCase {
    var tmpDir: String!
    var dbPath: String!

    override func setUp() {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nvfi_\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        dbPath = (tmpDir as NSString).appendingPathComponent("test.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpDir)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbPath)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbPath + suffix)
        }
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func makeMsg(seq: Int, id: String, content: String = "内容") -> IncomingMessage {
        IncomingMessage(seq: seq, id: id, title: "标题\(seq)", content: content,
                        text: content, priority: "normal", voiceSlot: 1,
                        createdAt: "2026-01-01T00:00:00.000Z")
    }

    /// 在 Persistence 的串行事务内执行一条只读 SQL，返回第一列整数。
    private func scalar(_ db: Persistence, _ sql: String) throws -> Int {
        try db.transaction { handle -> Int in
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let s = stmt else { return -1 }
            defer { sqlite3_finalize(s) }
            guard sqlite3_step(s) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int64(s, 0))
        }
    }

    // FI-A：库文件损坏 → 初始化必须抛错，且原文件保留、不自动重建/删除、不产生降级库
    func testCorruptDatabaseFileThrowsAndPreservesFile() throws {
        let db = try Persistence(path: dbPath)
        db.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        let garbage = Data(repeating: 0xAB, count: 4096)
        try garbage.write(to: URL(fileURLWithPath: dbPath))

        XCTAssertThrowsError(try Persistence(path: dbPath)) { err in
            XCTAssertTrue(err is NVError, "应抛 NVError，实际 \(type(of: err))")
        }
        let after = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        XCTAssertEqual(after.prefix(16), garbage.prefix(16), "损坏文件被自动重建/覆盖了")
        let entries = try FileManager.default.contentsOfDirectory(atPath: tmpDir)
        XCTAssertFalse(entries.contains { $0.contains("fallback") || $0.contains("temp") },
                       "不得自动创建临时/降级数据库：\(entries)")
    }

    // FI-B：权限拒绝（目录只读 + 库文件只读）→ 打开即失败，不得静默继续
    func testReadOnlyDatabaseRejectsOpen() throws {
        let db = try Persistence(path: dbPath)
        db.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dbPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmpDir)

        XCTAssertThrowsError(try Persistence(path: dbPath)) { err in
            switch err {
            case NVError.openFailed:
                break   // 打开阶段即被拒
            case NVError.execFailed(let msg):
                XCTAssertTrue(msg.localizedCaseInsensitiveContains("readonly"),
                              "只读库应在 WAL/PRAGMA 阶段报只读错误，实际 \(msg)")
            default:
                XCTFail("权限拒绝应抛 openFailed/execFailed，实际 \(err)")
            }
        }
        // 恢复权限后同一文件可正常打开，证明是权限故障而非数据损坏
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpDir)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbPath)
        let reopened = try Persistence(path: dbPath)
        XCTAssertEqual(try reopened.readCursor(), 0)
        reopened.close()
    }

    // FI-C：SQLITE_FULL（磁盘满等价）→ 写事务整体回滚，游标不前进、无任务、无回执
    func testSQLiteFullRollsBackWholeTransaction() throws {
        let db = try Persistence(path: dbPath)
        defer { db.close() }
        // 回滚日志模式下 max_page_count 才会对事务写入生效（WAL 新页先落 -wal）
        try db.exec("PRAGMA journal_mode=DELETE;")
        let pages = try scalar(db, "PRAGMA page_count;")
        XCTAssertGreaterThan(pages, 0)
        try db.exec("PRAGMA max_page_count=\(pages + 1);")

        let big = String(repeating: "X", count: 1_500_000)
        XCTAssertThrowsError(try db.storePageAndAcks([makeMsg(seq: 7, id: "full-1", content: big)],
                                                     newCursor: 7,
                                                     acks: [(messageId: "full-1", status: "received", eventId: "fi-full-ev")],
                                                     deviceId: "devFI"))
        XCTAssertEqual(try db.readCursor(), 0, "写入失败后游标不得前进")
        XCTAssertTrue(try db.jobs(in: ["queued"]).isEmpty, "写入失败后不得残留待播任务")
        XCTAssertTrue(try db.undeliveredAcks().isEmpty, "写入失败后不得残留回执")
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM messages;"), 0)

        // 放宽限制后同一批次可成功重放，证明无半提交状态
        try db.exec("PRAGMA max_page_count=0;")
        let n = try db.storePageAndAcks([makeMsg(seq: 7, id: "full-1")],
                                        newCursor: 7,
                                        acks: [(messageId: "full-1", status: "received", eventId: "fi-full-ev")],
                                        deviceId: "devFI")
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try db.readCursor(), 7)
        XCTAssertEqual(try db.undeliveredAcks().count, 1)
    }

    // FI-D：COMMIT 阶段失败（延迟外键约束）→ 必须上抛且整笔回滚
    func testCommitFailureThrowsAndRollsBack() throws {
        let db = try Persistence(path: dbPath)
        defer { db.close() }
        try db.exec("CREATE TABLE fi_parent(id INTEGER PRIMARY KEY);")
        try db.exec("CREATE TABLE fi_child(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES fi_parent(id) DEFERRABLE INITIALLY DEFERRED);")

        XCTAssertThrowsError(try db.transaction { handle -> Void in
            let rc = sqlite3_exec(handle, "INSERT INTO fi_child(parent_id) VALUES(999);", nil, nil, nil)
            XCTAssertEqual(rc, SQLITE_OK, "延迟约束应在 COMMIT 时才失败")
        }) { err in
            guard case NVError.execFailed = err else { return XCTFail("COMMIT 失败应上抛 execFailed，实际 \(err)") }
        }
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM fi_child;"), 0, "COMMIT 失败后必须回滚")
    }

    // FI-E：事务中途 ABORT（Outbox 插入被触发器拦截）→ 消息/任务/游标/回执同生同灭
    func testMidTransactionAbortKeepsAllStateConsistent() throws {
        let db = try Persistence(path: dbPath)
        defer { db.close() }
        try db.exec("CREATE TRIGGER trg_fi_abort BEFORE INSERT ON ack_outbox BEGIN SELECT RAISE(ABORT,'fi_abort'); END;")

        let acks = [(messageId: "abort-1", status: "received", eventId: "fi-abort-ev")]
        XCTAssertThrowsError(try db.storePageAndAcks([makeMsg(seq: 9, id: "abort-1")],
                                                     newCursor: 9, acks: acks, deviceId: "devFI"))
        XCTAssertEqual(try db.readCursor(), 0, "游标不得前进")
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM messages;"), 0)
        XCTAssertTrue(try db.jobs(in: ["queued"]).isEmpty)
        XCTAssertTrue(try db.undeliveredAcks().isEmpty)

        try db.exec("DROP TRIGGER trg_fi_abort;")
        let n = try db.storePageAndAcks([makeMsg(seq: 9, id: "abort-1")],
                                        newCursor: 9, acks: acks, deviceId: "devFI")
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try db.readCursor(), 9)
        XCTAssertEqual(try db.undeliveredAcks().count, 1)
    }

    // FI-F：device_id 首次写入失败 → 不得返回未持久化的随机 ID；恢复后 ID 稳定
    func testDeviceIdWriteFailureDoesNotReturnUnpersistedId() throws {
        let db = try Persistence(path: dbPath)
        try db.exec("CREATE TRIGGER trg_fi_device BEFORE INSERT ON app_state WHEN NEW.key='device_id' BEGIN SELECT RAISE(ABORT,'fi_device'); END;")
        XCTAssertThrowsError(try db.ensureDeviceId())
        XCTAssertNil(try db.getState("device_id"), "失败后不得留下未验证的 device_id")
        try db.exec("DROP TRIGGER trg_fi_device;")

        let id = try db.ensureDeviceId()
        XCTAssertFalse(id.isEmpty)
        db.close()

        let reopened = try Persistence(path: dbPath)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.ensureDeviceId(), id, "重开库后 device_id 必须稳定")
    }
}
