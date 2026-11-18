import CoreBluetooth
import Foundation

/// The car. JARVIS is the only app that talks to the OBD-II adapter (a Vgate iCar Pro 2S, Bluetooth LE): Aryak's
/// choice, 17 Nov. Once the adapter is chosen (⋯ → Car), iOS keeps a standing request to connect to it, so it
/// connects by itself whenever the car is on, even with the app in the background. While connected, JARVIS reads
/// the car over and over (speed, fuel, engine temperature, battery voltage); when the adapter goes quiet (the car's
/// off), the trip goes to JARVIS on the Mac. A trip that can't be sent yet waits and goes with the next one.
/// Only what the car reports: no position is sent.
final class Car: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = Car()

    @Published private(set) var status = "Not set up"
    @Published private(set) var choices: [CBPeripheral] = []   // adapters found while choosing
    @Published private(set) var lastSent: String?

    private var central: CBCentralManager!
    private let queue = DispatchQueue(label: "com.aryakvsathye.jarvis.car")
    private var adapter: CBPeripheral?
    private var writer: CBCharacteristic?
    private var started = false        // the adapter's set up for this connection
    private var buffer = ""
    private var waiting: ((String) -> Void)?
    private var commands: [(String, (String) -> Void)] = []
    private var attempt = 0            // which command a timeout belongs to
    private var trip: Trip?
    private var lastSpeedAt: Date?
    private var choosing = false

    private static let savedKey = "car.adapter"
    private static let outboxKey = "car.outbox"
    private static let restoreKey = "com.aryakvsathye.jarvis.car"

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Car.restoreKey])
    }

    /// Called at launch: creating the manager is what reconnects to the adapter, and sends anything left unsent.
    func start() { _ = central; Task { await sendOutbox() } }

    private func show(_ s: String) { DispatchQueue.main.async { self.status = s } }

    private var saved: UUID? {
        get { UserDefaults.standard.string(forKey: Car.savedKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Car.savedKey) }
    }
    var isSetUp: Bool { saved != nil }

    // ------------------------------------------------------------ choosing the adapter
    /// Look for adapters nearby. The car has to be on (the adapter sleeps when it's off).
    func choose() {
        queue.async {
            guard self.central.state == .poweredOn else { self.show("Bluetooth is off, or JARVIS isn't allowed to use it."); return }
            self.choosing = true
            DispatchQueue.main.async { self.choices = [] }
            self.show("Looking for the adapter… (the car must be on)")
            self.central.scanForPeripherals(withServices: nil)
            self.queue.asyncAfter(deadline: .now() + 20) {
                guard self.choosing else { return }
                self.central.stopScan(); self.choosing = false
                DispatchQueue.main.async {
                    if self.choices.isEmpty { self.status = "No adapter found. Is the car on, and is Pelican closed?" }
                }
            }
        }
    }

    func use(_ p: CBPeripheral) {
        queue.async {
            self.central.stopScan(); self.choosing = false
            self.saved = p.identifier
            DispatchQueue.main.async { self.choices = [] }
            self.connect(p)
        }
    }

    func forget() {
        queue.async {
            if let a = self.adapter { self.central.cancelPeripheralConnection(a) }
            self.adapter = nil; self.saved = nil
            self.show("Not set up")
        }
    }

    private func connect(_ p: CBPeripheral) {
        adapter = p
        p.delegate = self
        central.connect(p)   // a standing request: iOS connects whenever the adapter wakes, even in the background
        show("Waiting for the car")
    }

    // ------------------------------------------------------------ Bluetooth
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            show(c.state == .unauthorized ? "JARVIS isn't allowed to use Bluetooth: Settings → JARVIS." : "Bluetooth is off.")
            return
        }
        if let a = adapter {   // restored by iOS after a relaunch in the background
            if a.state == .connected { centralManager(c, didConnect: a) } else { connect(a) }
        } else if let id = saved, let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            adapter = p
            p.delegate = self
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard choosing, let name = p.name, !name.isEmpty else { return }
        let lower = name.lowercased()
        // the Vgate calls itself something like "IOS-Vlink"; other adapters "OBDII", "OBDBLE", "V-LINK"
        guard ["vlink", "v-link", "vgate", "obd", "elm", "icar"].contains(where: { lower.contains($0) }) else { return }
        DispatchQueue.main.async {
            if !self.choices.contains(where: { $0.identifier == p.identifier }) { self.choices.append(p) }
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        show("Connected: reading the car")
        started = false; buffer = ""; commands = []; waiting = nil; writer = nil
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if saved == p.identifier { connect(p) }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        // the car's off (the adapter sleeps): the trip's over; wait for the next one
        endTrip()
        started = false; waiting = nil; commands = []
        if saved == p.identifier { connect(p) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard writer == nil else { return }
        let chars = s.characteristics ?? []
        // the adapter's serial line: one characteristic it answers on (notify) and one it listens on (write), in the
        // same service (the Vgate's is FFF0, with FFF1 and FFF2)
        guard let notify = chars.first(where: { $0.properties.contains(.notify) }),
              let write = chars.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) })
        else { return }
        writer = write
        p.setNotifyValue(true, for: notify)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch.isNotifying, !started else { return }
        started = true
        setUp()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value, let s = String(data: d, encoding: .ascii) else { return }
        buffer += s
        guard let end = buffer.firstIndex(of: ">") else { return }   // ">" means the adapter's ready for more
        let reply = String(buffer[..<end])
        buffer = String(buffer[buffer.index(after: end)...])
        let done = waiting
        waiting = nil
        done?(reply)
        next()
    }

    // ------------------------------------------------------------ talking to the adapter (ELM327 commands)
    private func send(_ cmd: String, _ then: @escaping (String) -> Void = { _ in }) {
        commands.append((cmd, then))
        if waiting == nil { next() }
    }

    private func next() {
        guard waiting == nil, !commands.isEmpty, let p = adapter, let w = writer, p.state == .connected else { return }
        let (cmd, then) = commands.removeFirst()
        waiting = then
        attempt += 1
        let mine = attempt
        let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data((cmd + "\r").utf8), for: w, type: type)
        queue.asyncAfter(deadline: .now() + 5) {   // no answer in 5 seconds: carry on without one
            guard self.attempt == mine, let stuck = self.waiting else { return }
            self.waiting = nil; self.buffer = ""
            stuck("")
            self.next()
        }
    }

    private func setUp() {
        // reset; no echo, no line feeds, no spaces, no headers; find the car's protocol by itself
        for c in ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"] { send(c) }
        trip = Trip(started: Date())
        lastSpeedAt = nil
        send("0101") { r in   // check-engine light and how many codes are stored
            if let b = OBD.bytes(r, "01") { self.trip?.checkEngine = (b[0] & 0x80) != 0 }
        }
        send("03") { r in self.trip?.codes = OBD.codes(r) }
        send("0146") { r in if let b = OBD.bytes(r, "46") { self.trip?.ambient = Double(b[0]) - 40 } }
        send("01A6") { r in   // odometer: only newer cars report it
            if let b = OBD.bytes(r, "A6"), b.count >= 4 {
                self.trip?.odometer = Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) / 10
            }
        }
        send("012F") { r in if let b = OBD.bytes(r, "2F") { self.trip?.fuelStart = Double(b[0]) * 100 / 255 } }
        poll()
    }

    /// One round of readings; the next starts when it's done, for as long as the car's on. Each answer from the
    /// adapter wakes the app, so this keeps going in the background, where a timer wouldn't.
    private func poll() {
        guard adapter?.state == .connected, trip != nil else { return }
        send("010D") { r in
            guard let b = OBD.bytes(r, "0D") else { return }
            let now = Date(), kmh = Double(b[0])
            if let at = self.lastSpeedAt { self.trip?.add(speed: kmh, seconds: min(now.timeIntervalSince(at), 10)) }
            self.lastSpeedAt = now
        }
        send("0105") { r in if let b = OBD.bytes(r, "05") { self.trip?.coolant(Double(b[0]) - 40) } }
        send("012F") { r in if let b = OBD.bytes(r, "2F") { self.trip?.fuelEnd = Double(b[0]) * 100 / 255 } }
        send("ATRV") { r in   // the battery's voltage, measured by the adapter itself: works on every car
            if let v = OBD.volts(r) { self.trip?.volts(v) }
            self.queue.asyncAfter(deadline: .now() + 0.5) { self.poll() }
        }
    }

    private func endTrip() {
        guard let t = trip else { return }
        trip = nil
        let seconds = Date().timeIntervalSince(t.started)
        guard seconds >= 60 else { return }   // a minute or less isn't a trip (the car started and stopped)
        var out = UserDefaults.standard.array(forKey: Car.outboxKey) as? [[String: Any]] ?? []
        out.append(t.json(ended: Date()))
        UserDefaults.standard.set(Array(out.suffix(50)), forKey: Car.outboxKey)
        show("Trip saved: sending it to JARVIS")
        Task { await sendOutbox() }
    }

    /// Every trip not yet on the Mac. One that's refused as not a trip is dropped; one that couldn't be sent stays.
    func sendOutbox() async {
        let out = UserDefaults.standard.array(forKey: Car.outboxKey) as? [[String: Any]] ?? []
        guard !out.isEmpty, Pairing.shared.baseURL != nil else { return }
        var left: [[String: Any]] = []
        for t in out {
            do {
                let (code, _) = try await Client.call("api/car/trip", method: "POST", json: t)
                if code != 200 && code != 400 { left.append(t) }
            } catch {
                left.append(t)
            }
        }
        UserDefaults.standard.set(left, forKey: Car.outboxKey)
        let when = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        DispatchQueue.main.async {
            if left.isEmpty { self.lastSent = "Last trip sent at \(when)" }
            else { self.status = "\(left.count) trip\(left.count == 1 ? "" : "s") waiting to be sent (JARVIS couldn't be reached)" }
        }
    }
}

/// One trip, built up from the readings.
struct Trip {
    let started: Date
    var km = 0.0, movingSeconds = 0.0, maxKmh = 0.0
    var fuelStart: Double?, fuelEnd: Double?
    var coolantMax: Double?, voltsMin: Double?, voltsEnd: Double?, ambient: Double?, odometer: Double?
    var codes: [String] = []
    var checkEngine: Bool?

    mutating func add(speed kmh: Double, seconds: Double) {
        km += kmh * seconds / 3600
        if kmh > 0 { movingSeconds += seconds }
        maxKmh = max(maxKmh, kmh)
    }
    mutating func coolant(_ c: Double) { coolantMax = max(coolantMax ?? c, c) }
    mutating func volts(_ v: Double) { voltsEnd = v; voltsMin = min(voltsMin ?? v, v) }

    func json(ended: Date) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var j: [String: Any] = ["started": iso.string(from: started), "ended": iso.string(from: ended),
                                "duration_s": ended.timeIntervalSince(started), "distance_km": km,
                                "max_speed_kmh": maxKmh, "trouble_codes": codes]
        if movingSeconds > 0 { j["avg_speed_kmh"] = km / (movingSeconds / 3600) }
        if let v = fuelStart { j["fuel_start_pct"] = v }
        if let v = fuelEnd { j["fuel_end_pct"] = v }
        if let v = coolantMax { j["coolant_max_c"] = v }
        if let v = voltsMin { j["battery_min_v"] = v }
        if let v = voltsEnd { j["battery_end_v"] = v }
        if let v = ambient { j["ambient_c"] = v }
        if let v = odometer { j["odometer_km"] = v }
        if let v = checkEngine { j["check_engine_light"] = v }
        return j
    }
}

/// Reading the adapter's answers.
enum OBD {
    /// The data bytes of a mode-01 answer: "410D3C" for PID 0D gives [0x3C]. Nil for "NO DATA", errors or silence.
    static func bytes(_ reply: String, _ pid: String) -> [UInt8]? {
        let hex = reply.uppercased().filter { $0.isHexDigit }
        guard let r = hex.range(of: "41" + pid) else { return nil }
        let rest = Array(hex[r.upperBound...])
        var out: [UInt8] = []
        var i = 0
        while i + 1 < rest.count, out.count < 4 {
            guard let b = UInt8(String(rest[i...i + 1]), radix: 16) else { break }
            out.append(b)
            i += 2
        }
        return out.isEmpty ? nil : out
    }

    /// The adapter's own battery reading: "12.6V" → 12.6.
    static func volts(_ reply: String) -> Double? {
        let digits = reply.filter { $0.isNumber || $0 == "." }
        guard let v = Double(digits), v > 0, v < 20 else { return nil }
        return v
    }

    /// Stored trouble codes from a mode-03 answer. Older cars answer "43" then three codes, padded with zeros
    /// ("430133000000" → P0133); CAN cars (most since 2008) put a count first ("43010133" → P0133), and a long answer
    /// comes in numbered lines ("0:4302013302", "1:20…") after a line with its length.
    static func codes(_ reply: String) -> [String] {
        let lines = reply.uppercased().split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
        let numbered = lines.filter { $0.contains(":") }
        let joined = (numbered.isEmpty ? lines : numbered.map { String($0[$0.index(after: $0.firstIndex(of: ":")!)...]) })
            .joined().filter { $0.isHexDigit }
        guard let r = joined.range(of: "43") else { return [] }
        let hex = Array(joined[r.upperBound...])
        var bytes: [UInt8] = []
        var i = 0
        while i + 1 < hex.count, let b = UInt8(String(hex[i...i + 1]), radix: 16) { bytes.append(b); i += 2 }
        if let n = bytes.first, bytes.count >= 1 + 2 * Int(n), bytes.count % 2 == 1 || n == 0 {
            bytes = Array(bytes.dropFirst())   // CAN: the count first
        }
        var found: [String] = []
        var j = 0
        while j + 1 < bytes.count {
            let v = UInt16(bytes[j]) << 8 | UInt16(bytes[j + 1])
            j += 2
            guard v != 0 else { continue }
            let kind = ["P", "C", "B", "U"][Int(v >> 14)]
            found.append(kind + String(format: "%01X%03X", UInt32((v >> 12) & 0x3), UInt32(v & 0xFFF)))
        }
        return Array(Set(found)).sorted()
    }
}
