import Foundation
import SwiftUI

/// A line in the conversation on screen.
struct Line: Identifiable {
    enum Who { case him, jarvis, note }
    let id = UUID()
    let who: Who
    var text: String
    var tool: String = ""
    var timing: String = ""
}

/// The conversation, and listening: works like the web page. Tap once and JARVIS listens; a pause of 10 seconds
/// ends a request; it answers, then listens again; tap to end. JARVIS on the Mac checks the voice, so another
/// voice gets "Unauthorised access detected" and no answer.
@MainActor
final class Talk: ObservableObject {
    enum Phase { case idle, listening, thinking, speaking }

    @Published var phase: Phase = .idle
    @Published var lines: [Line] = []
    @Published var hint = "Tap to talk"
    @Published var level: Double = 0
    @Published var mustTeach = false
    @Published var deviceName = "iPhone"

    var session = false
    private let recorder = Recorder()
    private let speaker = Speaker()
    private var timer: Timer?
    private var spoke = false
    private var lastSpeech = Date()
    private var lastHeard = Date()
    private var startedAt = Date()
    private var noise: Double = 0

    static let silenceEnd: TimeInterval = 10            // his chosen pause that ends a request
    static let sessionIdle: TimeInterval = 15 * 60      // a session with nothing said ends itself
    static let speakLevel = 0.05

    init() {
        speaker.onIdle = { [weak self] in Task { @MainActor in self?.answered() } }
    }

    // ---------------------------------------------------------------- listening
    func toggle() {
        if session { endSession() } else { Task { await startSession() } }
    }

    func startSession() async {
        guard !session else { return }
        guard await AudioSession.microphoneAllowed() else {
            hint = "JARVIS needs the microphone: Settings → JARVIS → Microphone."
            return
        }
        do { try await AudioSession.start() } catch { hint = error.localizedDescription; return }
        session = true
        lastHeard = Date()
        listen()
    }

    func endSession() {
        session = false
        timer?.invalidate(); timer = nil
        if spoke, let audio = recorder.stop() { Task { await hear(audio) } } else { recorder.stop() }
        spoke = false
        if phase == .listening { phase = .idle; hint = "Tap to talk" }
    }

    private func listen() {
        guard session else { return }
        do { try recorder.start() } catch { hint = error.localizedDescription; endSession(); return }
        phase = .listening
        hint = "Listening. Tap to end."
        spoke = false
        startedAt = Date(); lastSpeech = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Twenty times a second: is he talking, compared with the room? The room's level follows it quickly when it
    /// gets quieter and slowly when it gets louder, so a steady TV becomes the floor.
    private func tick() {
        guard session, phase == .listening else { return }
        let lv = recorder.level
        level = lv
        noise = noise == 0 ? lv : (lv < noise ? noise * 0.9 + lv * 0.1 : noise * 0.998 + lv * 0.002)
        let now = Date()
        if lv > max(Talk.speakLevel, noise * 2.5) { spoke = true; lastSpeech = now; lastHeard = now }
        if spoke && now.timeIntervalSince(lastSpeech) > Talk.silenceEnd {
            timer?.invalidate(); timer = nil
            if let audio = recorder.stop() { Task { await hear(audio) } }
        } else if !spoke && now.timeIntervalSince(startedAt) > 30 {
            try? recorder.start(); startedAt = now   // nothing said: a fresh recording, so it stays small
        }
        if !spoke && now.timeIntervalSince(lastHeard) > Talk.sessionIdle { endSession() }
    }

    // ---------------------------------------------------------------- hearing and asking
    private func hear(_ audio: Data) async {
        phase = .thinking; hint = "Listening back…"; level = 0
        do {
            let (status, j) = try await Client.call("api/hear", method: "POST", body: audio, type: "audio/mp4")
            if status == 409, j["teach"] as? Bool == true {
                deviceName = j["device_name"] as? String ?? "iPhone"
                mustTeach = true
                endSession(); phase = .idle; hint = "Teach JARVIS your voice to talk here."
                return
            }
            if status == 401 { endSession(); phase = .idle; hint = "This app isn't paired any more. Pair it again."; return }
            if j["rejected"] as? Bool == true {
                let match = (j["score"] as? Double).map { String(format: " Match %.2f.", $0) } ?? ""
                hint = (j["message"] as? String ?? "Unauthorised access detected.") + match
                answered(); return
            }
            guard let text = j["text"] as? String, !text.isEmpty else {
                hint = status == 200 ? "Didn't catch that." : (j["error"] as? String ?? "JARVIS couldn't hear that.")
                answered(); return
            }
            await ask(text)
        } catch {
            hint = error.localizedDescription; answered()
        }
    }

    func ask(_ text: String) async {
        lines.append(Line(who: .him, text: text))
        var reply = Line(who: .jarvis, text: "")
        lines.append(reply)
        let index = lines.count - 1
        phase = .thinking; hint = "Thinking…"
        // where he is goes with every question; one about where he is (or the weather here) gets a fresh position
        let fresh = Location.needed(for: text)
        if fresh { hint = "Checking where you are…" }
        let fix = await Location.shared.now(fresh: fresh ? 600 : 3600, wait: fresh ? 8 : 2)
        let position: (lat: Double, lon: Double)?? = .some(fix.map { (lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) })
        hint = "Thinking…"
        let sent = Date()
        var firstWord: TimeInterval?
        do {
            for try await ev in Client.ask(text, where: position) {
                if let tool = ev["tool"] as? String {
                    reply.tool = Talk.toolLabel(tool); lines[index] = reply
                }
                if let t = ev["text"] as? String {
                    if firstWord == nil { firstWord = Date().timeIntervalSince(sent) }
                    reply.text += t; lines[index] = reply
                }
                if let b64 = ev["say"] as? String, let wav = Data(base64Encoded: b64) {
                    phase = .speaking; hint = "Speaking…"
                    speaker.add(wav)
                }
                if let e = ev["error"] as? String { reply.text += (reply.text.isEmpty ? "" : " ") + e; lines[index] = reply }
            }
        } catch {
            reply.text = error.localizedDescription; lines[index] = reply
        }
        if let f = firstWord { reply.timing = String(format: "first word %.1f s", f); lines[index] = reply }
        if !speaker.isSpeaking { answered() }
    }

    /// After an answer (or nothing to answer): listen again if the session is on.
    private func answered() {
        guard !speaker.isSpeaking else { return }
        if session { listen() } else { phase = .idle; if hint == "Speaking…" || hint == "Thinking…" { hint = "Tap to talk" } }
    }

    static func toolLabel(_ name: String) -> String {
        let acts = ["restart_project": "restart a project", "update_project": "update a project",
                    "roll_back_project": "roll back a project", "check_for_updates": "check for updates",
                    "change_setting": "change a setting"]
        if let a = acts[name] { return "Asked the Command Centre to " + a }
        return "Checked " + (["server_status": "the server", "current_time": "the time"][name] ?? name.replacingOccurrences(of: "_", with: " "))
    }

    // ---------------------------------------------------------------- teaching his voice on this phone
    static let phrases = ["JARVIS, how's the server?", "JARVIS, what's the time?", "JARVIS, is Portfolio running?",
                          "Good morning, JARVIS.", "JARVIS, restart the Command Centre.", "How much space is left on the Mac?",
                          "Set your voice speed to one point one.", "JARVIS, thank you, that's all for now."]

    /// One phrase: four seconds of recording, sent as a sample. Says what happened, so a failed one can be redone.
    func teachSample(first: Bool) async -> (done: Bool, have: Int, note: String) {
        if session { endSession() }
        guard await AudioSession.microphoneAllowed() else { return (false, 0, "JARVIS needs the microphone: Settings → JARVIS → Microphone.") }
        do {
            try await AudioSession.start()
            if first { _ = try await Client.call("api/voice/start", method: "POST") }
            try recorder.start()
            try await Task.sleep(nanoseconds: 4_200_000_000)
            guard let audio = recorder.stop() else { return (false, 0, "Nothing was recorded. Try again.") }
            let (_, j) = try await Client.call("api/voice/sample", method: "POST", body: audio, type: "audio/mp4")
            if j["done"] as? Bool == true { mustTeach = false; return (true, Talk.phrases.count, "Your voice is set on this phone.") }
            if j["ok"] as? Bool == true { return (false, j["have"] as? Int ?? 0, String(format: "Got it: %.1f seconds.", j["heard_s"] as? Double ?? 0)) }
            let restart = j["restart"] as? Bool == true
            return (false, restart ? 0 : -1, (j["error"] as? String ?? "That one didn't count. Try again.") + (restart ? " Starting again." : ""))
        } catch {
            return (false, -1, error.localizedDescription)
        }
    }
}
