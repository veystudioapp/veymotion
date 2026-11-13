import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import IOKit

/// What VeyMotion Pro unlocks. Server features are enforced by the server too (`server/utils/license.ts`);
/// the rest is checked here, in the app and the CLI.
public enum ProFeature: String, CaseIterable, Sendable {
    // Through the VeyMotion server (cost money per use).
    case vietnameseVoice, stockVideo
    // Export.
    case highResExport, proResExport, noWatermark
    // Content a Free scene can preview but not export.
    case threeD, backgroundRemoval
    // Actions.
    case stabilize, motionTracking, autoReframe, templates, graphEditor

    public var title: String {
        switch self {
        case .vietnameseVoice: return "Vietnamese voices (VieNeu)"
        case .stockVideo: return "Stock video"
        case .highResExport: return "Export above 1080p"
        case .proResExport: return "ProRes 4444 export"
        case .noWatermark: return "Export without watermark"
        case .threeD: return "3D layers and models"
        case .backgroundRemoval: return "Background removal"
        case .stabilize: return "Stabilize"
        case .motionTracking: return "Motion tracking"
        case .autoReframe: return "Auto reframe"
        case .templates: return "Templates"
        case .graphEditor: return "Graph editor"
        }
    }
}

/// The license as the app shows it.
public struct LicenseInfo: Equatable, Sendable {
    public var plan: String
    public var email: String?
    public var name: String?
    /// "…A1B2C3": the end of the key, to recognise it.
    public var keyHint: String
    /// When the license ends (only if the Polar benefit sets an expiration); nil = lifetime.
    public var licenseExpiresAt: Date?
    /// Pro works offline until this date; the app refreshes it daily.
    public var validUntil: Date
    public var issuedAt: Date

    public var isValid: Bool { validUntil > Date() }
}

public enum LicenseError: LocalizedError {
    case proRequired(ProFeature)
    case proContent([ProFeature])
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .proRequired(f):
            return "\(f.title) needs VeyMotion Pro. Enter a license key in Settings → Account, or buy one there."
        case let .proContent(list):
            return "This scene uses Pro features (\(list.map(\.title).joined(separator: ", "))). Previewing them is free; "
                + "exporting needs VeyMotion Pro (Settings → Account). Remove them to export with the Free plan."
        case let .failed(m):
            return m
        }
    }
}

/// VeyMotion Pro: a Polar license key, activated once per Mac through the VeyMotion server, which answers with a
/// token signed with Ed25519 (`payload.signature`, both base64url). The token is checked here offline with
/// `publicKeyBase64`, is bound to this Mac (`deviceId`), and is valid for 14 days; `refreshIfDue` renews it daily.
/// Stored in Application Support/VeyMotion/license.json (not the keychain: the CLI reads it too, and an ad-hoc
/// signed app would be asked for keychain access after every update). Copying the file to another Mac does nothing.
public enum License {
    /// Raw Ed25519 public key (base64) matching the server's NITRO_LICENSE_PRIVATE_KEY (`bun run license:keygen`).
    /// Empty = licensing not set up: everyone is on Free.
    public static let publicKeyBase64 = "2alO3WK4W+ucOGonAcyzE5Qq8KjMYsA0h8QoKtg32m8="

    /// Posted (on any thread) when the license is activated, refreshed, dropped or removed.
    public static let didChange = Notification.Name("VeyMotionLicenseDidChange")

    /// Free exports fit in this box (1080p, either orientation).
    public static let freeMaxLongSide = 1920
    public static let freeMaxShortSide = 1080

    // MARK: State

    struct Payload: Codable {
        var v: Int
        var plan: String
        var key: String
        var keyId: String
        var activation: String
        var benefit: String
        var customer: String
        var device: String
        var email: String?
        var name: String?
        var licenseExpiresAt: String?
        var iat: Double
        var exp: Double
    }

    struct Stored: Codable {
        var token: String
        /// Last refresh attempt (successful or not), to space them out.
        var checkedAt: Date?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (stamp: Date?, stored: Stored?, payload: Payload?)?

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VeyMotion/license.json")
    }

    /// The stored license (even if it needs a refresh), or nil.
    public static var stored: LicenseInfo? { load().payload.map(info) }

    /// The license when it is valid right now on this Mac.
    public static var current: LicenseInfo? { stored.flatMap { $0.isValid ? $0 : nil } }

    public static var isPro: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["VEYMOTION_PRO"] == "1" { return true }
        #endif
        return current != nil
    }

    /// Throws `LicenseError.proRequired` unless Pro is active.
    public static func require(_ feature: ProFeature) throws {
        if !isPro { throw LicenseError.proRequired(feature) }
    }

    /// Adds the license token to a request to the VeyMotion server (server features check it).
    public static func authorize(_ req: inout URLRequest) {
        if let token = load().stored?.token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    // MARK: Server calls (blocking; not on the main thread)

    /// Activates `key` on this Mac.
    @discardableResult
    public static func activate(key: String) throws -> LicenseInfo {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LicenseError.failed("Enter a license key.") }
        guard !publicKeyBase64.isEmpty || debugPublicKey != nil else {
            throw LicenseError.failed("This build of VeyMotion has no license public key (License.publicKeyBase64).")
        }
        let (data, status) = try call("/api/license/activate", json: [
            "key": key, "device": deviceId, "deviceName": deviceName, "appVersion": AppVersion.display,
        ], token: nil)
        guard (200..<300).contains(status) else { throw LicenseError.failed(message(data, status: status)) }
        do {
            return try save(data)
        } catch {
            // Polar counted this activation but the app cannot use the token (e.g. a signing key mismatch):
            // free it again, or every retry would use up one of the key's Macs.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = obj["token"] as? String {
                _ = try? call("/api/license/deactivate", json: [:], token: token)
            }
            throw error
        }
    }

    /// Renews the token. Returns nil (and removes the license) when the server says it ended; throws when the
    /// server cannot be reached or answers otherwise, keeping the stored license.
    @discardableResult
    public static func refresh() throws -> LicenseInfo? {
        guard let s = load().stored else { return nil }
        markChecked()
        let (data, status) = try call("/api/license/refresh", json: [:], token: s.token)
        if status == 402 || status == 401 {
            remove()
            throw LicenseError.failed(message(data, status: status))
        }
        guard (200..<300).contains(status) else { throw LicenseError.failed(message(data, status: status)) }
        return try save(data)
    }

    /// Refreshes when the last attempt is over a day old (or the token has expired) and quietly ignores network
    /// errors. Safe to call often, e.g. at launch and when the app becomes active.
    public static func refreshIfDue() {
        let state = load()
        guard let s = state.stored, let p = state.payload else { return }
        let age = Date().timeIntervalSince1970 - p.iat
        let lastTry = s.checkedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let expired = p.exp < Date().timeIntervalSince1970
        guard age > 86_400 || expired, lastTry > (expired ? 300 : 3_600) else { return }
        _ = try? refresh()
    }

    /// Frees this Mac's activation on the server (so the key can be used elsewhere) and removes the license here.
    /// The local license is removed even when the server cannot be reached.
    public static func deactivate() throws {
        guard let s = load().stored else { return }
        defer { remove() }
        let (data, status) = try call("/api/license/deactivate", json: [:], token: s.token)
        guard (200..<300).contains(status) || status == 401 else { throw LicenseError.failed(message(data, status: status)) }
    }

    public struct ServerInfo: Sendable {
        public var configured: Bool
        public var checkoutURL: URL?
        public var portalURL: URL?
    }

    /// Where to buy and manage Pro, from the server. Blocking.
    public static func serverInfo() throws -> ServerInfo {
        let base = VieNeu.baseURL
        guard let url = URL(string: base.absoluteString + "/api/license") else { throw LicenseError.failed("Invalid BASE_API_URL") }
        let r = try HTTP.perform(HTTP.request(url, timeout: 15))
        guard (200..<300).contains(r.response?.statusCode ?? 0),
              let obj = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any] else {
            throw LicenseError.failed("The VeyMotion server at \(base.absoluteString) has no licensing route.")
        }
        return ServerInfo(configured: obj["configured"] as? Bool ?? false,
                          checkoutURL: (obj["checkoutUrl"] as? String).flatMap(URL.init(string:)),
                          portalURL: (obj["portalUrl"] as? String).flatMap(URL.init(string:)))
    }

    // MARK: Pro content of a scene

    /// Pro features a scene uses that exporting with the Free plan does not allow.
    public static func proContent(of scene: MotionScene) -> [ProFeature] {
        var found: [ProFeature] = []
        let layers = scene.allLayers
        if layers.contains(where: { $0.threeD || $0.type == .model }) { found.append(.threeD) }
        if layers.contains(where: { $0.removeBackground != nil }) { found.append(.backgroundRemoval) }
        return found
    }

    /// Applies the Free plan to an export: refuses Pro content and ProRes, and fits the size into 1080p.
    /// Returns whether to draw the watermark. Pro: no change, no watermark.
    public static func prepareExport(_ scene: MotionScene, options: inout ExportOptions, format: ExportFormat) throws -> Bool {
        if isPro || format.isAudioOnly { return false }
        if format == .mov { throw LicenseError.proRequired(.proResExport) }
        let pro = proContent(of: scene)
        if !pro.isEmpty { throw LicenseError.proContent(pro) }
        let (w, h) = options.pixelSize(for: scene)
        let s = min(1, Double(freeMaxLongSide) / Double(max(w, h)), Double(freeMaxShortSide) / Double(min(w, h)))
        if s < 1 {
            options.size = PixelSize(width: Int((Double(w) * s).rounded()), height: Int((Double(h) * s).rounded()))
        }
        return true
    }

    // MARK: Device

    /// This Mac: base64url SHA-256 of its hardware UUID (the UUID itself never leaves the Mac).
    public static let deviceId: String = {
        var uuid = ""
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service != 0 {
            if let v = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String { uuid = v }
            IOObjectRelease(service)
        }
        if uuid.isEmpty { uuid = ProcessInfo.processInfo.hostName }
        return Data(SHA256.hash(data: Data("veymotion-license:\(uuid)".utf8))).base64URL
    }()

    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    // MARK: Token

    private static var debugPublicKey: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["VEYMOTION_LICENSE_PUBLIC_KEY"]
        #else
        return nil
        #endif
    }

    /// The verified payload of a token, or nil (bad signature, other Mac, unknown format). Expiry is not checked.
    static func verify(_ token: String) -> Payload? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let keyData = Data(base64Encoded: debugPublicKey ?? publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Data(base64URL: String(parts[1])),
              key.isValidSignature(signature, for: Data(parts[0].utf8)),
              let json = Data(base64URL: String(parts[0])),
              let p = try? JSONDecoder().decode(Payload.self, from: json),
              p.v == 1, p.plan == "pro", p.device == deviceId
        else { return nil }
        return p
    }

    private static func info(_ p: Payload) -> LicenseInfo {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ends = p.licenseExpiresAt.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return LicenseInfo(plan: p.plan, email: p.email, name: p.name, keyHint: "…" + p.key.suffix(6),
                           licenseExpiresAt: ends, validUntil: Date(timeIntervalSince1970: p.exp),
                           issuedAt: Date(timeIntervalSince1970: p.iat))
    }

    // MARK: Storage

    private static func load() -> (stored: Stored?, payload: Payload?) {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        lock.lock()
        defer { lock.unlock() }
        if let c = cache, c.stamp == stamp { return (c.stored, c.payload) }
        let stored = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode(Stored.self, from: $0) }
        let payload = stored.flatMap { verify($0.token) }
        cache = (stamp, stored, payload)
        return (stored, payload)
    }

    private static func write(_ stored: Stored?, notify: Bool = true) {
        let fm = FileManager.default
        if let stored, let data = try? encoder.encode(stored) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Not .atomic: that stages in the system temp folder, which sandboxed processes cannot use.
            let part = fileURL.appendingPathExtension("part")
            try? fm.removeItem(at: part)
            if fm.createFile(atPath: part.path, contents: data, attributes: [.posixPermissions: 0o600]) {
                try? fm.removeItem(at: fileURL)
                try? fm.moveItem(at: part, to: fileURL)
            }
        } else {
            try? fm.removeItem(at: fileURL)
        }
        lock.lock(); cache = nil; lock.unlock()
        if notify { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    private static func save(_ response: Data) throws -> LicenseInfo {
        guard let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let token = obj["token"] as? String else {
            throw LicenseError.failed("The VeyMotion server sent an unreadable license.")
        }
        guard let p = verify(token) else {
            throw LicenseError.failed("The license from the server does not match this app (signing key or Mac).")
        }
        write(Stored(token: token, checkedAt: Date()))
        return info(p)
    }

    private static func markChecked() {
        guard var s = load().stored else { return }
        s.checkedAt = Date()
        write(s, notify: false)
    }

    /// Removes the license from this Mac only (the activation stays on the server).
    public static func remove() { write(nil) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: HTTP

    private static func call(_ path: String, json: [String: Any], token: String?) throws -> (Data, Int) {
        let base = VieNeu.baseURL
        guard let url = URL(string: base.absoluteString + path) else { throw LicenseError.failed("Invalid BASE_API_URL: \(base)") }
        var req = HTTP.request(url, timeout: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        do {
            let r = try HTTP.perform(req)
            return (r.data, r.response?.statusCode ?? 0)
        } catch {
            throw LicenseError.failed("Cannot reach the VeyMotion server at \(base.absoluteString). \(error.localizedDescription)")
        }
    }

    private static func message(_ data: Data, status: Int) -> String {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["message"] as? String ?? "VeyMotion server error (HTTP \(status))"
    }
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// "Made with Vey Motion" in the bottom-right corner of Free exports.
enum Watermark {
    static let text = "Made with Vey Motion"

    static func draw(in ctx: CGContext, width: Int, height: Int) {
        let short = Double(min(width, height))
        let fontSize = max(12, short * 0.03)
        let font = CTFontCreateWithName("Helvetica Neue Medium" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 0.92),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let padX = fontSize * 0.6, padY = fontSize * 0.4, margin = short * 0.03
        let box = CGRect(x: Double(width) - margin - textWidth - 2 * padX, y: margin,
                         width: textWidth + 2 * padX, height: fontSize + 2 * padY)

        ctx.saveGState()
        ctx.concatenate(ctx.ctm.inverted()) // device pixels, origin bottom-left, whatever the renderer left behind
        ctx.setBlendMode(.normal)
        ctx.setAlpha(1)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: box.height / 2, cornerHeight: box.height / 2, transform: nil))
        ctx.fillPath()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: box.minX + padX, y: box.midY - (ascent - descent) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
