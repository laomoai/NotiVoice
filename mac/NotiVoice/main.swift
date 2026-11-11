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
    let voice_slot: Int?   // 服务端指定音色槽位 #1/#2/#3，旧消息为 nil
}
struct Feed: Decodable { let messages: [Notice]; let next_cursor: Int; let has_more: Bool }
struct HistoryItem: Codable, Identifiable {
    let id: String
    let text: String
    let timestamp: Date
    var result: String
    var voiceSlot: Int?    // Optional，兼容早期没有该字段的 history.json
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
    // 主入口：自定义域名 notivoice.laomo.app（workers.dev 作为备用，可在设置页改回）
    @Published var endpoint = UserDefaults.standard.string(forKey:"endpoint") ?? "https://notivoice.laomo.app/api/notifications"
    @Published var postEndpoint = UserDefaults.standard.string(forKey:"postEndpoint") ?? "https://notivoice.laomo.app/api/notifications"
    // 所有 /api/* 共用的 Bearer Token（与 Worker 的 API_TOKEN secret 一致，非机密）
    @Published var apiToken = UserDefaults.standard.string(forKey:"apiToken") ?? "6c8db15bf637cd0815f6551a54d18178015395912666cdd8"
    // 默认选官方免费模型，避免误用付费模型产生账单
    @Published var model = UserDefaults.standard.string(forKey:"model") ?? "s2.1-pro-free"
    @Published var detectedModels: [FishModelOption] = []
    @Published var detectingModels = false
    @Published var modelDetectStatus = ""
    @Published var voice = UserDefaults.standard.string(forKey:"voice") ?? ""      // 音色 #1（默认）
    @Published var voice2 = UserDefaults.standard.string(forKey:"voice2") ?? ""    // 音色 #2
    @Published var voice3 = UserDefaults.standard.string(forKey:"voice3") ?? ""    // 音色 #3
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
    @Published var history: [HistoryItem] = []
    @Published var speaking = false
    @Published var volume: Double = UserDefaults.standard.object(forKey:"volume") as? Double ?? 0.8
    private var cursor = UserDefaults.standard.integer(forKey:"cursor")
    private var bootstrapped = UserDefaults.standard.bool(forKey:"bootstrapped")
    private var timer: Timer?
    private var polling = false
    private var pending: [Notice] = []
    private var pendingIDs = Set<String>()
    private var playingIDs = Set<String>()
    private var draining = false
    private var player: AVAudioPlayer?
    private let synthesizer = NSSpeechSynthesizer()
    private var didStart = false
    private var retryCount: [String:Int] = [:]
    private let historyURL: URL = {
        let dir=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NotiVoice",isDirectory:true)
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        return dir.appendingPathComponent("history.json")
    }()
    private let diagURL: URL = {
        let dir=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NotiVoice",isDirectory:true)
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        return dir.appendingPathComponent("diagnostic.log")
    }()
    private let cacheDir: URL = {
        let dir=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NotiVoice/audio-cache",isDirectory:true)
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        return dir
    }()
    private func logDiagnostic(_ line:String) {
        let prev=(try? String(contentsOf:diagURL,encoding:.utf8)) ?? ""
        let next=String((prev + "\(Date()) \(line)\n").suffix(20000))
        try? next.write(to:diagURL,atomically:true,encoding:.utf8)
    }
    // 缓存键含 文本 + 模型 + 实际音色 ID，任一变化都会自动 miss，不会串音色
    private func cacheFile(text:String,model:String,voiceID:String)->URL {
        let digest=SHA256.hash(data:Data("\(model)|\(voiceID)|\(text)".utf8))
        return cacheDir.appendingPathComponent(digest.map{String(format:"%02x",$0)}.joined()+".mp3")
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
        cacheCount=0
        status="语音缓存已清除"
    }
    // 目标槽位没配 ID 时回退 #1；#1 也为空则不传 reference_id，用模型默认音色
    func resolvedVoiceID(slot:Int)->String {
        let all=[voice,voice2,voice3].map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
        let idx=min(max(slot,1),3)-1
        return all[idx].isEmpty ? all[0] : all[idx]
    }
    init() {
        if let d=try? Data(contentsOf:historyURL), let h=try? JSONDecoder().decode([HistoryItem].self,from:d) { history=h }
        if #available(macOS 13.0, *) { launchAtLogin = SMAppService.mainApp.status == .enabled }
        let savedModels = UserDefaults.standard.stringArray(forKey:"detectedModelIDs") ?? []
        detectedModels = FishModelOption.candidates.filter { savedModels.contains($0.id) }
        if !detectedModels.isEmpty {modelDetectStatus="以下是上次检测的缓存结果，点「检测可用模型」可用当前 Key 重新验证"}
        refreshCacheCount()
        // 菜单栏弹窗未展开时 .task 不会触发，需在启动时主动开启轮询
        Task { @MainActor in self.startIfNeeded() }
    }
    func startIfNeeded() { guard !didStart else{return};didStart=true;resetTimer() }
    // 用当前输入的 Key 逐个探测官方候选模型：200 可用 / 401 Key 无效 / 402 无付费额度 / 429 限流
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
        Keychain.write(key)  // 探测成功说明该 Key 有效，避免 Keychain 里残留无效旧值
        modelDetectStatus = available.isEmpty
            ? "未检测到可用模型（付费模型无 API credit 时返回 402）"
            : "检测到 \(available.count) 个可用模型，另 \(blocked) 个不可用；点击可填入，计费以官方账单为准"
    }
    func save() {
        for (k,v) in ["endpoint":endpoint,"postEndpoint":postEndpoint,"apiToken":apiToken,"model":model,"voice":voice,"voice2":voice2,"voice3":voice3,"start":start,"end":end] {UserDefaults.standard.set(v,forKey:k)}
        UserDefaults.standard.set(min(max(defaultVoiceSlot,1),3),forKey:"defaultVoiceSlot")
        UserDefaults.standard.set(max(3,interval),forKey:"interval")
        UserDefaults.standard.set(scheduleOn,forKey:"scheduleOn")
        UserDefaults.standard.set(enabled,forKey:"enabled")
        UserDefaults.standard.set(volume,forKey:"volume")
        Keychain.write(fishKey.trimmingCharacters(in:.whitespacesAndNewlines))
        if #available(macOS 13.0, *) {
            do { if launchAtLogin {try SMAppService.mainApp.register()} else {try SMAppService.mainApp.unregister()} }
            catch {status="开机启动设置失败：\(error.localizedDescription)"}
        }
        resetTimer()
    }
    func resetTimer() {
        timer?.invalidate()
        timer=Timer.scheduledTimer(withTimeInterval:TimeInterval(max(3,interval)),repeats:true){[weak self] _ in Task { @MainActor in await self?.poll() }}
        Task { await poll() }
    }
    func toggle() {enabled.toggle();UserDefaults.standard.set(enabled,forKey:"enabled");if enabled {Task {await poll()}} else {status="已暂停"}}
    private func inHours() -> Bool {
        guard scheduleOn else {return true}
        var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(identifier:"Asia/Shanghai")!
        let c=cal.dateComponents([.hour,.minute],from:Date());let now=(c.hour ?? 0)*60+(c.minute ?? 0)
        func minutes(_ s:String)->Int? {let a=s.split(separator:":").compactMap{Int($0)};guard a.count==2,(0...23).contains(a[0]),(0...59).contains(a[1]) else{return nil};return a[0]*60+a[1]}
        guard let a=minutes(start),let b=minutes(end) else{return false}
        if a==b{return true};return a<b ? now>=a && now<b : now>=a || now<b
    }
    func poll() async {
        guard !polling else{return};guard enabled else{status="已暂停";return}
        guard inHours() else{status="不在播报时间内";return}
        guard var components=URLComponents(string:endpoint),components.scheme=="https" else {status="读取地址必须为 HTTPS";return}
        polling=true;defer{polling=false}
        var fetched=0
        do {
            for _ in 0..<20 {
                components.queryItems=(components.queryItems ?? []).filter{!(["after","limit"].contains($0.name))} + [URLQueryItem(name:"after",value:String(cursor)),URLQueryItem(name:"limit",value:"50")]
                guard let url=components.url else {throw URLError(.badURL)}
                var req=URLRequest(url:url);req.timeoutInterval=12
                req.setValue("Bearer \(apiToken.trimmingCharacters(in:.whitespacesAndNewlines))",forHTTPHeaderField:"Authorization")
                let (data,response)=try await URLSession.shared.data(for:req)
                let code=(response as? HTTPURLResponse)?.statusCode ?? 0
                guard code==200 else {
                    if code==401 {status="API Token 无效（HTTP 401），请在通用设置中更新"}
                    throw URLError(.badServerResponse)
                }
                let feed=try JSONDecoder().decode(Feed.self,from:data)
                if !bootstrapped {
                    // First run starts from latest existing message; paginate without playing historical items.
                    cursor=feed.next_cursor;UserDefaults.standard.set(cursor,forKey:"cursor")
                    if !feed.has_more || feed.messages.isEmpty {bootstrapped=true;UserDefaults.standard.set(true,forKey:"bootstrapped");status="首次同步完成（不播放历史）";return}
                    continue
                }
                for notice in feed.messages where !pendingIDs.contains(notice.id) && !playingIDs.contains(notice.id) {
                    pending.append(notice);pendingIDs.insert(notice.id);fetched+=1
                }
                cursor=feed.next_cursor;UserDefaults.standard.set(cursor,forKey:"cursor")
                if !feed.has_more || feed.messages.isEmpty {break}
            }
            if bootstrapped && !pending.isEmpty {Task {await drain()}}
            if fetched==0 && !speaking {status="已同步 · 无新消息"}
        }catch{if !status.hasPrefix("API Token 无效") {status="连接失败：\(error.localizedDescription)"}}
    }
    private func drain() async {
        guard !draining else{return};draining=true;defer{draining=false}
        while enabled && inHours() && !pending.isEmpty {
            let n=pending.removeFirst();pendingIDs.remove(n.id);playingIDs.insert(n.id)
            let slot=min(max(n.voice_slot ?? defaultVoiceSlot,1),3)
            let ok=await speak(n.text,slot:slot)
            playingIDs.remove(n.id)
            if ok {addHistory(id:n.id,text:n.text,result:"已播放 · 音色 #\(slot)",voiceSlot:slot);retryCount.removeValue(forKey:n.id);await ack([n.seq])}
            else {
                let attempts=(retryCount[n.id] ?? 0)+1;retryCount[n.id]=attempts
                if attempts<3 {pending.insert(n,at:0);pendingIDs.insert(n.id);try? await Task.sleep(nanoseconds:2_000_000_000)}
                else {addHistory(id:n.id,text:n.text,result:"播放失败",voiceSlot:slot);status="有消息播放失败，可在记录中重播"}
            }
        }
    }
    // 播报成功后把 seq 回执给 Worker，后台才能区分「已被取走」与「已播报」
    private func ack(_ seqs:[Int]) async {
        guard var comps=URLComponents(string:endpoint),comps.scheme=="https" else{return}
        comps.path=(comps.path as NSString).deletingLastPathComponent + "/ack"
        comps.queryItems=nil
        guard let url=comps.url else{return}
        var req=URLRequest(url:url);req.httpMethod="POST";req.timeoutInterval=10
        req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        req.setValue("Bearer \(apiToken.trimmingCharacters(in:.whitespacesAndNewlines))",forHTTPHeaderField:"Authorization")
        req.httpBody=try? JSONSerialization.data(withJSONObject:["seqs":seqs])
        guard let (_,res)=try? await URLSession.shared.data(for:req),
              (res as? HTTPURLResponse)?.statusCode==200 else {
            logDiagnostic("ack 失败 seqs=\(seqs)")
            return
        }
    }
    func replay(_ h:HistoryItem) {Task {let slot=min(max(h.voiceSlot ?? defaultVoiceSlot,1),3);let ok=await speak(h.text,slot:slot);status=ok ? "重播完成 · 音色 #\(slot)" : "重播失败"}}
    func testVoice() {Task {let ok=await speak("Noti Voice 语音测试，您有一条新的 BTC 提醒。",slot:defaultVoiceSlot);if !ok {status="语音测试失败"} else if !status.hasPrefix("Fish Audio 失败") {status="语音测试完成 · 音色 #\(defaultVoiceSlot)"}}}
    private func addHistory(id:String,text:String,result:String,voiceSlot:Int?=nil) {
        history.insert(HistoryItem(id:id,text:text,timestamp:Date(),result:result,voiceSlot:voiceSlot),at:0)
        if history.count>500 {history=Array(history.prefix(500))}
        if let data=try? JSONEncoder().encode(history) {try? data.write(to:historyURL,options:.atomic)}
    }
    private func playFile(_ url:URL,label:String) async -> Bool {
        guard let p=try? AVAudioPlayer(contentsOf:url) else{return false}
        player=p;p.volume=Float(volume);p.prepareToPlay()
        guard p.play() else{return false}
        status=label
        while p.isPlaying {try? await Task.sleep(nanoseconds:150_000_000)}
        return true
    }
    // 网络层瞬时错误（TLS 握手失败 / 连接重置 / 超时）自动重试一次；HTTP 4xx/5xx 不重试
    private func fetchTTS(_ req:URLRequest) async throws -> (Data,URLResponse) {
        do {return try await URLSession.shared.data(for:req)}
        catch {
            status="网络异常，正在重试…（\(error.localizedDescription)）"
            logDiagnostic("tts 网络重试 -> \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds:900_000_000)
            return try await URLSession.shared.data(for:req)
        }
    }
    // 每个「文本+模型+音色」组合只生成一次；命中缓存直接播放，不再请求 Fish Audio
    private func speak(_ text:String,slot:Int?=nil) async -> Bool {
        speaking=true;status="正在生成语音…";defer{speaking=false}
        let key=fishKey.trimmingCharacters(in:.whitespacesAndNewlines)
        let modelID=model.trimmingCharacters(in:.whitespacesAndNewlines)
        let useSlot=min(max(slot ?? defaultVoiceSlot,1),3)
        let voiceID=resolvedVoiceID(slot:useSlot)
        let cache=cacheFile(text:text,model:modelID,voiceID:voiceID)
        if !key.isEmpty,FileManager.default.fileExists(atPath:cache.path) {
            if await playFile(cache,label:"正在播放缓存音频 · 音色 #\(useSlot)") {return true}
            try? FileManager.default.removeItem(at:cache)  // 缓存损坏则重新生成
            refreshCacheCount()
        }
        if !key.isEmpty {
            do {
                var req=URLRequest(url:URL(string:"https://api.fish.audio/v1/tts")!);req.httpMethod="POST";req.timeoutInterval=45
                req.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
                req.setValue("application/json",forHTTPHeaderField:"Content-Type")
                req.setValue(modelID,forHTTPHeaderField:"model")
                var body:[String:Any]=["text":text,"format":"mp3"]
                if !voiceID.isEmpty {body["reference_id"]=voiceID}
                req.httpBody=try JSONSerialization.data(withJSONObject:body)
                let (data,res)=try await fetchTTS(req)
                let code=(res as? HTTPURLResponse)?.statusCode ?? 0
                guard code==200 else {
                    let detail=String(decoding:data.prefix(300),as:UTF8.self)
                    throw NSError(domain:"fish",code:code,userInfo:[NSLocalizedDescriptionKey:"HTTP \(code) · \(detail)"])
                }
                // AVAudioPlayer(data:) 对 mp3 常识别失败，落盘后用 contentsOf: 播放
                try data.write(to:cache)
                trimCache(limit:100)
                guard await playFile(cache,label:"正在播放…") else {throw NSError(domain:"audio",code:2,userInfo:[NSLocalizedDescriptionKey:"AVAudioPlayer 无法开始播放"])}
                return true
            } catch {
                let reason=error.localizedDescription
                let isNetwork=(error as NSError).domain==NSURLErrorDomain
                status=isNetwork
                    ? "Fish Audio 网络失败：\(reason)（已重试 1 次，改用系统语音；请检查代理/VPN 后重试）"
                    : "Fish Audio 失败：\(reason)（已改用系统语音）"
                logDiagnostic("speak model=\(modelID) voice=\(voiceID) slot=\(useSlot) network=\(isNetwork) -> \(reason)")
            }
        }
        synthesizer.volume=Float(volume)
        let started=synthesizer.startSpeaking(text)
        guard started else {status="系统语音也无法启动";return false}
        while synthesizer.isSpeaking {try? await Task.sleep(nanoseconds:150_000_000)}
        return true
    }
}

enum Keychain {
    static let service="cn.lemoai.notivoice.fish"
    static func read()->String? {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var out:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&out)==errSecSuccess,let data=out as? Data else{return nil};return String(data:data,encoding:.utf8)
    }
    static func write(_ s:String) {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service]
        SecItemDelete(q as CFDictionary)
        if !s.isEmpty {var a=q;a[kSecValueData as String]=Data(s.utf8);SecItemAdd(a as CFDictionary,nil)}
    }
}

struct MenuPanel:View {
    @ObservedObject var store:VoiceStore
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"waveform.circle.fill").font(.system(size:34)).foregroundStyle(.blue)
                VStack(alignment:.leading,spacing:2){Text("Noti Voice").font(.headline);HStack(spacing:5){Circle().fill(store.enabled ? Color.green : .gray).frame(width:7,height:7);Text(store.enabled ? "语音通知助手 · 运行中" : "语音通知助手 · 已暂停").font(.caption).foregroundStyle(.secondary)}}
                Spacer()
                Button {NSApp.activate(ignoringOtherApps:true);openWindow(id:"settings")} label:{Image(systemName:"gearshape").font(.system(size:18))}.buttonStyle(.plain).help("打开设置")
            }.padding(16)
            Divider()
            HStack {Text("已播放记录").font(.subheadline).bold();Spacer();Text("\(store.history.filter{Calendar.current.isDateInToday($0.timestamp)}.count) 条（今日）").font(.caption).foregroundStyle(.secondary)}.padding(.horizontal,16).padding(.vertical,10)
            ScrollView {
                LazyVStack(spacing:0) {
                    // macOS 13 兼容：ContentUnavailableView 仅 macOS 14+ 可用
                    if store.history.isEmpty {VStack(spacing:8){Image(systemName:"waveform").font(.system(size:28)).foregroundStyle(.secondary);Text("暂无播放记录").font(.subheadline).foregroundStyle(.secondary);Text("首次同步只建立基线，新消息会自动播报").font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity).padding(.vertical,36)}
                    ForEach(store.history) { h in
                        HStack(alignment:.top,spacing:10) {
                            Button {store.replay(h)} label:{Image(systemName:"play.circle.fill").font(.system(size:25)).foregroundStyle(.blue)}.buttonStyle(.plain).help("重播")
                            VStack(alignment:.leading,spacing:4){Text(h.text).font(.subheadline).lineLimit(2);Text(h.result).font(.caption2).foregroundStyle(h.result=="已播放" ? Color.secondary : Color.red)}
                            Spacer(minLength:4)
                            Text(h.timestamp,style:.time).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.horizontal,16).padding(.vertical,11)
                        Divider().padding(.leading,48)
                    }
                }
            }.frame(height:240)
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

struct SettingsWindow:View {
    @ObservedObject var store:VoiceStore
    @State private var tab="general"
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
                    VStack(alignment:.leading,spacing:7){Text("消息读取地址（GET）");TextField("https://notivoice.laomo.app/api/notifications",text:$store.endpoint).textFieldStyle(.roundedBorder)}
                    VStack(alignment:.leading,spacing:7){Text("消息提交地址（仅用于发送测试）");TextField("https://notivoice.laomo.app/api/notifications",text:$store.postEndpoint).textFieldStyle(.roundedBorder)}
                    VStack(alignment:.leading,spacing:7){Text("API Token（Bearer，读取 / 提交 / 回执共用）");TextField("输入 API Token",text:$store.apiToken).textFieldStyle(.roundedBorder)}
                    HStack {Text("轮询间隔");Spacer();Picker("",selection:$store.interval){ForEach([3,5,10,15,30,60],id:\.self){Text("\($0) 秒").tag($0)}}.frame(width:145)}
                    Toggle("开机自动启动",isOn:$store.launchAtLogin)
                    Text("所有接口必须带同一个 API Token，否则返回 HTTP 401。首次连接只同步历史消息，不会朗读旧消息。API 必须使用 HTTPS。").font(.caption).foregroundStyle(.secondary)
                } else if tab=="voice" {
                    VStack(alignment:.leading,spacing:7){Text("Fish Audio API Key");SecureField("输入 API Key",text:$store.fishKey).textFieldStyle(.roundedBorder)}
                    HStack(spacing:10) {
                        Button {Task {await store.detectModels()}} label:{Label("检测可用模型",systemImage:"magnifyingglass")}
                            .disabled(store.detectingModels || store.fishKey.isEmpty)
                        if store.detectingModels {ProgressView().scaleEffect(0.7)}
                        Text(store.modelDetectStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !store.detectedModels.isEmpty {
                        VStack(alignment:.leading,spacing:5) {
                            Text("检测结果（点击填入模型）").font(.caption).bold()
                            ForEach(store.detectedModels) { option in
                                Button {store.model=option.id} label:{
                                    HStack(spacing:7) {
                                        Image(systemName:store.model==option.id ? "checkmark.circle.fill" : "circle").foregroundStyle(.blue)
                                        Text(option.id).font(.system(size:11,design:.monospaced))
                                        if option.isFree {Text("免费").font(.caption2).bold().foregroundStyle(.green)}
                                        if option.isDeprecated {Text("已弃用").font(.caption2).foregroundStyle(.orange)}
                                        Text(option.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        Spacer(minLength:0)
                                    }
                                }.buttonStyle(.plain).help(option.note)
                            }
                        }
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
                        Text("状态：\(store.status)").font(.caption).foregroundStyle(.red).lineLimit(3)
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
                    Label("Noti Voice V1.0 · 测试版",systemImage:"waveform.circle.fill").font(.headline)
                    Text("macOS 13+ · Apple Silicon · SwiftUI")
                    Text("Cloudflare Worker + D1 · Fish Audio · 本地播放记录")
                    Text("本软件是未签名源码构建测试版，不保证电脑休眠、系统静音时发声。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack {Spacer();Button("保存设置") {store.save()}.buttonStyle(.borderedProminent)}
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
