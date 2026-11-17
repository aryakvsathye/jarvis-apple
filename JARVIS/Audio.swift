import AVFoundation
import Foundation

/// The phone's audio: one session for listening and speaking. Answers play through AirPods when they're in.
enum AudioSession {
    static func start() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default,
                          options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        try s.setActive(true)
    }

    static func microphoneAllowed() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

/// Records what he says to a file (AAC, 16 kHz mono, which JARVIS's ears read directly), and reports how loud the
/// room is, so a request can end itself after a pause.
final class Recorder {
    private var recorder: AVAudioRecorder?
    private(set) var file: URL?

    func start() throws {
        stop()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("said-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw ClientError.status(0, "The microphone wouldn't start.") }
        recorder = r
        file = url
    }

    /// Loudness from 0 (silence) to 1, like the web page's level.
    var level: Double {
        guard let r = recorder else { return 0 }
        r.updateMeters()
        let db = Double(r.averagePower(forChannel: 0))   // -160 (silence) to 0 (loudest)
        return max(0, min(1, pow(10, db / 20) * 4))
    }

    var seconds: Double { recorder?.currentTime ?? 0 }

    /// Stops and hands back what was recorded.
    @discardableResult
    func stop() -> Data? {
        guard let r = recorder else { return nil }
        r.stop()
        recorder = nil
        defer { if let f = file { try? FileManager.default.removeItem(at: f) }; file = nil }
        guard let f = file else { return nil }
        return try? Data(contentsOf: f)
    }
}

/// Speaks JARVIS's sentences in order, as they arrive (each is a short WAV made on the Mac).
final class Speaker: NSObject, AVAudioPlayerDelegate {
    private var queue: [Data] = []
    private var player: AVAudioPlayer?
    var onIdle: (() -> Void)?
    var isSpeaking: Bool { player != nil || !queue.isEmpty }

    func add(_ wav: Data) {
        queue.append(wav)
        if player == nil { next() }
    }

    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
    }

    private func next() {
        guard !queue.isEmpty else { player = nil; onIdle?(); return }
        let wav = queue.removeFirst()
        guard let p = try? AVAudioPlayer(data: wav) else { next(); return }
        p.delegate = self
        player = p
        p.play()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.next() }
    }
}
