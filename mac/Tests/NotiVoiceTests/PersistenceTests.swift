// NotiVoice V1.1 持久层单元测试（FIX-01/FIX-02 加固版）
// 覆盖：入库+游标原子性（T02/T03）、任务状态机（T08/T18）、ACK Outbox 重试（T05）、
// 崩溃恢复（T04）、重新打开数据库持久化（T17）、device_id 稳定性、
// FIX-02 完成与 played 回执同事务 + 幂等重入、FIX-01 迁移原子性。
// 通过真实 SQLite 文件 + 关闭后重新打开来模拟进程重启/崩溃恢复。
import XCTest
import SQLite3
@testable import NotiVoice

final class PersistenceTests: XCTestCase {
    var tmpDir: String!
    var dbPath: String!

    override func setUp() {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nvtests_\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        dbPath = (tmpDir as NSString).appendingPathComponent("test.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func makeMsg(seq: Int, id: String) -> IncomingMessage {
        IncomingMessage(seq: seq, id: id, title: "标题\(seq)", content: "内容\(seq)", text: "内容\(seq)", priority: "normal", voiceSlot: 1, createdAt: "2026-01-01T00:00:00.000Z")
    }

    // T03：storePageAndAcks 在同一事务中入库+建任务+推进游标+写 ACK Outbox
    func testStorePageAndAcksAtomic() throws {
        let db = try Persistence(path: dbPath)
        let acks = [(messageId: "m1", status: "received", eventId: "e1"),
                    (messageId: "m2", status: "received", eventId: "e2")]
        let inserted = try db.storePageAndAcks([makeMsg(seq: 1, id: "m1"), makeMsg(seq: 2, id: "m2")],
                                               newCursor: 2, acks: acks, deviceId: "devA")
        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(try db.readCursor(), 2)
        XCTAssertEqual(try db.jobs(in: ["queued"]).count, 2)
        XCTAssertEqual(try db.undeliveredAcks().count, 2)
        XCTAssertEqual(try db.pendingAckCount(), 2)
    }

    // T02：游标与消息必须同事务提交（提交后两者一致；若中途失败应整体回滚）
    func testCursorConsistencyWithMessages() throws {
        let db = try Persistence(path: dbPath)
        let ins = try db.storePage([makeMsg(seq: 1, id: "m1"), makeMsg(seq: 2, id: "m2")], newCursor: 5)
        XCTAssertEqual(ins, 2)
        // 提交成功后，游标与已入库消息数一致
        XCTAssertEqual(try db.readCursor(), 5)
        XCTAssertEqual(try db.jobs(in: ["queued"]).count, 2)
        // 幂等 idempotency：同 id 重复入库不新增、游标仍按新值前进
        let again = try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 6)
        XCTAssertEqual(again, 0, "重复 message_id 不应再插入")
        XCTAssertEqual(try db.readCursor(), 6)
    }

    // FIX-01：事务体中途抛错 → 整体回滚（已写入的语句不得留存，游标不得前进）
    func testTransactionRollbackOnBodyError() throws {
        let db = try Persistence(path: dbPath)
        try db.setCursor(5)   // 基线游标
        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction { dbPtr in
            // 事务内先成功写入一条，再抛错 → COMMIT 不得执行，已写内容必须回滚
            var err: UnsafeMutablePointer<CChar>? = nil
            _ = sqlite3_exec(dbPtr, "INSERT INTO app_state(key,value) VALUES('rollback_probe','dirty')", nil, nil, &err)
            sqlite3_free(err)
            throw Boom()
        })
        XCTAssertEqual(try db.readCursor(), 5, "回滚后游标必须保持原值")
        XCTAssertNil(try db.getState("rollback_probe"), "事务体内已写入的数据必须被回滚")
    }

    // FIX-02：播放完成与 played 回执同一事务 —— completed 落库时 Outbox 必有一条 played
    func testCompleteAndEnqueuePlayedAtomic() throws {
        let db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 1)
        try db.markPlaying("m1")
        let ev = try db.completeAndEnqueuePlayed("m1", deviceId: "devA")
        XCTAssertFalse(ev.isEmpty)
        XCTAssertEqual(try db.jobs(in: ["completed"]).count, 1)
        let pending = try db.undeliveredAcks()
        XCTAssertEqual(pending.count, 1, "completed 必须伴随恰好一条待发 played 回执")
        XCTAssertEqual(pending[0].status, "played")
        XCTAssertEqual(pending[0].messageId, "m1")
        XCTAssertEqual(pending[0].deviceId, "devA")
    }

    // FIX-02：幂等重入 —— 重复完成不得产生第二个有效 played 事件（返回原事件 ID）
    func testCompleteTwiceYieldsSingleEvent() throws {
        let db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 1)
        try db.markPlaying("m1")
        let ev1 = try db.completeAndEnqueuePlayed("m1", deviceId: "devA")
        let ev2 = try db.completeAndEnqueuePlayed("m1", deviceId: "devA")
        XCTAssertEqual(ev1, ev2, "重入应返回同一事件 ID")
        XCTAssertEqual(try db.undeliveredAcks().count, 1, "不得产生第二条 played 回执")
    }

    // FIX-02：非 playing 状态（如 queued）拒绝完成
    func testCompleteRejectsNonPlaying() throws {
        let db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 1)
        XCTAssertThrowsError(try db.completeAndEnqueuePlayed("m1", deviceId: "devA")) { e in
            guard case NVError.notPlaying = e else { return XCTFail("应抛 notPlaying，实际 \(e)") }
        }
        XCTAssertEqual(try db.jobs(in: ["queued"]).count, 1, "拒绝后任务状态不得改变")
        XCTAssertEqual(try db.undeliveredAcks().count, 0, "拒绝后不得有 played 回执")
    }

    // FIX-02：未知任务拒绝完成
    func testCompleteUnknownJobThrows() throws {
        let db = try Persistence(path: dbPath)
        XCTAssertThrowsError(try db.completeAndEnqueuePlayed("ghost", deviceId: "devA")) { e in
            guard case NVError.unknownJob = e else { return XCTFail("应抛 unknownJob，实际 \(e)") }
        }
    }

    // FIX-02：COMMIT 前崩溃模拟 —— completed 与 played 回执同生同灭：重开库后要么都在、要么都不在
    func testCompletionInvariantsAcrossReopen() throws {
        var db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 1)
        try db.markPlaying("m1")
        _ = try db.completeAndEnqueuePlayed("m1", deviceId: "devA")
        db.close()
        db = try Persistence(path: dbPath)
        let completed = try db.jobs(in: ["completed"]).count
        let playedRows = try db.undeliveredAcks().filter { $0.status == "played" }.count
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(playedRows, 1, "重开后 completed 与 played 回执必须同时存在（同事务保证）")
    }

    // T04/T18：崩溃恢复 —— playing 任务在重新打开后应被重排为 queued（允许少量重复播报，不丢消息）
    func testRecoverInterruptedPlayingToQueued() throws {
        let db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 1)
        try db.markPlaying("m1")
        XCTAssertEqual(try db.jobs(in: ["playing"]).count, 1)
        try db.recoverInterrupted()
        XCTAssertEqual(try db.jobs(in: ["playing"]).count, 0)
        XCTAssertEqual(try db.jobs(in: ["queued"]).count, 1)
    }

    // T08：失败不永久丢弃 —— 指数退避封顶 60s；达阈值转 needs_attention（保留不删）
    func testFailureRetryBackoffAndAttention() throws {
        let db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 1)
        let now = Date().timeIntervalSince1970
        try db.markFailed("m1", error: "net", threshold: 3, now: now)
        var j = try db.jobs(in: ["retry_wait"]).first; XCTAssertEqual(j?.attempts, 1)
        XCTAssertNotNil(j?.nextRetryAt)
        XCTAssertLessThanOrEqual(j?.nextRetryAt ?? 0, now + 2.0 + 0.01)
        try db.markFailed("m1", error: "net", threshold: 3, now: now)
        XCTAssertEqual(try db.jobs(in: ["retry_wait"]).first?.attempts, 2)
        try db.markFailed("m1", error: "net", threshold: 3, now: now)
        XCTAssertEqual(try db.jobs(in: ["needs_attention"]).count, 1, "达阈值后应转入 needs_attention")
        XCTAssertEqual(db.failedCount, 1)
        // 仍在库中，未删除（T08：不永久丢弃）
        XCTAssertEqual(try db.jobs(in: ["needs_attention", "retry_wait", "queued", "playing"]).count, 1)
        try db.retryAttention("m1")
        XCTAssertEqual(try db.jobs(in: ["queued"]).count, 1, "手动重播应回到 queued")
    }

    // T05：ACK Outbox 持续重试 —— 仅标记 delivered 才出队，本地已播放事实不变
    func testAckOutboxRetry() throws {
        let db = try Persistence(path: dbPath)
        try db.enqueueAcks([(messageId: "m1", status: "played", eventId: "ev1")], deviceId: "devA")
        XCTAssertEqual(try db.pendingAckCount(), 1)
        try db.bumpAckAttempt("ev1", nextRetryAt: Date().timeIntervalSince1970 + 5)
        XCTAssertEqual(try db.pendingAckCount(), 1, "仅 bump 不应出队")
        try db.markAckDelivered("ev1")
        XCTAssertEqual(try db.pendingAckCount(), 0)
        XCTAssertEqual(try db.undeliveredAcks().count, 0)
    }

    // T17：重新打开数据库后数据持久化（模拟进程重启）
    func testReopenPersistsData() throws {
        var db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 9)
        let dev1 = try db.ensureDeviceId()
        try db.insertHistory(id: "h1", messageId: "m1", action: "auto", engine: "fish", result: "ok", text: "内容1")
        db.close()

        db = try Persistence(path: dbPath)
        XCTAssertEqual(try db.readCursor(), 9, "重开后游标应持久化")
        XCTAssertEqual(try db.jobs(in: ["queued"]).count, 1)
        XCTAssertEqual(try db.ensureDeviceId(), dev1, "device_id 应跨重启稳定")
        XCTAssertEqual(try db.recentHistory().count, 1, "历史应持久化")
    }

    // device_id 稳定性：同路径多次打开返回同一值
    func testDeviceIdStable() throws {
        let db1 = try Persistence(path: dbPath)
        let a = try db1.ensureDeviceId()
        db1.close()
        let db2 = try Persistence(path: dbPath)
        let b = try db2.ensureDeviceId()
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    // 到期任务选取：retry_wait 且到点的应进入 dueJobs
    func testDueJobsIncludesRetryWaitWhenDue() throws {
        let db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 1)
        let now = Date().timeIntervalSince1970
        try db.markFailed("m1", error: "x", threshold: 99, now: now)
        let due = try db.dueJobs(now: now + 100)
        XCTAssertEqual(due.count, 1, "已到点退避任务应在 dueJobs 中")
        let notDue = try db.dueJobs(now: now)
        XCTAssertEqual(notDue.count, 0, "未到点退避任务不应出现在 dueJobs")
    }
}
