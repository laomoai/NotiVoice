import Foundation
import AVFoundation
import AppKit

// NotiVoice V1.1 串行播放调度器
// 唯一串行队列，持有单一 AVAudioPlayer / NSSpeechSynthesizer 实例；
// 自动播报、手动重播、测试语音统一经 speak() 入队，互不抢占同一音频对象。
// 播放完成以 delegate 回调为准（非轮询 isPlaying）——满足 T04 验收要求。

final class AudioCoordinator: NSObject {
    static let shared = AudioCoordinator()

    private let playQueue = DispatchQueue(label: "cn.lemoai.notivoice.audio")
    private var filePlayer: AVAudioPlayer?
    private let synthesizer = NSSpeechSynthesizer()

    private var fileCont: CheckedContinuation<Bool, Never>?
    private var speechCont: CheckedContinuation<Bool, Never>?

    // 配置（由 VoiceStore 注入，speak 时快照，避免跨线程访问隔离状态）
    private var volume: Float = 0.8
    private var fishKey = ""
    private var model = "s2.1-pro-free"
    private var resolveVoiceID: ((Int) -> String)?
    private var cacheFile: ((String, String, String) -> URL)?
    private var cacheDirPath: String = ""
    private var trimLimit: Int = 100

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func configure(volume: Float, fishKey: String, model: String,
                   resolveVoiceID: @escaping (Int) -> String,
                   cacheFile: @escaping (String, String, String) -> URL,
                   cacheDirPath: String, trimLimit: Int = 100) {
        self.volume = volume
        self.fishKey = fishKey
        self.model = model
        self.resolveVoiceID = resolveVoiceID
        self.cacheFile = cacheFile
        self.cacheDirPath = cacheDirPath
        self.trimLimit = trimLimit
    }

    /// 统一串行播放入口：返回 true 表示已播放完成（含系统 TTS 兜底），false 表示彻底失败。
    func speak(text: String, slot: Int) async -> Bool {
        let snapVolume = volume
        let snapKey = fishKey
        let snapModel = model
        let snapResolve = resolveVoiceID
        let snapCache = cacheFile
        let snapDir = cacheDirPath
        let snapLimit = trimLimit
        return await withCheckedContinuation { cont in
            playQueue.async { [weak self] in
                self?._run(text: text, slot: slot, volume: snapVolume, key: snapKey, model: snapModel,
                           resolve: snapResolve, cache: snapCache, dir: snapDir, limit: snapLimit, cont: cont)
            }
        }
    }

    private func _run(text: String, slot: Int, volume: Float, key: String, model: String,
                      resolve: ((Int) -> String)?, cache: ((String, String, String) -> URL)?,
                      dir: String, limit: Int, cont: CheckedContinuation<Bool, Never>) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceID = resolve?(slot) ?? ""

        // 1) 命中缓存或请求 Fish Audio 生成 MP3（串行队列内同步等待，保证不并发占用播放对象）
        var fileURL: URL?
        if !k.isEmpty, let cache, let url = cache(text, modelID, voiceID) as URL? {
            if FileManager.default.fileExists(atPath: url.path) {
                fileURL = url
            } else if let data = requestFish(text: text, model: modelID, voice: voiceID, key: k) {
                try? data.write(to: url)
                trimCacheDir(dir, limit: limit)
                fileURL = url
            }
        }

        if let url = fileURL {
            playFile(url, volume: volume, cont: cont)
            return
        }
        // 2) 系统 TTS 兜底
        speakSystem(text, volume: volume, cont: cont)
    }

    private func trimCacheDir(_ dir: String, limit: Int) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: dir)
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles).filter({ $0.pathExtension == "mp3" }),
              files.count > limit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast) }
        for (f, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) { try? fm.removeItem(at: f) }
    }

    private func requestFish(text: String, model: String, voice: String, key: String) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        var req = URLRequest(url: URL(string: "https://api.fish.audio/v1/tts")!)
        req.httpMethod = "POST"; req.timeoutInterval = 45
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(model, forHTTPHeaderField: "model")
        var body: [String: Any] = ["text": text, "format": "mp3"]
        if !voice.isEmpty { body["reference_id"] = voice }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let data, let r = resp as? HTTPURLResponse, r.statusCode == 200 else { return }
            result = data
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 60)
        return result
    }

    private func playFile(_ url: URL, volume: Float, cont: CheckedContinuation<Bool, Never>) {
        guard let p = try? AVAudioPlayer(contentsOf: url) else { cont.resume(returning: false); return }
        filePlayer = p; p.volume = volume; p.delegate = self
        fileCont = cont
        guard p.play() else { fileCont = nil; filePlayer = nil; cont.resume(returning: false); return }
    }

    private func speakSystem(_ text: String, volume: Float, cont: CheckedContinuation<Bool, Never>) {
        synthesizer.volume = volume
        speechCont = cont
        if !synthesizer.startSpeaking(text) {
            speechCont = nil
            cont.resume(returning: false)
        }
    }
}

extension AudioCoordinator: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let c = fileCont; fileCont = nil; filePlayer = nil
        c?.resume(returning: flag)
    }
}

extension AudioCoordinator: NSSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finished: Bool) {
        let c = speechCont; speechCont = nil
        c?.resume(returning: finished)
    }
}
