import SwiftUI

private let ink = Color(red: 0.02, green: 0.03, blue: 0.05)
private let arc = Color(red: 0.33, green: 0.78, blue: 0.95)
private let dim = Color(red: 0.55, green: 0.62, blue: 0.70)

struct RootView: View {
    @StateObject private var talk = Talk()
    @ObservedObject private var launch = Launch.shared
    @State private var paired = Pairing.shared.isPaired

    var body: some View {
        Group {
            if paired { TalkView(talk: talk, paired: $paired) } else { PairView(paired: $paired) }
        }
        .background(ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: launch.wantsTalk) { _, want in
            if want && paired { launch.wantsTalk = false; Task { await talk.startSession() } }
        }
        .onAppear {
            if launch.wantsTalk && paired { launch.wantsTalk = false; Task { await talk.startSession() } }
        }
    }
}

// ---------------------------------------------------------------- pairing
struct PairView: View {
    @Binding var paired: Bool
    @State private var address = "https://jarvis.tail36c719.ts.net"
    @State private var code = ""
    @State private var note = "On JARVIS's page: ⋯ → Pair the iPhone App. Confirm with your passkey, then type the code it shows."
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("JARVIS").font(.system(size: 30, weight: .semibold)).tracking(6).foregroundStyle(.white)
                Text(note).foregroundStyle(dim)
                field("Address", text: $address, keyboard: .URL)
                field("Code", text: $code, keyboard: .asciiCapable)
                Button(action: pair) {
                    Text(busy ? "Pairing…" : "Pair with JARVIS").frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).tint(arc).disabled(busy || code.count < 8)
                Text("Tailscale needs to be on, as it is for JARVIS's page.").font(.footnote).foregroundStyle(dim)
            }
            .padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
    }

    private func field(_ label: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote).foregroundStyle(dim)
            TextField(label, text: text)
                .keyboardType(keyboard).textInputAutocapitalization(label == "Code" ? .characters : .never)
                .autocorrectionDisabled().padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                .foregroundStyle(.white)
        }
    }

    private func pair() {
        busy = true
        Task {
            do { try await Pairing.shared.pair(address: address, code: code); paired = true }
            catch { note = error.localizedDescription }
            busy = false
        }
    }
}

// ---------------------------------------------------------------- talking
struct TalkView: View {
    @ObservedObject var talk: Talk
    @Binding var paired: Bool
    @State private var typing = ""
    @State private var showTeach = false
    @State private var confirmUnpair = false

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > 700   // the Duo unfolded: orb on the left, the conversation on the right
            VStack(spacing: 0) {
                header
                if wide {
                    HStack(spacing: 0) {
                        orbArea.frame(width: g.size.width * 0.45)
                        Divider().background(Color.white.opacity(0.08))
                        conversation
                    }
                } else {
                    orbArea.frame(height: min(g.size.height * 0.42, 360))
                    conversation
                }
                inputBar
            }
        }
        .sheet(isPresented: $showTeach) { TeachView(talk: talk) }
        .onChange(of: talk.mustTeach) { _, must in if must { showTeach = true } }
        .confirmationDialog("Unpair this app from JARVIS?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { talk.endSession(); Pairing.shared.unpair(); paired = false }
        }
    }

    private var header: some View {
        HStack {
            Text("JARVIS").font(.system(size: 15, weight: .semibold)).tracking(4).foregroundStyle(.white)
            Spacer()
            Menu {
                Button("Teach JARVIS My Voice on This \(talk.deviceName)") { showTeach = true }
                Button("Unpair This App", role: .destructive) { confirmUnpair = true }
            } label: { Image(systemName: "ellipsis").foregroundStyle(dim).padding(8) }
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var orbArea: some View {
        VStack(spacing: 14) {
            Orb(phase: talk.phase, level: talk.level)
                .frame(width: 220, height: 220)
                .contentShape(Circle())
                .onTapGesture { talk.toggle() }
                .accessibilityLabel(talk.session ? "End the conversation" : "Talk to JARVIS")
                .accessibilityAddTraits(.isButton)
            Text(talk.hint).font(.subheadline).foregroundStyle(dim).multilineTextAlignment(.center).padding(.horizontal)
            if !talk.heard.isEmpty {   // his words as he says them
                Text(talk.heard).font(.body).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                    .lineLimit(3).padding(.horizontal, 24).transition(.opacity)
            }
            if talk.session {
                Button(role: .destructive) { talk.endSession() } label: {
                    Label("End", systemImage: "xmark").padding(.horizontal, 18).padding(.vertical, 8)
                }
                .buttonStyle(.bordered).tint(.red).accessibilityLabel("End the conversation")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(talk.lines) { line in LineView(line: line).id(line.id) }
                }
                .padding(16)
            }
            .onChange(of: talk.lines.last?.text) { _, _ in
                if let last = talk.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask JARVIS", text: $typing)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 22).stroke(arc.opacity(0.5)))
                .foregroundStyle(.white)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) { Image(systemName: "arrow.up").padding(12) }
                .disabled(typing.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func send() {
        let t = typing.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        typing = ""
        talk.send(t)
    }
}

struct LineView: View {
    let line: Line
    var body: some View {
        switch line.who {
        case .him:
            HStack { Spacer(minLength: 40)
                Text(line.text).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
                    .foregroundStyle(.white)
            }
        case .jarvis:
            VStack(alignment: .leading, spacing: 4) {
                if !line.tool.isEmpty { Text(line.tool).font(.caption).foregroundStyle(arc) }
                Text(line.text.isEmpty ? "…" : line.text).font(.title3).foregroundStyle(.white)
                if !line.timing.isEmpty { Text(line.timing).font(.caption2).foregroundStyle(dim) }
            }
        case .note:
            Text(line.text).font(.footnote).foregroundStyle(dim)
        }
    }
}

/// The arc-reactor orb: still when idle, breathing with his voice while listening, turning while thinking.
struct Orb: View {
    let phase: Talk.Phase
    let level: Double
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(arc.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: 0.82)
                .stroke(arc.opacity(phase == .idle ? 0.35 : 0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [26, 14]))
                .padding(18)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(phase == .thinking ? .linear(duration: 2.4).repeatForever(autoreverses: false) : .default, value: spin)
            Circle().stroke(arc.opacity(0.35), lineWidth: 2).padding(52)
            Circle()
                .fill(RadialGradient(colors: [.white, arc, arc.opacity(0)], center: .center, startRadius: 2, endRadius: 70))
                .padding(60)
                .scaleEffect(phase == .listening ? 0.9 + level * 0.5 : (phase == .speaking ? 1.05 : 1))
                .opacity(phase == .idle ? 0.7 : 1)
                .animation(.easeOut(duration: 0.12), value: level)
        }
        .onChange(of: phase) { _, p in spin = (p == .thinking) }
    }
}

// ---------------------------------------------------------------- teaching his voice here
struct TeachView: View {
    @ObservedObject var talk: Talk
    @Environment(\.dismiss) private var dismiss
    @State private var have = 0
    @State private var busy = false
    @State private var note = "JARVIS learns your voice on each device separately, because each microphone hears you a little differently."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Teach JARVIS your voice on this \(talk.deviceName)").font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text("\(have) of \(Talk.phrases.count) saved").foregroundStyle(dim)
            if have < Talk.phrases.count {
                Text("Say this in your normal voice:").foregroundStyle(dim)
                Text("“\(Talk.phrases[have])”").font(.title2).foregroundStyle(.white)
            }
            Text(note).font(.footnote).foregroundStyle(dim)
            Spacer()
            Button(action: record) {
                Text(busy ? "Recording…" : (have >= Talk.phrases.count ? "Done" : "Record")).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).tint(arc).disabled(busy)
        }
        .padding(24)
        .background(ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func record() {
        if have >= Talk.phrases.count { dismiss(); return }
        busy = true
        let first = have == 0
        Task {
            let r = await talk.teachSample(first: first)
            if r.done { have = Talk.phrases.count } else if r.have >= 0 { have = r.have }
            note = r.note
            busy = false
        }
    }
}
