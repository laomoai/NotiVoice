// NotiVoice V1.1 持久层单元测试
// 覆盖：入库+游标原子性（T02/T03）、任务状态机（T08/T18）、ACK Outbox 重试（T05）、
// 崩溃恢复（T04）、重新打开数据库持久化（T17）、device_id 稳定性。
// 通过真实 SQLite 文件 + 关闭后重新打开来模拟进程重启/崩溃恢复。
import XCTest
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
        XCTAssertEqual(db.cursor, 2)
        XCTAssertEqual(db.jobs(in: ["queued"]).count, 2)
        XCTAssertEqual(db.undeliveredAcks().count, 2)
        XCTAssertEqual(db.pendingAckCount(), 2)
    }

    // T02：游标与消息必须同事务提交（提交后两者一致；若中途失败应整体回滚）
    func testCursorConsistencyWithMessages() throws {
        let db = try Persistence(path: dbPath)
        let ins = try db.storePage([makeMsg(seq: 1, id: "m1"), makeMsg(seq: 2, id: "m2")], newCursor: 5)
        XCTAssertEqual(ins, 2)
        // 提交成功后，游标与已入库消息数一致
        XCTAssertEqual(db.cursor, 5)
        XCTAssertEqual(db.jobs(in: ["queued"]).count, 2)
        // 幂等 idempotency：同 id 重复入库不新增、游标仍按新值前进
        let again = try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 6)
        XCTAssertEqual(again, 0, "重复 message_id 不应再插入")
        XCTAssertEqual(db.cursor, 6)
    }

    // T04/T18：崩溃恢复 —— playing 任务在重新打开后应被重排为 queued（允许少量重复播报，不丢消息）
    func testRecoverInterruptedPlayingToQueued() throws {
        let db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 1)
        db.markPlaying("m1")
        XCTAssertEqual(db.jobs(in: ["playing"]).count, 1)
        db.recoverInterrupted()
        XCTAssertEqual(db.jobs(in: ["playing"]).count, 0)
        XCTAssertEqual(db.jobs(in: ["queued"]).count, 1)
    }

    // T08：失败不永久丢弃 —— 指数退避封顶 60s；达阈值转 needs_attention（保留不删）
    func testFailureRetryBackoffAndAttention() throws {
        let db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 1)
        let now = Date().timeIntervalSince1970
        db.markFailed("m1", error: "net", threshold: 3, now: now)
        var j = db.jobs(in: ["retry_wait"]).first; XCTAssertEqual(j?.attempts, 1)
        XCTAssertNotNil(j?.nextRetryAt)
        XCTAssertLessThanOrEqual(j?.nextRetryAt ?? 0, now + 2.0 + 0.01)
        db.markFailed("m1", error: "net", threshold: 3, now: now)
        XCTAssertEqual(db.jobs(in: ["retry_wait"]).first?.attempts, 2)
        db.markFailed("m1", error: "net", threshold: 3, now: now)
        XCTAssertEqual(db.jobs(in: ["needs_attention"]).count, 1, "达阈值后应转入 needs_attention")
        XCTAssertEqual(db.failedCount, 1)
        // 仍在库中，未删除（T08：不永久丢弃）
        XCTAssertEqual(db.jobs(in: ["needs_attention", "retry_wait", "queued", "playing"]).count, 1)
        db.retryAttention("m1")
        XCTAssertEqual(db.jobs(in: ["queued"]).count, 1, "手动重播应回到 queued")
    }

    // T05：ACK Outbox 持续重试 —— 仅标记 delivered 才出队，本地已播放事实不变
    func testAckOutboxRetry() throws {
        let db = try Persistence(path: dbPath)
        db.enqueueAcks([(messageId: "m1", status: "played", eventId: "ev1")], deviceId: "devA")
        XCTAssertEqual(db.pendingAckCount(), 1)
        db.bumpAckAttempt("ev1", nextRetryAt: Date().timeIntervalSince1970 + 5)
        XCTAssertEqual(db.pendingAckCount(), 1, "仅 bump 不应出队")
        db.markAckDelivered("ev1")
        XCTAssertEqual(db.pendingAckCount(), 0)
        XCTAssertEqual(db.undeliveredAcks().count, 0)
    }

    // T17：重新打开数据库后数据持久化（模拟进程重启）
    func testReopenPersistsData() throws {
        var db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 9)
        let dev1 = db.deviceId
        db.insertHistory(id: "h1", messageId: "m1", action: "auto", engine: "fish", result: "ok", text: "内容1")
        db.close()

        db = try Persistence(path: dbPath)
        XCTAssertEqual(db.cursor, 9, "重开后游标应持久化")
        XCTAssertEqual(db.jobs(in: ["queued"]).count, 1)
        XCTAssertEqual(db.deviceId, dev1, "device_id 应跨重启稳定")
        XCTAssertEqual(db.recentHistory().count, 1, "历史应持久化")
    }

    // device_id 稳定性：同路径多次打开返回同一值
    func testDeviceIdStable() throws {
        let db1 = try Persistence(path: dbPath)
        let a = db1.deviceId
        db1.close()
        let db2 = try Persistence(path: dbPath)
        let b = db2.deviceId
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    // 到期任务选取：retry_wait 且到点的应进入 dueJobs
    func testDueJobsIncludesRetryWaitWhenDue() throws {
        let db = try Persistence(path: dbPath)
        try db.storePage([makeMsg(seq: 1, id: "m1")], newCursor: 1)
        let now = Date().timeIntervalSince1970
        db.markFailed("m1", error: "x", threshold: 99, now: now)
        let due = db.dueJobs(now: now + 100)
        XCTAssertEqual(due.count, 1, "已到点退避任务应在 dueJobs 中")
        let notDue = db.dueJobs(now: now)
        XCTAssertEqual(notDue.count, 0, "未到点退避任务不应出现在 dueJobs")
    }
}
