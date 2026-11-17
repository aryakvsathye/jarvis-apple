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

/// A conversation, like voice mode: tap once and JARVIS listens; it works out when he's finished (from his pause
/// and whether what he said sounds finished), answers, and listens again, until he ends it. He can cut in while
/// JARVIS is talking. JARVIS on the Mac checks the voice, so another voice gets "Unauthorised access detected".
@MainActor
final class Talk: ObservableObject {
    enum Phase { case idle, listening, thinking, speaking }

    @Published var phase: Phase = .idle
    @Published var lines: [Line] = []
    @Published var hint = "Tap to talk"
    @Published var heard = ""                 // his words so far, live
    @Published var level: Double = 0
    @Published var mustTeach = false
    @Published var deviceName = "iPhone"
    @Published private(set) var session = false

    private let engine = Engine.shared
    private let speaker = Speaker()           // for answers to typed questions outside a conversation
    private let words = Transcriber()
    private var timer: Timer?
    private var answerTask: Task<Void, Never>?
    private var answering = false             // the answer is still arriving: a gap between its sentences isn't the end

    // what the room and his voice are doing (updated twenty times a second)
    private var noise = 0.0, latest = 0.0
    private var hearing = false               // he's speaking (or spoke and is pausing) in this turn
    private var started = Date(), lastSpeech = Date(), lastHeard = Date()
    private var cutIn: Date?                  // when loud sound started while JARVIS was busy (a possible interruption)

    static let sessionIdle: TimeInterval = 15 * 60      // a conversation with nothing said ends itself
    static let speakLevel = 0.04
    static let longest: TimeInterval = 60

    init() {
        speaker.onIdle = { [weak self] in Task { @MainActor in self?.answered() } }
        engine.onIdle = { [weak self] in Task { @MainActor in self?.answered() } }
        engine.onLevel = { [weak self] lv in Task { @MainActor in self?.latest = lv } }
    }

    // ---------------------------------------------------------------- getting JARVIS ready
    private static var warmedAt = Date.distantPast

    /// Ask JARVIS to load its brain (if it was unloaded) and read the conversation now, while he's still opening the
    /// app or talking, rather than after his question arrives. At most every 20 seconds.
    static func warm() {
        guard Pairing.shared.isPaired, Date().timeIntervalSince(warmedAt) > 20 else { return }
        warmedAt = Date()
        Task { _ = try? await Client.call("api/warm", method: "POST") }
    }

    // ---------------------------------------------------------------- the conversation
    func toggle() {
        if session { endSession() } else { Task { await startSession() } }
    }

    func startSession() async {
        guard !session else { return }
        Talk.warm()
        guard await AudioSession.microphoneAllowed() else {
            hint = "JARVIS needs the microphone: Settings → JARVIS → Microphone."
            return
        }
        await words.authorise()
        do {
            try await AudioSession.start()
            try engine.start()
        } catch { hint = error.localizedDescription; return }
        session = true
        lastHeard = Date()
        listen()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func endSession() {
        session = false
        timer?.invalidate(); timer = nil
        answerTask?.cancel(); answerTask = nil
        words.finish()
        engine.stop()
        hearing = false; heard = ""; level = 0
        phase = .idle; hint = "Tap to talk"
    }

    private func listen() {
        guard session else { return }
        phase = .listening
        hint = "Listening. Tap to end."
        hearing = false; heard = ""; cutIn = nil
        engine.discardCapture()
        started = Date()
    }

    /// Twenty times a second: is he talking, compared with the room? Has he finished? Is he cutting in?
    private func tick() {
        guard session else { return }
        let lv = latest
        level = lv
        // the room's level follows quickly when it gets quieter, slowly when louder: a steady TV becomes the floor
        noise = noise == 0 ? lv : (lv < noise ? noise * 0.9 + lv * 0.1 : noise * 0.998 + lv * 0.002)
        let loud = lv > max(Talk.speakLevel, noise * 2.5)
        let now = Date()
        if loud { lastHeard = now }

        switch phase {
        case .listening:
            if loud && !hearing {
                hearing = true; started = now
                engine.beginCapture(transcribing: words.begin())
            }
            if loud { lastSpeech = now }
            if hearing {
                heard = words.text
                let pause = now.timeIntervalSince(lastSpeech)
                let spokeFor = lastSpeech.timeIntervalSince(started)
                if spokeFor < 0.25 && pause > 1.0 && words.text.isEmpty {
                    hearing = false; words.finish(); engine.discardCapture()   // a cough or a knock, not words
                } else if pause >= Transcriber.pauseNeeded(after: words.text, hearing: words.available)
                            || now.timeIntervalSince(started) > Talk.longest {
                    finishTurn()
                }
            } else if now.timeIntervalSince(lastHeard) > Talk.sessionIdle {
                endSession()
            }
        case .thinking, .speaking:
            // cutting in: loud for a moment, and (when words can be recognised) at least two of them
            if loud {
                if cutIn == nil {
                    cutIn = now; started = now
                    engine.beginCapture(transcribing: words.begin())
                }
                lastSpeech = now
            }
            if let c = cutIn {
                let wordsSoFar = words.text.split(separator: " ").count
                if (words.available && wordsSoFar >= 2) || (!words.available && now.timeIntervalSince(c) > 0.6 && loud) {
                    interrupt()
                } else if now.timeIntervalSince(lastSpeech) > 1.2 {
                    cutIn = nil; words.finish(); engine.discardCapture()   // just noise
                }
            }
        case .idle:
            break
        }
    }

    /// He started talking over JARVIS: stop it, drop the rest of the answer, and listen to him (already recording).
    private func interrupt() {
        cutIn = nil
        answerTask?.cancel(); answerTask = nil
        answering = false
        engine.stopSpeaking()
        phase = .listening; hint = "Listening. Tap to end."
        hearing = true
    }

    private func finishTurn() {
        hearing = false
        let audio = engine.endCapture()
        words.finish()
        heard = ""
        phase = .thinking; hint = "Listening back…"; level = 0
        answerTask = Task { await hear(audio) }
    }

    // ---------------------------------------------------------------- hearing and asking
    private func hear(_ audio: Data) async {
        do {
            let (status, j) = try await Client.call("api/hear", method: "POST", body: audio, type: "audio/wav")
            if Task.isCancelled { return }
            if status == 409, j["teach"] as? Bool == true {
                deviceName = j["device_name"] as? String ?? "iPhone"
                mustTeach = true
                endSession(); hint = "Teach JARVIS your voice to talk here."
                return
            }
            if status == 401 { endSession(); hint = "This app isn't paired any more. Pair it again."; return }
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
            if Task.isCancelled { return }
            hint = error.localizedDescription; answered()
        }
    }

    /// A typed question: answered the same way, spoken through the conversation if one is on.
    func send(_ text: String) {
        answerTask?.cancel()
        answerTask = Task { await ask(text) }
    }

    func ask(_ text: String) async {
        answering = true
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
                if Task.isCancelled { break }
                if let tool = ev["tool"] as? String {
                    reply.tool = Talk.toolLabel(tool); lines[index] = reply
                }
                if let t = ev["text"] as? String {
                    if firstWord == nil { firstWord = Date().timeIntervalSince(sent) }
                    reply.text += t; lines[index] = reply
                }
                if let b64 = ev["say"] as? String, let wav = Data(base64Encoded: b64) {
                    if phase != .listening { phase = .speaking; hint = session ? "Speaking. Talk to cut in." : "Speaking…" }
                    if session { engine.play(wav) } else { speaker.add(wav) }
                }
                if let e = ev["error"] as? String { reply.text += (reply.text.isEmpty ? "" : " ") + e; lines[index] = reply }
            }
        } catch {
            if !Task.isCancelled { reply.text = error.localizedDescription; lines[index] = reply }
        }
        if let f = firstWord { reply.timing = String(format: "first word %.1f s", f); lines[index] = reply }
        if Task.isCancelled { return }   // he cut in: listening is already under way
        answering = false
        answered()   // waits for the last sentence to finish playing, if it hasn't
    }

    /// After an answer (or nothing to answer): listen again if the conversation is on.
    private func answered() {
        guard !engine.isSpeaking, !speaker.isSpeaking, !answering else { return }   // more is on its way
        if session {
            if phase != .listening || !hearing { listen() }
        } else {
            phase = .idle
            if hint.hasPrefix("Speaking") || hint == "Thinking…" { hint = "Tap to talk" }
        }
    }

    static func toolLabel(_ name: String) -> String {
        let acts = ["restart_project": "restart a project", "update_project": "update a project",
                    "roll_back_project": "roll back a project", "check_for_updates": "check for updates",
                    "change_setting": "change a setting"]
        if let a = acts[name] { return "Asked the Command Centre to " + a }
        let checks = ["server_status": "the server", "current_time": "the time", "thinking": "it through carefully",
                      "web_search": "the web", "weather": "the weather", "news": "the news"]
        return "Checked " + (checks[name] ?? name.replacingOccurrences(of: "_", with: " "))
    }

    // ---------------------------------------------------------------- teaching his voice on this phone
    static let phrases = ["JARVIS, how's the server?", "JARVIS, what's the time?", "JARVIS, is Portfolio running?",
                          "Good morning, JARVIS.", "JARVIS, restart the Command Centre.", "How much space is left on the Mac?",
                          "Set your voice speed to one point one.", "JARVIS, thank you, that's all for now."]

    /// One phrase: four seconds through the same microphone a conversation uses (with its echo cancellation), so the
    /// voiceprint matches what JARVIS hears when talking. Says what happened, so a failed one can be redone.
    func teachSample(first: Bool) async -> (done: Bool, have: Int, note: String) {
        if session { endSession() }
        guard await AudioSession.microphoneAllowed() else { return (false, 0, "JARVIS needs the microphone: Settings → JARVIS → Microphone.") }
        do {
            try await AudioSession.start()
            if first { _ = try await Client.call("api/voice/start", method: "POST") }
            try engine.start()
            engine.beginCapture(transcribing: nil)
            try await Task.sleep(nanoseconds: 4_200_000_000)
            let audio = engine.endCapture()
            engine.stop()
            let (_, j) = try await Client.call("api/voice/sample", method: "POST", body: audio, type: "audio/wav")
            if j["done"] as? Bool == true { mustTeach = false; return (true, Talk.phrases.count, "Your voice is set on this phone.") }
            if j["ok"] as? Bool == true { return (false, j["have"] as? Int ?? 0, String(format: "Got it: %.1f seconds.", j["heard_s"] as? Double ?? 0)) }
            let restart = j["restart"] as? Bool == true
            return (false, restart ? 0 : -1, (j["error"] as? String ?? "That one didn't count. Try again.") + (restart ? " Starting again." : ""))
        } catch {
            engine.stop()
            return (false, -1, error.localizedDescription)
        }
    }
}
