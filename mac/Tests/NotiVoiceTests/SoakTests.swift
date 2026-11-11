// NotiVoice V1.1 持久层长循环回归（Mac mini M4）
// 120 轮「重开库 → 入库 → 播放完成 → 部分回执延迟投递」，每轮关闭数据库模拟进程重启。
// 断言：游标单调、消息不丢、事件不重复、任务不残留、未送达回执可跨重启补发。
import XCTest
import SQLite3
@testable import NotiVoice

final class SoakTests: XCTestCase {
    private func scalar(_ db: Persistence, _ sql: String) throws -> Int {
        try db.transaction { handle -> Int in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return -1 }
            defer { sqlite3_finalize(s) }
            guard sqlite3_step(s) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int64(s, 0))
        }
    }

    func testRepeatedStorePlayAckRestartCycles() throws {
        let cycles = 120
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nvsoak_\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("soak.sqlite")
        let dev = "devSoak"

        for cycle in 1...cycles {
            let db = try Persistence(path: path)          // 每轮重开：模拟崩溃/重启
            try db.recoverInterrupted()
            let id = "soak-\(cycle)"
            let msg = IncomingMessage(seq: cycle, id: id, title: "标题\(cycle)", content: "内容\(cycle)",
                                      text: "内容\(cycle)", priority: "normal", voiceSlot: 1,
                                      createdAt: "2026-01-01T00:00:00.000Z")
            XCTAssertEqual(try db.storePageAndAcks([msg], newCursor: cycle,
                                                   acks: [(messageId: id, status: "received", eventId: "soak-recv-\(cycle)")],
                                                   deviceId: dev), 1)
            try db.markPlaying(id)
            _ = try db.completeAndEnqueuePlayed(id, deviceId: dev)
            XCTAssertEqual(try db.readCursor(), cycle, "第 \(cycle) 轮游标不一致")

            // 每 3 轮故意留一批回执不投递，模拟断网；下一轮重开后必须仍可补发
            if cycle % 3 != 0 {
                for r in try db.undeliveredAcks() { try db.markAckDelivered(r.eventId) }
            }
            db.close()
        }

        let final = try Persistence(path: path)
        defer { final.close() }
        XCTAssertEqual(try final.readCursor(), cycles)
        XCTAssertEqual(try scalar(final, "SELECT COUNT(*) FROM messages;"), cycles)
        XCTAssertEqual(try scalar(final, "SELECT COUNT(*) FROM ack_outbox;"), cycles * 2)
        XCTAssertEqual(try scalar(final, "SELECT COUNT(DISTINCT event_id) FROM ack_outbox;"), cycles * 2,
                       "不得因重试产生重复事件")
        XCTAssertEqual(try scalar(final, "SELECT COUNT(*) FROM playback_jobs WHERE state IN ('queued','playing');"), 0)
        XCTAssertTrue(try final.jobs(in: ["queued", "playing"]).isEmpty)
        XCTAssertEqual(try final.pendingAckCount(), 2, "最后一轮故意未投递的 received+played 应跨重启保留")
    }
}
