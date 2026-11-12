// NotiVoice 显示时区单元测试
// 数据层始终用 UTC 时刻（ISO 8601 Z）；DisplayClock 只负责「给人看」的格式化。
// 验证统一时区生效、跨日边界、配置可改、非法值兜底、日志带时区标识。
import XCTest
@testable import NotiVoice

final class TimezoneTests: XCTestCase {
    private func utc(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }

    func testShanghaiConvertsUTCToBeijing() {
        let c = DisplayClock(identifier: "Asia/Shanghai")
        let d = utc("2026-11-12T01:02:42Z")
        XCTAssertEqual(c.full(d), "2026-11-12 09:02:42")
        XCTAssertEqual(c.time(d), "09:02:42")
    }

    func testAlternativeTimezoneIsHonoured() {
        let d = utc("2026-11-12T01:02:42Z")
        XCTAssertEqual(DisplayClock(identifier: "UTC").full(d), "2026-11-12 01:02:42")
        // 冬令时 EST = UTC-5
        XCTAssertEqual(DisplayClock(identifier: "America/New_York").full(d), "2026-11-11 20:02:42")
    }

    func testCrossMidnightUsesDisplayZone() {
        let c = DisplayClock(identifier: "Asia/Shanghai")
        let d = utc("2026-11-11T16:30:00Z")   // 北京 11-12 00:30
        XCTAssertEqual(c.full(d), "2026-11-12 00:30:00")
        XCTAssertEqual(c.calendar.component(.day, from: d), 12)
        XCTAssertEqual(c.calendar.component(.hour, from: d), 0)
    }

    func testZoneLabelAndInvalidFallback() {
        XCTAssertTrue(DisplayClock(identifier: "Asia/Shanghai").label.contains("UTC+8"))
        // 配置写错时退回 UTC+8，不崩溃
        let c = DisplayClock(identifier: "Invalid/Zone")
        XCTAssertEqual(c.full(utc("2026-11-12T01:02:42Z")), "2026-11-12 09:02:42")
    }

    func testLogStampCarriesZone() {
        let s = DisplayClock(identifier: "Asia/Shanghai").logStamp(utc("2026-11-12T01:02:42Z"))
        XCTAssertTrue(s.hasPrefix("2026-11-12 09:02:42"))
        XCTAssertTrue(s.contains("UTC+8"))
    }
}
