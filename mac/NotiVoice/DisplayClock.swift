import Foundation

/// 全应用「给人看的时间」的统一入口。
/// 显示时区唯一来源：仓库根目录 `TIMEZONE`，出包时由 `mac/build-app.command` 写入 Info.plist 的 `NVDisplayTimezone`。
/// 数据层（D1 / API / 本地 SQLite）始终保存 UTC 时刻（ISO 8601 Z / timeIntervalSince1970），此类型只负责展示。
struct DisplayClock {
    let identifier: String
    let timeZone: TimeZone

    init(identifier: String) {
        self.identifier = identifier
        // 配置写错时退回 UTC+8，避免崩溃；门禁脚本会拦截非法时区名。
        self.timeZone = TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 8 * 3600)!
    }

    static let shared = DisplayClock(
        identifier: Bundle.main.object(forInfoDictionaryKey: "NVDisplayTimezone") as? String ?? "Asia/Shanghai"
    )

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// 例：`Asia/Shanghai（UTC+8）`；offset 按当前日期动态计算，含夏令时的时区会自动变化。
    var label: String {
        let seconds = timeZone.secondsFromGMT(for: Date())
        let sign = seconds >= 0 ? "+" : "-"
        let value = abs(seconds)
        let h = value / 3600
        let m = (value % 3600) / 60
        let off = m == 0 ? "UTC\(sign)\(h)" : "UTC\(sign)\(h):\(String(format: "%02d", m))"
        return "\(identifier)（\(off)）"
    }

    func full(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = timeZone
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// 诊断日志用：带完整日期与时区标识，避免日志里再出现 UTC / 本地时间混用。
    func logStamp(_ date: Date = Date()) -> String {
        "\(full(date)) \(label)"
    }
}
