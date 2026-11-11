import SwiftUI
import AppKit
import AVFoundation
import Security
import ServiceManagement
import CryptoKit

struct Notice: Codable, Identifiable, Hashable {
    let seq: Int
    let id: String
    let text: String
    let created_at: String
    let voice_slot: Int?
    let title: String?      // V1.1
    let content: String?    // V1.1
    let priority: String?   // V1.1
}
struct Feed: Decodable { let messages: [Notice]; let next_cursor: Int; let has_more: Bool }
struct HistoryItem: Codable, Identifiable {
    let id: String
    let text: String
    let timestamp: Date
    var result: String
    var voiceSlot: Int?
}

// 依据 Fish Audio 官方文档 2026-11 的模型清单；无「列出 TTS 模型」接口，故用探测判定可用性
struct FishModelOption: Identifiable {
    let id: String
    let name: String
    let note: String
    let isFree: Bool
    let isDeprecated: Bool
    static let candidates: [FishModelOption] = [
        FishModelOption(id:"s2.1-pro-free",name:"S2.1 Pro Free",note:"$0 免费 · 官方 Playground 标注免费至 2026-11-30 · 无 SLA",isFree:true,isDeprecated:false),
        FishModelOption(id:"s2.1-pro",name:"S2.1 Pro",note:"推荐生产模型 · 付费，需账户 API credit",isFree:false,isDeprecated:false),
        FishModelOption(id:"s2-pro",name:"S2 Pro",note:"上一代 · 旁白与多说话人 · 付费",isFree:false,isDeprecated:false),
        FishModelOption(id:"drama-3",name:"Drama 3",note:"自然语言指导表演 · 付费",isFree:false,isDeprecated:false),
        FishModelOption(id:"s1",name:"S1",note:"已弃用 · 2026-12-31 退役，不建议新用",isFree:false,isDeprecated:true)
    ]
}

@MainActor final class VoiceStore: ObservableObject {
    @Published var serverBase: String = {
        if let saved = UserDefaults.standard.string(forKey:"serverBase"), !saved.isEmpty { return saved }
        for key in ["endpoint","postEndpoint"] {
            if let old = UserDefaults.standard.string(forKey:key),
               let u = URL(string: old), let scheme = u.scheme, let host = u.host {
                UserDefaults.standard.removeObject(forKey:"endpoint")
                UserDefaults.standard.removeObject(forKey:"postEndpoint")
                return "\(scheme)://\(host)"
            }
        }
        return "https://notivoice.laomo.app"
    }()
    // API Token 存于 macOS Keychain（非 UserDefaults / 明文）；不内置默认值
    @Published var apiToken = Keychain.readAPI() ?? ""
    @Published var model = UserDefaults.standard.string(forKey:"model") ?? "s2.1-pro-free"
    @Published var detectedModels: [FishModelOption] = []
    @Published var detectingModels = false
    @Published var modelDetectStatus = ""
    @Published var voice = UserDefaults.standard.string(forKey:"voice") ?? ""
    @Published var voice2 = UserDefaults.standard.string(forKey:"voice2") ?? ""
    @Published var voice3 = UserDefaults.standard.string(forKey:"voice3") ?? ""
    @Published var defaultVoiceSlot = UserDefaults.standard.object(forKey:"defaultVoiceSlot") as? Int ?? 1
    @Published var cacheCount = 0
    @Published var fishKey = Keychain.read() ?? ""
    @Published var interval = max(3,UserDefaults.standard.integer(forKey:"interval") == 0 ? 5 : UserDefaults.standard.integer(forKey:"interval"))
    @Published var start = UserDefaults.standard.string(forKey:"start") ?? "08:30"
    @Published var end = UserDefaults.standard.string(forKey:"end") ?? "23:00"
    @Published var scheduleOn = UserDefaults.standard.object(forKey:"scheduleOn") as? Bool ?? true
    @Published var enabled = UserDefaults.standard.object(forKey:"enabled") as? Bool ?? true
    @Published var launchAtLogin = false
    @Published var status = "准备连接"
    @Published var saveFeedback = ""
    @Published var history: [HistoryItem] = []
    @Published var speaking = false
    @Published var volume: Double = UserDefaults.standard.object(forKey:"volume") as? Double ?? 0.8
    // 可靠性状态（V1.1）
    @Published var queuedCount = 0
    @Published var attentionCount = 0
    @Published var ackPending = 0
    @Published var lastSync: Date?
    @Published var bootstrapped: Bool = false
    // 启动自检状态机（V1.1 里程碑引入）：状态灯/文案以真实检查结果为准，不再看 enabled 开关脸色
    @Published var health: Health = .checking
    @Published var storageFaultDetail = ""
    enum Health {
        case checking, paused, offHours, unconfigured, invalidToken, unreachable, storageFault, playing, ok
    }
    var statusDot: Color {
        switch health {
        case .ok, .playing: return .green
        case .paused, .offHours: return .gray
        case .checking: return .yellow
        case .unconfigured: return .orange
        case .invalidToken, .unreachable, .storageFault: return .red
        }
    }
    var statusLine: String {
        switch health {
        case .checking: return "正在自检…"
        case .paused: return "语音通知助手 · 已暂停"
        case .offHours: return "语音通知助手 · 不在播报时间段"
        case .unconfigured: return "语音通知助手 · 待配置（未填 API Token 或服务器地址无效）"
        case .invalidToken: return "语音通知助手 · API Token 无效"
        case .unreachable: return "语音通知助手 · 无法连接服务器"
        case .storageFault: return "语音通知助手 · 本地数据库故障，可靠投递已暂停"
        case .playing: return "语音通知助手 · 播报中"
        case .ok: return "语音通知助手 · 运行中 · 已连接"
        }
    }

    // FIX-03：主库失败不再降级到临时库。db 为 nil 即存储故障，可靠处理全部暂停。
    private var db: Persistence?
    private var deviceId: String?
    private let dbPath: String
    private var timer: Timer?
    private var ackTimer: Timer?
    private var polling = false
    private var draining = false
    private var flushing = false
    private let cacheDir: URL
    private let diagURL: URL
    private let historyURL: URL

    private static func appSupportDir() -> URL {
        let dir = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NotiVoice",isDirectory:true)
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        return dir
    }

    init() {
        let dir = VoiceStore.appSupportDir()
        let dbURL = dir.appendingPathComponent("notivoice.sqlite")
        dbPath = dbURL.path
        cacheDir = dir.appendingPathComponent("audio-cache",isDirectory:true)
        diagURL = dir.appendingPathComponent("diagnostic.log")
        historyURL = dir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at:cacheDir,withIntermediateDirectories:true)
        // FIX-03：主库打开/迁移失败 → 进入存储故障态（红灯 + 可重连），不再创建临时库冒充正常。
        // 保留原文件，不重建不删除；修复前不拉取、不推进游标、不播报、不发 ACK。
        do {
            let p = try Persistence(path: dbURL.path)
            db = p
            deviceId = try p.ensureDeviceId()
            bootstrapped = ((try p.getState("bootstrapped")) ?? "") == "1"
            migrateHistoryJSON()
            loadHistoryFromDB()
            try p.recoverInterrupted()   // 崩溃恢复：playing → queued（T04）
        } catch {
            db = nil; deviceId = nil
            enterStorageFault("数据库打开/初始化失败", error)
        }
        // 旧版 apiToken 从 UserDefaults 迁移到 Keychain（一次性）
        if let old = UserDefaults.standard.string(forKey:"apiToken"), !old.isEmpty, Keychain.readAPI() == nil {
            Keychain.writeAPI(old); UserDefaults.standard.removeObject(forKey:"apiToken")
        }
        // 配置串行播放调度器
        configureCoordinator()
        if #available(macOS 13.0, *) { launchAtLogin = SMAppService.mainApp.status == .enabled }
        let savedModels = UserDefaults.standard.stringArray(forKey:"detectedModelIDs") ?? []
        detectedModels = FishModelOption.candidates.filter { savedModels.contains($0.id) }
        if !detectedModels.isEmpty { modelDetectStatus="以下是上次检测的缓存结果，点「检测可用模型」可用当前 Key 重新验证" }
        refreshCacheCount()
        Task { @MainActor in self.startIfNeeded() }
    }

    // FIX-03：存储故障统一入口（打开失败 / 关键写入失败都会进入）
    private func enterStorageFault(_ context: String, _ error: Error) {
        health = .storageFault
        storageFaultDetail = "\(context)：\(describe(error))"
        status = "本地数据库故障，可靠投递已暂停。修复后点「重新连接数据库」。"
    }

    private func describe(_ error: Error) -> String {
        if let nv = error as? NVError {
            switch nv {
            case .openFailed(let rc): return "打开失败 rc=\(rc)"
            case .execFailed(let m): return "SQL 执行失败：\(m)"
            case .prepareFailed(let rc, let m): return "prepare 失败 rc=\(rc)：\(m)"
            case .bindFailed(let rc, let m): return "bind 失败 rc=\(rc)：\(m)"
            case .stepFailed(let rc, let m): return "step 失败 rc=\(rc)：\(m)"
            case .unknownJob(let id): return "任务不存在 \(id)"
            case .notPlaying(let s): return "任务状态非法 \(s)"
            case .verifyFailed(let m): return "验证失败：\(m)"
            }
        }
        return error.localizedDescription
    }

    var storageOK: Bool { db != nil && health != .storageFault }

    /// FIX-03：「重新连接数据库」——重新打开原路径；成功后先恢复本地队列与 Outbox，再启动网络拉取。
    func retryStorage() {
        guard !storageOK || db == nil else { return }
        do {
            let p = try Persistence(path: dbPath)
            try p.healthProbe()
            db = p
            deviceId = try p.ensureDeviceId()
            bootstrapped = ((try p.getState("bootstrapped")) ?? "") == "1"
            loadHistoryFromDB()
            try p.recoverInterrupted()
            storageFaultDetail = ""
            health = .checking
            status = "数据库已重新连接，恢复本地队列…"
            Task { @MainActor in await self.updateReliability(); await self.poll() }
        } catch {
            enterStorageFault("重新连接数据库失败", error)
        }
    }

    private func migrateHistoryJSON() {
        guard let db = db else { return }
        guard let data = try? Data(contentsOf:historyURL),
              let old = try? JSONDecoder().decode([HistoryItem].self,from:data), !old.isEmpty else { return }
        for h in old {
            do { try db.insertHistory(id:h.id, messageId:h.id, action:"auto", engine:"migrated", result:h.result, text:h.text, at:h.timestamp.timeIntervalSince1970) }
            catch { enterStorageFault("历史迁移写入失败", error); return }
        }
        try? FileManager.default.removeItem(at:historyURL)
    }

    private func loadHistoryFromDB() {
        guard let db = db else { return }
        do {
            let rows = try db.recentHistory(limit:500)
            history = rows.compactMap { r -> HistoryItem? in
                guard let id = r["id"] as? String, let text = r["text"] as? String,
                      let res = r["result"] as? String, let ts = r["occurredAt"] as? TimeInterval else { return nil }
                return HistoryItem(id:id, text:text, timestamp: Date(timeIntervalSince1970:ts), result:res, voiceSlot:defaultVoiceSlot)
            }
        } catch { enterStorageFault("历史读取失败", error) }
    }

    func startIfNeeded() {
        guard timer == nil else { return }
        resetTimer()
    }

    // 规范化基地址
    private func normalizedBase() -> String? {
        let b = serverBase.trimmingCharacters(in:.whitespacesAndNewlines)
        let full = (b.hasPrefix("http://") || b.hasPrefix("https://")) ? b : "https://"+b
        guard let c = URLComponents(string:full), c.scheme == "https", c.host != nil else { return nil }
        return full
    }

    func refreshCacheCount() {
        let files=(try? FileManager.default.contentsOfDirectory(at:cacheDir,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? []
        cacheCount=files.filter{$0.pathExtension=="mp3"}.count
    }

    private func trimCache(limit:Int=100) {
        let fm=FileManager.default
        let files=((try? fm.contentsOfDirectory(at:cacheDir,includingPropertiesForKeys:[.contentModificationDateKey],options:.skipsHiddenFiles)) ?? []).filter{$0.pathExtension=="mp3"}
        if files.count>limit {
            let dated=files.map{($0,(try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast)}
            for (f,_) in dated.sorted(by:{$0.1<$1.1}).prefix(files.count-limit) {try? fm.removeItem(at:f)}
        }
        cacheCount=min(files.count,limit)
    }

    func clearCache() {
        let files=(try? FileManager.default.contentsOfDirectory(at:cacheDir,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? []
        for f in files where f.pathExtension=="mp3" {try? FileManager.default.removeItem(at:f)}
        cacheCount=0; status="语音缓存已清除"
    }

    // 配置串行播放调度器：在此快照当前值（在 @MainActor 上），以普通闭包注入，避免调度器串行队列访问隔离状态
    private func configureCoordinator() {
        let v1 = UserDefaults.standard.string(forKey:"voice") ?? ""
        let v2 = UserDefaults.standard.string(forKey:"voice2") ?? ""
        let v3 = UserDefaults.standard.string(forKey:"voice3") ?? ""
        let dirPath = cacheDir.path
        let modelID = model
        let key = fishKey
        let vol = Float(volume)
        AudioCoordinator.shared.configure(volume: vol, fishKey: key, model: modelID,
            resolveVoiceID: { slot in
                let all=[v1,v2,v3].map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
                let idx=min(max(slot,1),3)-1
                return all[idx].isEmpty ? all[0] : all[idx]
            },
            cacheFile: { t,m,v in
                let digest=SHA256.hash(data:Data("\(m)|\(v)|\(t)".utf8))
                return URL(fileURLWithPath:dirPath).appendingPathComponent(digest.map{String(format:"%02x",$0)}.joined()+".mp3")
            },
            cacheDirPath: dirPath, trimLimit: 100)
    }

    func save() {
        for (k,v) in ["serverBase":serverBase,"model":model,"voice":voice,"voice2":voice2,"voice3":voice3,"start":start,"end":end] {UserDefaults.standard.set(v,forKey:k)}
        UserDefaults.standard.set(min(max(defaultVoiceSlot,1),3),forKey:"defaultVoiceSlot")
        UserDefaults.standard.set(max(3,interval),forKey:"interval")
        UserDefaults.standard.set(scheduleOn,forKey:"scheduleOn")
        UserDefaults.standard.set(enabled,forKey:"enabled")
        UserDefaults.standard.set(volume,forKey:"volume")
        Keychain.writeAPI(apiToken.trimmingCharacters(in:.whitespacesAndNewlines))  // Token 入钥匙串
        Keychain.write(fishKey.trimmingCharacters(in:.whitespacesAndNewlines))
        configureCoordinator()
        if #available(macOS 13.0, *) {
            do { if launchAtLogin {try SMAppService.mainApp.register()} else {try SMAppService.mainApp.unregister()} }
            catch {status="开机启动设置失败：\(error.localizedDescription)"}
        }
        resetTimer()
        saveFeedback = "设置已保存 ✓"
        Task { try? await Task.sleep(nanoseconds:3_000_000_000); if saveFeedback == "设置已保存 ✓" { saveFeedback = "" } }
    }

    func resetTimer() {
        timer?.invalidate()
        timer=Timer.scheduledTimer(withTimeInterval:TimeInterval(max(3,interval)),repeats:true){[weak self] _ in Task { @MainActor in await self?.poll() }}
        Task { await poll() }
        // ACK 重试定时器（T05：网络恢复后持续补发）
        ackTimer?.invalidate()
        ackTimer=Timer.scheduledTimer(withTimeInterval:5,repeats:true){[weak self] _ in Task { @MainActor in await self?.flushAcks() }}
        Task { await flushAcks() }
    }

    func toggle() {enabled.toggle();UserDefaults.standard.set(enabled,forKey:"enabled");if enabled {health = .checking;Task {await poll()}} else {health = .paused;status="已暂停"}}

    private func inHours() -> Bool {
        guard scheduleOn else {return true}
        var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(identifier:"Asia/Shanghai")!
        let c=cal.dateComponents([.hour,.minute],from:Date());let now=(c.hour ?? 0)*60+(c.minute ?? 0)
        func minutes(_ s:String)->Int? {let a=s.split(separator:":").compactMap{Int($0)};guard a.count==2,(0...23).contains(a[0]),(0...59).contains(a[1]) else{return nil};return a[0]*60+a[1]}
        guard let a=minutes(start),let b=minutes(end) else{return false}
        if a==b{return true};return a<b ? now>=a && now<b : now>=a || now<b
    }

    // MARK: - 拉取（与本地落库同一事务；GET 不写服务端 fetched_at）
    func poll() async {
        guard !polling else{return}
        if health == .storageFault { return }          // FIX-03：存储故障期间不拉取、不推进游标
        guard let db = db, let devId = deviceId else { health = .storageFault; status = "本地数据库不可用"; return }
        if !enabled {health = .paused;status="已暂停";return}
        if !inHours() {health = .offHours;status="不在播报时间内";return}
        if apiToken.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {health = .unconfigured;status="请先在通用设置中填写 API Token";return}
        guard let base = normalizedBase(), var components = URLComponents(string: base), components.scheme == "https" else { health = .unconfigured; status = "服务器地址无效，须为 HTTPS 域名（如 https://notivoice.laomo.app）"; return }
        components.path="/api/notifications"
        polling=true;defer{polling=false}
        do {
            var cursor = try db.readCursor()          // FIX-01：游标读取失败即存储故障，不得静默归零重拉
            for _ in 0..<40 {
                components.queryItems=[URLQueryItem(name:"after",value:String(cursor)),URLQueryItem(name:"limit",value:"50")]
                guard let url=components.url else {throw URLError(.badURL)}
                var req=URLRequest(url:url);req.timeoutInterval=12
                req.setValue("Bearer \(apiToken.trimmingCharacters(in:.whitespacesAndNewlines))",forHTTPHeaderField:"Authorization")
                let (data,response)=try await URLSession.shared.data(for:req)
                let code=(response as? HTTPURLResponse)?.statusCode ?? 0
                guard code==200 else {
                    if code == 401 { health = .invalidToken; status = "API Token 无效（HTTP 401），请在通用设置中更新" }
                    throw URLError(.badServerResponse)
                }
                let feed=try JSONDecoder().decode(Feed.self,from:data)
                if !bootstrapped {
                    // 首次同步只建立基线，不播放历史；分页推进 cursor（FIX-01：写入 checked，失败上抛）
                    cursor=feed.next_cursor
                    try db.setCursor(cursor)
                    if !feed.has_more || feed.messages.isEmpty {
                        bootstrapped=true
                        try db.setState("bootstrapped","1")
                        status="首次同步完成（不播放历史）";break
                    }
                    continue
                }
                if feed.messages.isEmpty {break}
                let msgs = feed.messages.map { m -> IncomingMessage in
                    let t = m.text.isEmpty ? (m.content ?? m.title ?? "") : m.text
                    return IncomingMessage(seq:m.seq, id:m.id, title:m.title ?? m.text, content:m.content ?? m.text,
                                          text:t, priority:m.priority ?? "normal", voiceSlot:min(max(m.voice_slot ?? defaultVoiceSlot,1),3), createdAt:m.created_at)
                }
                let acks = msgs.map { (messageId:$0.id, status:"received", eventId:UUID().uuidString) }
                // 同一事务：入库 + 建待播任务 + 推进 cursor + 建 received 回执（T03：崩溃可恢复）
                _ = try db.storePageAndAcks(msgs, newCursor: feed.next_cursor, acks: acks, deviceId: devId)
                cursor = feed.next_cursor
                lastSync = Date()
                if !feed.has_more {break}
            }
            if bootstrapped { Task { await drain() }; Task { await flushAcks() } }
            await updateReliability()
            if health != .storageFault { health = .ok }
            if health != .playing { status = queuedCount > 0 ? "已连接 · 待播 \(queuedCount) 条" : "已连接 · 暂无待播消息" }
        }catch{
            if let nv = error as? NVError {
                enterStorageFault("拉取过程持久化失败", nv)   // FIX-01/03：存储错误不得伪装成网络错误
                return
            }
            if health != .invalidToken && health != .storageFault { health = .unreachable }
            if !status.hasPrefix("API Token 无效") {status="连接失败：\(error.localizedDescription)"}
        }
    }

    // MARK: - 自动播放（串行调度器；失败指数退避不丢弃；超阈值转 needs_attention）
    private func drain() async {
        guard !draining else{return};draining=true;defer{draining=false}
        guard let db = db, let devId = deviceId else { return }   // FIX-03：存储故障期间不播报
        while enabled && inHours() && health != .storageFault {
            let jobsList: [PlaybackJob]
            do { jobsList = try db.dueJobs() }
            catch { enterStorageFault("任务读取失败", error); return }
            guard let first = jobsList.first else { break }
            let slot=min(max(first.voiceSlot,1),3)
            do { try db.markPlaying(first.messageId) }
            catch { enterStorageFault("标记播放中失败", error); return }
            health = .playing
            status="正在播报：\(first.text.prefix(20))"
            let ok=await AudioCoordinator.shared.speak(text: first.text,slot:slot)
            if ok {
                // FIX-02：completed 与 played 回执同一事务，同生同灭；eventId 持久化于 Outbox，重试复用原 ID
                do { _ = try db.completeAndEnqueuePlayed(first.messageId, deviceId: devId) }
                catch { enterStorageFault("播放完成落库失败", error); return }
                addHistory(id:first.messageId,text:first.text,result:"已播放 · 音色 #\(slot)",voiceSlot:slot,engine:"fish/system")
                await flushAcks()
            } else {
                do { try db.markFailed(first.messageId, error:"Fish 与系统 TTS 均失败", threshold:3) }
                catch { enterStorageFault("失败标记落库失败", error); return }
                addHistory(id:first.messageId,text:first.text,result:"播放失败",voiceSlot:slot,engine:"none")
                status="有消息播放失败，可在记录中重播"
            }
        }
        await updateReliability()
        if health == .playing { health = .ok }
    }

    // MARK: - ACK Outbox 重试（T05：失败持续重试，不改变本地已播放事实）
    func flushAcks() async {
        guard !flushing else {return};flushing=true;defer{flushing=false}
        guard let db = db else { return }                          // FIX-03：存储故障期间不发 ACK
        let rows: [AckRow]
        do { rows = try db.undeliveredAcks() }
        catch { enterStorageFault("ACK Outbox 读取失败", error); return }
        for row in rows {
            let ok=await postReceipt(row)
            do {
                if ok { try db.markAckDelivered(row.eventId) }
                else { try db.bumpAckAttempt(row.eventId, nextRetryAt: Date().timeIntervalSince1970 + 15) }
            } catch { enterStorageFault("ACK 状态更新失败", error); return }
        }
        await updateReliability()
    }

    private func postReceipt(_ row: AckRow) async -> Bool {
        guard let base=normalizedBase(), var comps=URLComponents(string:base), comps.scheme=="https" else {return false}
        comps.path="/api/notifications/ack"
        guard let url=comps.url else {return false}
        var req=URLRequest(url:url);req.httpMethod="POST";req.timeoutInterval=10
        req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        req.setValue("Bearer \(apiToken.trimmingCharacters(in:.whitespacesAndNewlines))",forHTTPHeaderField:"Authorization")
        req.httpBody=try? JSONSerialization.data(withJSONObject:["device_id":row.deviceId,"message_id":row.messageId,"status":row.status,"event_id":row.eventId])
        guard let (_,res)=try? await URLSession.shared.data(for:req) else {return false}
        let code=(res as? HTTPURLResponse)?.statusCode ?? 0
        return code==200 || code==409 || code==404   // 409/404：服务端已判定冲突或消息不存在，视为终态，不再重试
    }

    func retryAttentionAll() {
        guard let db = db else { return }
        do {
            for j in try db.needAttentionJobs() { try db.retryAttention(j.messageId) }
        } catch { enterStorageFault("人工重试落库失败", error); return }
        Task { await drain() }
    }

    private func updateReliability() async {
        guard let db = db else { return }
        // UI 计数为展示性读取：失败保持上一拍数值（控制流读取已在 poll/drain/flushAcks 中严格校验）
        let q=(try? db.dueJobs().count) ?? queuedCount
        let a=(try? db.needAttentionJobs().count) ?? attentionCount
        let ack=(try? db.pendingAckCount()) ?? ackPending
        queuedCount=q; attentionCount=a; ackPending=ack
    }

    // MARK: - 手动重播 / 测试语音（同样走串行调度器，T11 不互相抢占）
    func replay(_ h:HistoryItem) {
        Task { let slot=min(max(h.voiceSlot ?? defaultVoiceSlot,1),3);let ok=await AudioCoordinator.shared.speak(text: h.text,slot:slot);status=ok ? "重播完成 · 音色 #\(slot)" : "重播失败" }
    }
    func testVoice() {
        Task { let ok=await AudioCoordinator.shared.speak(text: "Noti Voice 语音测试，您有一条新的提醒。",slot:defaultVoiceSlot);if !ok {status="语音测试失败"} else if !status.hasPrefix("Fish Audio 失败") {status="语音测试完成 · 音色 #\(defaultVoiceSlot)"} }
    }

    func addHistory(id:String,text:String,result:String,voiceSlot:Int?=nil,engine:String) {
        let item=HistoryItem(id:id,text:text,timestamp:Date(),result:result,voiceSlot:voiceSlot)
        history.insert(item,at:0)
        if history.count>500 {history=Array(history.prefix(500))}
        // FIX-01：历史写入 checked。历史属审计信息：失败不中断投递，但必须暴露而不是吞掉。
        guard let db = db else { return }
        do { try db.insertHistory(id:id, messageId:id, action:"auto", engine:engine, result:result, text:text) }
        catch {
            appendDiag("历史写入失败：\(describe(error))")
            if !status.hasPrefix("本地数据库故障") { status = "已播放，但历史记录写入失败（详见诊断日志）" }
        }
    }

    private func appendDiag(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = FileHandle(forWritingAtPath: diagURL.path) { h.seekToEndOfFile(); h.write(stamped.data(using:.utf8)!); try? h.close() }
        else { try? stamped.data(using:.utf8)?.write(to: diagURL) }
    }

    func clearHistory() {
        history=[]; status="已播放记录已清空"
        // 仅清空内存与展示；持久化播放历史保留（审计）
    }

    // MARK: - Fish 模型探测
    func detectModels() async {
        guard !detectingModels else {return}
        let key = fishKey.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty else {modelDetectStatus="请先填入 Fish Audio API Key";return}
        guard let url = URL(string:"https://api.fish.audio/v1/tts") else {return}
        detectingModels = true;defer{detectingModels=false}
        detectedModels = []
        modelDetectStatus = "正在逐个探测候选模型…"
        var available: [FishModelOption] = []
        var blocked = 0
        for option in FishModelOption.candidates {
            var req = URLRequest(url:url)
            req.httpMethod = "POST";req.timeoutInterval = 15
            req.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
            req.setValue("application/json",forHTTPHeaderField:"Content-Type")
            req.setValue(option.id,forHTTPHeaderField:"model")
            req.httpBody = try? JSONSerialization.data(withJSONObject:["text":"测试","format":"mp3"])
            do {
                let (_,response) = try await URLSession.shared.data(for:req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {available.append(option)}
                else if code == 401 {modelDetectStatus="API Key 无效（401），请检查密钥";detectedModels=[];return}
                else {blocked += 1}
            } catch {modelDetectStatus="检测中断：\(error.localizedDescription)";return}
        }
        detectedModels = available
        UserDefaults.standard.set(available.map{$0.id},forKey:"detectedModelIDs")
        Keychain.write(key)
        modelDetectStatus = available.isEmpty
            ? "未检测到可用模型（付费模型无 API credit 时返回 402）"
            : "检测到 \(available.count) 个可用模型，另 \(blocked) 个不可用；点击可填入，计费以官方账单为准"
    }

    private func logDiagnostic(_ line:String) {
        let prev=(try? String(contentsOf:diagURL,encoding:.utf8)) ?? ""
        let next=String((prev + "\(Date()) \(line)\n").suffix(20000))
        try? next.write(to:diagURL,atomically:true,encoding:.utf8)
    }
}

// MARK: - Keychain（双 service：Fish 语音 Key / API Token，均不进明文）
enum Keychain {
    static let fishService="cn.lemoai.notivoice.fish"
    static let apiService="cn.lemoai.notivoice.api"
    static func read()->String? { read(service:fishService) }
    static func write(_ s:String) { write(service:fishService, s) }
    static func readAPI()->String? { read(service:apiService) }
    static func writeAPI(_ s:String) { write(service:apiService, s) }
    private static func read(service:String)->String? {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var out:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&out)==errSecSuccess,let data=out as? Data else{return nil};return String(data:data,encoding:.utf8)
    }
    private static func write(service:String,_ s:String) {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service]
        SecItemDelete(q as CFDictionary)
        if !s.isEmpty {var a=q;a[kSecValueData as String]=Data(s.utf8);SecItemAdd(a as CFDictionary,nil)}
    }
}

// MARK: - UI
struct MenuPanel:View {
    @ObservedObject var store:VoiceStore
    @Environment(\.openWindow) private var openWindow
    @State private var showClearConfirm = false
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"waveform.circle.fill").font(.system(size:34)).foregroundStyle(.blue)
                VStack(alignment:.leading,spacing:2){Text("Noti Voice").font(.headline);HStack(spacing:5){Circle().fill(store.statusDot).frame(width:7,height:7);Text(store.statusLine).font(.caption).foregroundStyle(.secondary)}}
                Spacer()
                Button {NSApp.activate(ignoringOtherApps:true);openWindow(id:"settings")} label:{Image(systemName:"gearshape").font(.system(size:18))}.buttonStyle(.plain).help("打开设置")
            }.padding(16)
            if store.health == .storageFault {
                VStack(alignment:.leading,spacing:6) {
                    Text("本地数据库故障，可靠投递已暂停（不拉取、不播报、不发回执）").font(.caption).bold().foregroundStyle(.red)
                    Text(store.storageFaultDetail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    Button("重新连接数据库") { store.retryStorage() }.font(.caption).controlSize(.small)
                }.padding(.horizontal,16).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                Divider()
            }
            Divider()
            HStack(spacing:8) {Text("已播放记录").font(.subheadline).bold();Spacer();if showClearConfirm {Button("取消"){showClearConfirm=false}.font(.caption).foregroundStyle(.secondary);Button{store.clearHistory();showClearConfirm=false}label:{Text("确认清空").font(.caption).bold()}.foregroundStyle(.red)}else{Button("清空记录"){showClearConfirm=true}.font(.caption).foregroundStyle(.secondary)};Text("\(store.history.filter{Calendar.current.isDateInToday($0.timestamp)}.count) 条（今日）").font(.caption).foregroundStyle(.secondary)}.padding(.horizontal,16).padding(.vertical,10)
            ScrollView {
                LazyVStack(spacing:0) {
                    if store.history.isEmpty {VStack(spacing:8){Image(systemName:"waveform").font(.system(size:28)).foregroundStyle(.secondary);Text("暂无播放记录").font(.subheadline).foregroundStyle(.secondary);Text("首次同步只建立基线，新消息会自动播报").font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity).padding(.vertical,36)}
                    ForEach(store.history) { h in
                        HStack(alignment:.top,spacing:10) {
                            Button {store.replay(h)} label:{Image(systemName:"play.circle.fill").font(.system(size:25)).foregroundStyle(.blue)}.buttonStyle(.plain).help("重播")
                            VStack(alignment:.leading,spacing:4){Text(h.text).font(.subheadline).lineLimit(2);Text(h.result).font(.caption2).foregroundStyle(h.result.hasPrefix("已播放") ? Color.green : (h.result.contains("失败") ? Color.orange : Color.secondary))}
                            Spacer(minLength:4)
                            Text(h.timestamp,style:.time).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.horizontal,16).padding(.vertical,11)
                        Divider().padding(.leading,48)
                    }
                }
            }.frame(height:200)
            Divider()
            // 可靠性状态（V1.1）
            HStack(spacing:6) {
                ReliChip(label:"待播", value:store.queuedCount, color:.blue)
                ReliChip(label:"失败待处理", value:store.attentionCount, color:.orange)
                ReliChip(label:"ACK待发", value:store.ackPending, color:.purple)
                if let ls=store.lastSync { Text("最近同步 \(ls,style:.time)").font(.caption2).foregroundStyle(.secondary) }
                if store.attentionCount>0 { Button("重试"){store.retryAttentionAll()}.font(.caption).foregroundStyle(.orange) }
            }.padding(.horizontal,16).padding(.vertical,8)
            Divider()
            Text(store.status).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal,16).padding(.vertical,9)
            Divider()
            HStack {
                Button {store.toggle()} label:{Label(store.enabled ? "暂停播报" : "恢复播报",systemImage:store.enabled ? "pause.circle" : "play.circle")}
                Spacer()
                Button("立即检查") {Task {await store.poll()}}
            }.buttonStyle(.borderless).padding(.horizontal,16).padding(.vertical,12)
            Divider()
            Button {NSApp.terminate(nil)} label:{Label("退出 Noti Voice",systemImage:"power")}.buttonStyle(.borderless).padding(13)
        }.frame(width:380)
    }
}

struct ReliChip: View {
    let label:String; let value:Int; let color:Color
    var body: some View {
        HStack(spacing:3){ Text(label).font(.caption2); Text("\(value)").font(.caption2.bold()).foregroundStyle(value>0 ? color : .secondary) }
            .padding(.horizontal,7).padding(.vertical,3).background(color.opacity(value>0 ? 0.12 : 0.05)).cornerRadius(7)
    }
}

struct SettingsWindow:View {
    @ObservedObject var store:VoiceStore
    @State private var tab="general"
    @State private var copiedVersion=false
    // 版本与构建标识一律从 Info.plist 读取（由 mac/build-app.command 注入），禁止在 UI 里写死
    private var appVersion:String {
        Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown"
    }
    private var buildStamp:String {
        let d=Bundle.main.infoDictionary ?? [:]
        let b=d["CFBundleVersion"] as? String ?? "?"
        let c=d["NVGitCommit"] as? String ?? "dev"
        let t=d["NVBuildTime"] as? String ?? "-"
        let v=d["NVBuildVariant"] as? String ?? "-"
        let dirty=(d["NVGitDirty"] as? String=="yes") ? " · 含未提交改动" : ""
        return "V\(appVersion) · build \(b) · 标识 \(c) · \(v) · \(t)\(dirty)"
    }
    var body:some View {
        NavigationSplitView {
            List(selection:$tab) {
                Label("通用设置",systemImage:"gearshape").tag("general")
                Label("语音设置",systemImage:"waveform").tag("voice")
                Label("运行时间",systemImage:"clock").tag("schedule")
                Label("关于",systemImage:"info.circle").tag("about")
            }.navigationTitle("Noti Voice").listStyle(.sidebar).frame(minWidth:170)
        } detail: {
            VStack(alignment:.leading,spacing:18) {
                Text(["general":"通用设置","voice":"语音设置","schedule":"运行时间","about":"关于"][tab] ?? "设置").font(.title2).bold()
                Divider()
                if tab=="general" {
                    VStack(alignment:.leading,spacing:7){Text("服务器地址");TextField("https://notivoice.laomo.app",text:$store.serverBase).textFieldStyle(.roundedBorder)}
                    Text("接口路径由程序自动拼接（GET/POST 用 /api/notifications，回执用 /api/notifications/ack），只需填写域名。").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment:.leading,spacing:7){Text("API Token（Bearer，读取 / 提交 / 回执；保存在 macOS 钥匙串）");SecureField("输入 API Token",text:$store.apiToken).textFieldStyle(.roundedBorder)}
                    HStack {Text("轮询间隔");Spacer();Picker("",selection:$store.interval){ForEach([3,5,10,15,30,60],id:\.self){Text("\($0) 秒").tag($0)}}.frame(width:145)}
                    Toggle("开机自动启动",isOn:$store.launchAtLogin)
                    Text("API Token 与 ADMIN_TOKEN 分离：后台管理使用独立的 ADMIN_TOKEN，不会发到 Mac 客户端。所有接口必须带 API Token，否则 401。首次连接只同步历史消息。API 必须使用 HTTPS。").font(.caption).foregroundStyle(.secondary)
                } else if tab=="voice" {
                    VStack(alignment:.leading,spacing:7){Text("Fish Audio API Key");SecureField("输入 API Key",text:$store.fishKey).textFieldStyle(.roundedBorder)}
                    HStack(spacing:10) {
                        Button {Task {await store.detectModels()}} label:{Label("检测可用模型",systemImage:"magnifyingglass")}
                            .disabled(store.detectingModels || store.fishKey.isEmpty)
                        if store.detectingModels {ProgressView().scaleEffect(0.7)}
                        Text(store.modelDetectStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    VStack(alignment:.leading,spacing:5) {
                        Text("模型列表（点击填入 · 绿色「免费」表示无费用）").font(.caption).bold()
                        ForEach(FishModelOption.candidates) { option in
                            Button {store.model=option.id} label:{
                                HStack(spacing:7) {
                                    Image(systemName:store.model==option.id ? "checkmark.circle.fill" : "circle").foregroundStyle(.blue)
                                    Text(option.id).font(.system(size:11,design:.monospaced))
                                    if option.isFree {Text("免费").font(.caption2).bold().foregroundStyle(.green)}
                                    if option.isDeprecated {Text("已弃用").font(.caption2).foregroundStyle(.orange)}
                                    if !store.detectedModels.isEmpty {
                                        if store.detectedModels.contains(where:{$0.id==option.id}) {Text("可用").font(.caption2).foregroundStyle(.green)}
                                        else if !option.isDeprecated {Text("当前 Key 不可用").font(.caption2).foregroundStyle(.secondary)}
                                    }
                                    Text(option.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength:0)
                                }
                            }.buttonStyle(.plain).help(option.note)
                        }
                        Text("点「检测可用模型」用当前 Key 验证可用性；即便显示「不可用」也可手动选择（付费模型需账户有 credit，实际费用以官方账单为准）。").font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack(alignment:.leading,spacing:7){Text("模型（Model）");TextField("s2.1-pro-free",text:$store.model).textFieldStyle(.roundedBorder)}
                    HStack(spacing:6){Text("免费模型").font(.caption).bold().foregroundStyle(.green);Text("s2.1-pro-free").font(.system(size:11,design:.monospaced));Text("$0 · 官方 Playground 标注免费至 2026-11-30 · 无 SLA，实际以官方账单为准").font(.caption2).foregroundStyle(.secondary)}
                    VStack(alignment:.leading,spacing:6) {
                        Text("音色槽位（Reference ID）").font(.subheadline).bold()
                        HStack(spacing:8){Text("#1").font(.system(size:12,design:.monospaced)).foregroundStyle(.blue).frame(width:26);TextField("默认音色",text:$store.voice).textFieldStyle(.roundedBorder)}
                        HStack(spacing:8){Text("#2").font(.system(size:12,design:.monospaced)).frame(width:26);TextField("留空则回退 #1",text:$store.voice2).textFieldStyle(.roundedBorder)}
                        HStack(spacing:8){Text("#3").font(.system(size:12,design:.monospaced)).frame(width:26);TextField("留空则回退 #1",text:$store.voice3).textFieldStyle(.roundedBorder)}
                        HStack {Text("默认音色");Picker("",selection:$store.defaultVoiceSlot){Text("#1").tag(1);Text("#2").tag(2);Text("#3").tag(3)}.frame(width:110)}
                        Text("POST 时加 \"voice\":2 或 \"voice\":\"#2\" 即可指定音色；不传用默认 #1。").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing:10){Text("语音缓存：\(store.cacheCount) / 100 条（重播命中缓存不再调用 API）").font(.caption);Button("清除缓存"){store.clearCache()}.font(.caption);Spacer()}
                    HStack {Text("音量");Slider(value:$store.volume,in:0...1);Text("\(Int(store.volume*100))%")}
                    Button {store.testVoice()} label:{Label("测试语音",systemImage:"play.fill")}
                    if store.status.hasPrefix("Fish Audio 失败") {
                        Text("状态：\(store.status)").font(.caption).foregroundStyle(.orange).lineLimit(3)
                    } else {
                        Text("状态：\(store.status)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("缓存按「文本 + 模型 + 音色」分别保存，最多 100 条，超出按最旧淘汰；换模型或音色会自动重新生成。检测会向每个候选模型发送 2 个字的测试请求；账户若有付费额度，探测付费模型可能产生极小费用，实际以官方账单为准。未设置 Key 或 Fish Audio 不可用时，使用 macOS 系统语音兜底。").font(.caption).foregroundStyle(.secondary)
                } else if tab=="schedule" {
                    Toggle("启用运行时间限制",isOn:$store.scheduleOn)
                    Text("时区：北京时间（Asia/Shanghai）").foregroundStyle(.secondary)
                    HStack {Text("开始时间");Spacer();TextField("08:30",text:$store.start).frame(width:100).textFieldStyle(.roundedBorder)}
                    HStack {Text("结束时间");Spacer();TextField("23:00",text:$store.end).frame(width:100).textFieldStyle(.roundedBorder)}
                    Text("运行时间之外不拉取消息；恢复运行后会继续补拉。支持跨午夜时间段，格式 HH:mm。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Noti Voice V\(appVersion) · 可靠消息播报",systemImage:"waveform.circle.fill").font(.headline)
                    VStack(alignment:.leading,spacing:6) {
                        Text(buildStamp).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        HStack(spacing:10) {
                            Button("复制版本信息") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(buildStamp,forType:.string)
                                copiedVersion=true
                            }.font(.caption)
                            if copiedVersion {Text("已复制，可直接贴给开发者").font(.caption2).foregroundStyle(.green)}
                            Text("以本页为准确认实际运行的版本").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("macOS 13+ · Apple Silicon · SwiftUI")
                    Text("Cloudflare Worker + D1 · Fish Audio · 本地 SQLite 持久化")
                    Text("本软件是未签名源码构建测试版，不保证电脑休眠、系统静音时发声。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack {Spacer();if !store.saveFeedback.isEmpty{Text(store.saveFeedback).font(.caption).foregroundStyle(.green)};Button("保存设置") {store.save()}.buttonStyle(.borderedProminent)}
            }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        }.frame(minWidth:720,minHeight:520)
    }
}

@main struct NotiVoiceApp:App {
    @StateObject private var store=VoiceStore()
    var body:some Scene {
        MenuBarExtra("Noti Voice",systemImage:"waveform") {MenuPanel(store:store).task {store.startIfNeeded()}}.menuBarExtraStyle(.window)
        Window("Noti Voice 设置",id:"settings") {SettingsWindow(store:store).task {store.startIfNeeded()}}
            .defaultSize(width:760,height:550)
    }
}
