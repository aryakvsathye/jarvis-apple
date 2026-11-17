import AVFoundation
import Foundation
import Speech

/// The phone's microphone and speaker for a conversation, through one audio engine with iOS's voice processing
/// (as FaceTime uses): echo cancellation, so the microphone doesn't hear JARVIS's own voice and Aryak can cut in.
/// What he says is kept as 16 kHz mono 16-bit samples, which JARVIS's ears on the Mac read directly (as a WAV).
final class Engine {
    static let shared = Engine()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let keepFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var inConverter: AVAudioConverter?
    private let lock = NSLock()
    private var preroll: [Int16] = []          // the last moment before he started, so his first syllable isn't lost
    private var captured: [Int16] = []
    private var capturing = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var generation = 0                 // bumped when speech is cut off, so old "finished" calls are ignored
    private(set) var running = false

    /// Loudness of each moment, from 0 to 1 (on the audio thread).
    var onLevel: ((Double) -> Void)?
    /// When the last queued sentence has finished playing (on the main thread).
    var onIdle: (() -> Void)?
    private(set) var queued = 0                // sentences scheduled and not yet played (main thread)
    var isSpeaking: Bool { queued > 0 }

    static let prerollSamples = 16000 * 6 / 10

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        if !engine.attachedNodes.contains(player) { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        let format = input.outputFormat(forBus: 0)
        inConverter = AVAudioConverter(from: format, to: keepFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in self?.feed(buffer) }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    func stop() {
        guard running else { return }
        stopSpeaking()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        lock.withLock { capturing = false; captured = []; preroll = []; request = nil }
        running = false
    }

    // ---------------------------------------------------------------- listening
    private func feed(_ buffer: AVAudioPCMBuffer) {
        var sum: Float = 0
        if let ch = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        }
        let rms = buffer.frameLength > 0 ? sqrt(sum / Float(buffer.frameLength)) : 0
        let samples = convert(buffer)
        lock.withLock {
            request?.append(buffer)
            if capturing {
                captured += samples
            } else {
                preroll += samples
                if preroll.count > Engine.prerollSamples { preroll.removeFirst(preroll.count - Engine.prerollSamples) }
            }
        }
        onLevel?(min(1, Double(rms) * 8))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let c = inConverter else { return [] }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * keepFormat.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: keepFormat, frameCapacity: cap) else { return [] }
        var given = false
        var error: NSError?
        c.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let p = out.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
    }

    /// From now, keep what he says (starting with the moment before), and give it to the transcriber too.
    func beginCapture(transcribing r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { captured = preroll; preroll = []; capturing = true; request = r }
    }

    /// Stop keeping, and hand back what he said as a WAV.
    func endCapture() -> Data {
        let samples: [Int16] = lock.withLock {
            let s = captured
            capturing = false; captured = []; request = nil
            return s
        }
        return Engine.wav(samples, rate: 16000)
    }

    func discardCapture() {
        lock.withLock { capturing = false; captured = []; request = nil }
    }

    static func wav(_ samples: [Int16], rate: Int) -> Data {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes).littleEndian)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian); put(UInt16(1).littleEndian)
        put(UInt16(1).littleEndian); put(UInt32(rate).littleEndian); put(UInt32(rate * 2).littleEndian)
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        d.append(contentsOf: Array("data".utf8)); put(UInt32(bytes).littleEndian)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    // ---------------------------------------------------------------- speaking
    /// Queue one of JARVIS's sentences (a WAV from the Mac). Main thread.
    func play(_ wav: Data) {
        guard running, let buffer = Engine.decode(wav, to: playFormat) else { return }
        queued += 1
        let gen = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.queued = max(0, self.queued - 1)
                if self.queued == 0 { self.onIdle?() }
            }
        }
        if !player.isPlaying { player.play() }
    }

    /// Cut JARVIS off (he started talking). Main thread.
    func stopSpeaking() {
        generation += 1
        queued = 0
        player.stop()
        if running { player.play() }
    }

    static func decode(_ wav: Data, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? wav.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url),
              let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: raw)) != nil else { return nil }
        if raw.format == format { return raw }
        guard let c = AVAudioConverter(from: raw.format, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(raw.frameLength) * format.sampleRate / raw.format.sampleRate) + 1024)
        else { return nil }
        var given = false
        var error: NSError?
        c.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true; status.pointee = .haveData; return raw
        }
        return error == nil ? out : nil
    }
}

/// His words as he says them, recognised on the phone itself (never sent to Apple), only to judge when he's finished:
/// what JARVIS answers comes from the recording, heard on the Mac.
@MainActor
final class Transcriber {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var task: SFSpeechRecognitionTask?
    private(set) var text = ""
    private(set) var available = false

    func authorise() async {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        available = status == .authorized && (recognizer?.supportsOnDeviceRecognition ?? false)
    }

    /// A new request for one turn, or nil when on-phone recognition isn't available (then pauses alone decide).
    func begin() -> SFSpeechAudioBufferRecognitionRequest? {
        finish()
        text = ""
        guard available, let recognizer else { return nil }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.requiresOnDeviceRecognition = true
        r.shouldReportPartialResults = true
        r.addsPunctuation = true
        task = recognizer.recognitionTask(with: r) { [weak self] result, _ in
            guard let words = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in self?.text = words }
        }
        return r
    }

    func finish() {
        task?.cancel()
        task = nil
    }

    /// How long a pause means he's finished, from what he's said so far: a sentence that sounds complete ends
    /// quickly; one that trails off on "and", "the", "um" gets longer.
    static func pauseNeeded(after said: String, hearing: Bool) -> TimeInterval {
        guard hearing else { return 1.4 }   // no words to judge by: a steady middle
        let t = said.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty { return 1.6 }
        let last = t.split(separator: " ").last.map { String($0).trimmingCharacters(in: .punctuationCharacters) } ?? ""
        let hanging: Set<String> = ["and", "but", "so", "or", "um", "uh", "er", "erm", "the", "a", "an", "to", "of",
                                    "because", "like", "with", "for", "if", "then", "is", "my", "your", "what", "which",
                                    "that", "in", "on", "at", "about", "how", "can", "could", "should", "would", "jarvis"]
        if hanging.contains(last) { return 2.6 }
        if t.hasSuffix("?") || t.hasSuffix(".") || t.hasSuffix("!") { return 0.8 }
        return 1.2
    }
}
