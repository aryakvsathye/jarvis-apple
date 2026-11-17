import CryptoKit
import Foundation
import Security

/// What the app keeps in the Keychain: JARVIS's address, the id JARVIS gave this app when it was paired, and the
/// app's signing key (a Secure Enclave key: only an opaque handle to it is stored, the key itself never leaves the
/// phone's secure hardware). Readable after the first unlock, so "Hey Siri, JARVIS" works with the phone locked.
enum Keychain {
    private static let service = "com.aryakvsathye.jarvis"

    static func set(_ data: Data, for key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}

/// The app's key. On a phone it lives in the Secure Enclave; the simulator has none, so there it's an ordinary key.
private enum SigningKey {
    case enclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)

    static func make() throws -> SigningKey {
        SecureEnclave.isAvailable ? .enclave(try SecureEnclave.P256.Signing.PrivateKey())
                                  : .software(P256.Signing.PrivateKey())
    }

    static func load(_ data: Data) -> SigningKey? {
        if SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
            return .enclave(k)
        }
        if let k = try? P256.Signing.PrivateKey(rawRepresentation: data) { return .software(k) }
        return nil
    }

    var stored: Data {
        switch self {
        case .enclave(let k): return k.dataRepresentation
        case .software(let k): return k.rawRepresentation
        }
    }

    var publicKey: Data {
        switch self {
        case .enclave(let k): return k.publicKey.x963Representation
        case .software(let k): return k.publicKey.x963Representation
        }
    }

    func sign(_ data: Data) throws -> Data {
        switch self {
        case .enclave(let k): return try k.signature(for: data).derRepresentation
        case .software(let k): return try k.signature(for: data).derRepresentation
        }
    }
}

enum PairingError: LocalizedError {
    case badAddress, refused(String)
    var errorDescription: String? {
        switch self {
        case .badAddress: return "That doesn't look like JARVIS's address. It starts with https://jarvis."
        case .refused(let why): return why
        }
    }
}

/// Pairing with JARVIS once, and signing every request after that. JARVIS checks each signature against the public
/// key it was given when paired; a request that's unsigned, reused, for another path or more than a minute old is
/// refused.
final class Pairing {
    static let shared = Pairing()
    private var key: SigningKey?
    private var lastMs: Int64 = 0
    private let lock = NSLock()

    private init() {
        if let d = Keychain.get("key") { key = SigningKey.load(d) }
    }

    var baseURL: URL? {
        guard let d = Keychain.get("base"), let s = String(data: d, encoding: .utf8) else { return nil }
        return URL(string: s)
    }

    var device: String? {
        guard let d = Keychain.get("device") else { return nil }
        return String(data: d, encoding: .utf8)
    }

    var isPaired: Bool { baseURL != nil && device != nil && key != nil }

    /// "jarvis.tail36c719.ts.net" or a full address: always https, no path.
    static func address(_ typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("https://") { s = "https://" + s.replacingOccurrences(of: "http://", with: "") }
        guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
        c.path = ""; c.query = nil; c.fragment = nil
        return c.url
    }

    func pair(address: String, code: String) async throws {
        guard let base = Pairing.address(address) else { throw PairingError.badAddress }
        let k = try SigningKey.make()
        var req = URLRequest(url: base.appendingPathComponent("api/pair/finish"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code, "public_key": k.publicKey.base64EncodedString(), "name": "JARVIS app on iPhone"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let dev = json["device"] as? String else {
            throw PairingError.refused(json["error"] as? String ?? "JARVIS didn't accept the pairing.")
        }
        Keychain.set(k.stored, for: "key")
        Keychain.set(Data(base.absoluteString.utf8), for: "base")
        Keychain.set(Data(dev.utf8), for: "device")
        lock.withLock { key = k; lastMs = 0 }
    }

    func unpair() {
        Keychain.remove("key"); Keychain.remove("base"); Keychain.remove("device")
        lock.withLock { key = nil }
    }

    /// Adds the app's id, a millisecond time (always later than the last one) and the signature to a request.
    func sign(_ req: inout URLRequest) throws {
        guard let k = key, let dev = device, let url = req.url else { throw PairingError.refused("This app isn't paired with JARVIS.") }
        let ms: Int64 = lock.withLock {
            lastMs = max(Int64(Date().timeIntervalSince1970 * 1000), lastMs + 1)
            return lastMs
        }
        let method = (req.httpMethod ?? "GET").uppercased()
        let message = "\(method)\n\(url.path)\n\(ms)\n\(dev)"
        let sig = try k.sign(Data(message.utf8))
        req.setValue(dev, forHTTPHeaderField: "X-JARVIS-App")
        req.setValue(String(ms), forHTTPHeaderField: "X-JARVIS-Time")
        req.setValue(sig.base64EncodedString(), forHTTPHeaderField: "X-JARVIS-Sig")
    }
}
