import AppKit
import Foundation
import Network

/// Where to find the printer. The access code lives in the Keychain, not here.
struct PrinterConfig: Codable, Equatable {
    var host: String
    var serial: String
    var name: String
    /// SSDP model code ("N7" for the P2S).
    var modelCode: String

    var modelName: String { PrinterModels.name(for: modelCode, serial: serial) }

    /// An IP address or a hostname (a DNS or Tailscale MagicDNS name), as typed: spaces, a scheme or a
    /// trailing slash pasted along with it are dropped.
    static func normalizedHost(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        while host.hasSuffix("/") { host.removeLast() }
        return host
    }

    /// Discovery only follows a printer to a new address when the saved one is a plain IP address;
    /// a hostname the person chose resolves on its own and is kept.
    var hostIsIPAddress: Bool { IPv4Address(host) != nil || IPv6Address(host) != nil }
}

enum PrinterModels {
    static func name(for code: String, serial: String = "") -> String {
        switch code.uppercased() {
        case "N7": return "P2S"
        case "C11": return "P1P"
        case "C12": return "P1S"
        case "BL-P001": return "X1 Carbon"
        case "BL-P002": return "X1"
        case "C13", "BL-P003": return "X1E"
        case "N1", "A12", "A04": return "A1 mini"
        case "N2S", "A11": return "A1"
        case "O1D": return "H2D"
        case "O1E", "O2D": return "H2D Pro"
        case "O1C", "O1C2": return "H2C"
        case "O1S": return "H2S"
        case "N6": return "X2D"
        case "N9": return "A2L"
        default:
            switch serial.prefix(3) {
            case "22E": return "P2S"
            case "01P": return "P1S"
            case "01S": return "P1P"
            case "00M": return "X1 Carbon"
            case "03W": return "X1E"
            case "039": return "A1"
            case "030": return "A1 mini"
            case "093": return "H2S"
            case "094": return "H2D"
            default: return "Bambu Lab printer"
            }
        }
    }
}

/// Keeps one MQTT session to the printer alive: connects, re-requests a full report, merges the deltas
/// into a status, and reconnects with back-off when the printer drops off the network or the Mac sleeps,
/// and right away when this Mac changes networks (Wi-Fi to tethering, a VPN coming up).
@MainActor
final class PrinterConnection {
    enum Phase: Equatable {
        case idle
        case connecting
        case online
        case offline(String)
        case unauthorized
        case certificate(String)
    }

    /// How the live connection reaches the printer, read from the interface it actually uses.
    struct Route: Equatable {
        var interface: String
        /// Through a tunnel (Tailscale's subnet router, another VPN) rather than this Mac's own network.
        var isTunnel: Bool
        /// The tunnel is Tailscale: this end of the connection has a 100.64.0.0/10 address.
        var isTailscale: Bool

        init?(_ path: NWPath) {
            guard let interface = path.availableInterfaces.first else { return nil }
            self.interface = interface.name
            isTunnel = interface.type == .other || interface.name.hasPrefix("utun")
            if case .hostPort(.ipv4(let address), _)? = path.localEndpoint {
                let bytes = [UInt8](address.rawValue)
                isTailscale = isTunnel && bytes[0] == 100 && bytes[1] & 0xC0 == 64
            } else {
                isTailscale = false
            }
        }

        /// "On LAN", "Remote via Tailscale".
        var summary: String { isTunnel ? "Remote via \(isTailscale ? "Tailscale" : "VPN")" : "On LAN" }
    }

    var onPhase: ((Phase) -> Void)?
    var onRoute: ((Route?) -> Void)?
    var onStatus: ((PrinterStatus, ReportDocument) -> Void)?
    /// Any message from the printer, changed or not.
    var onHeartbeat: (() -> Void)?
    /// A command acknowledgement: command name, success, reason.
    var onAck: ((String, Bool, String?) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhase?(phase) } }
    }
    private(set) var route: Route? {
        didSet { if route != oldValue { onRoute?(route) } }
    }

    private var config: PrinterConfig?
    private var accessCode = ""
    private var insecure = false
    private var client: MQTTClient?
    private var document = ReportDocument()
    private var lastStatus: PrinterStatus?
    private var lastMessage = Date.distantPast
    private var lastPushall = Date.distantPast
    private var attempt = 0
    private var retry: Timer?
    private var watchdog: Timer?
    private var sequence = 0
    private var observers: [NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()
    private var network: NetworkPath?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectSoon(after: 2) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.pathChanged(NetworkPath(path)) }
        }
        pathMonitor.start(queue: .main)
    }

    deinit {
        pathMonitor.cancel()
    }

    func start(_ config: PrinterConfig, accessCode: String, insecure: Bool = false) {
        stop()
        self.config = config
        self.accessCode = accessCode
        self.insecure = insecure
        attempt = 0
        open()
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
    }

    func stop() {
        retry?.invalidate()
        watchdog?.invalidate()
        retry = nil
        watchdog = nil
        closeClient()
        config = nil
        lastStatus = nil
        document.reset()
        route = nil
        phase = .idle
    }

    /// Asks for a full report now (after wake, or when the person clicks refresh).
    func refresh() {
        if phase == .online { requestFullReport() } else if config != nil { reconnectSoon(after: 0) }
    }

    // MARK: - Commands

    func pause() { sendPrint(["command": "pause"]) }
    func resume() { sendPrint(["command": "resume"]) }
    func stopPrint() { sendPrint(["command": "stop"]) }
    func setSpeed(_ level: SpeedLevel) { sendPrint(["command": "print_speed", "param": "\(level.rawValue)"]) }

    func setChamberLight(_ on: Bool) {
        send(["system": ["command": "ledctrl", "led_node": "chamber_light", "led_mode": on ? "on" : "off",
                         "led_on_time": 500, "led_off_time": 500, "loop_times": 0, "interval_time": 0]], key: "system")
    }

    private func sendPrint(_ body: [String: Any]) { send(["print": body], key: "print") }

    private func send(_ message: [String: Any], key: String) {
        guard let config, let client, phase == .online else { return }
        sequence += 1
        var message = message
        if var body = message[key] as? [String: Any] {
            body["sequence_id"] = "\(sequence)"
            message[key] = body
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        client.publish("device/\(config.serial)/request", payload: data)
    }

    // MARK: - Session

    private func open() {
        guard let config else { return }
        closeClient()
        phase = .connecting
        // The watchdog measures silence from here, so it doesn't cut off an attempt that's still connecting.
        lastMessage = Date()
        let client = MQTTClient(.init(host: config.host, password: accessCode, serial: config.serial, insecure: insecure))
        client.onEvent = { [weak self, weak client] event in
            MainActor.assumeIsolated {
                guard let self, let client, client === self.client else { return }
                self.handle(event)
            }
        }
        self.client = client
        client.connect()
    }

    private func closeClient() {
        client?.onEvent = nil
        client?.disconnect()
        client = nil
    }

    private func handle(_ event: MQTTClient.Event) {
        guard let config else { return }
        switch event {
        case .connected(let path):
            route = path.flatMap(Route.init)
            lastMessage = Date()
            client?.subscribe("device/\(config.serial)/report")
            sendRaw(["info": ["sequence_id": "0", "command": "get_version"]])
            requestFullReport()
            // Stay "connecting" until the first report arrives, so a silent broker doesn't look online.
        case .message(_, let payload):
            lastMessage = Date()
            onHeartbeat?()
            guard let json = Self.decode(payload) else { return }
            if let p = json["print"] as? [String: Any], let command = p["command"] as? String,
               command != "push_status", let result = p["result"] as? String {
                onAck?(command, result.lowercased() == "success", p["reason"] as? String)
            }
            guard document.apply(json) else { return }
            guard document.hasFullReport || document.print["gcode_state"] != nil else { return }
            if phase != .online {
                // Back-off resets only once the printer is really talking, not on a CONNACK alone.
                attempt = 0
                phase = .online
            }
            publishStatus()
        case .disconnected(let failure):
            client = nil
            route = nil
            switch failure {
            case .refused(let code) where code == 4 || code == 5:
                // A wrong access code won't fix itself; wait for the person to change it.
                phase = .unauthorized
                return
            case .certificate(let reason):
                // A certificate that doesn't check out won't fix itself either; don't keep sending it the code.
                phase = .certificate(reason)
                return
            case .unreachable(let reason):
                phase = .offline(reason)
            case .timedOut:
                phase = .offline("The printer stopped answering.")
            case .closed, .malformed, .refused:
                phase = .offline("The connection to the printer closed.")
            }
            scheduleReconnect()
        }
    }

    private func publishStatus() {
        var status = ReportParser.status(from: document, hms: HMSCatalog.shared)
        if let last = lastStatus {
            // Keep the timestamp the remaining time was measured at, so the ETA doesn't drift between reports.
            var same = status
            same.updatedAt = last.updatedAt
            if same == last { return }
            if status.remainingMinutes == last.remainingMinutes && status.progress == last.progress && status.state == last.state {
                status.updatedAt = last.updatedAt
            }
        }
        lastStatus = status
        onStatus?(status, document)
    }

    private func requestFullReport() {
        lastPushall = Date()
        sendRaw(["pushing": ["sequence_id": "0", "command": "pushall"]])
    }

    private func sendRaw(_ message: [String: Any]) {
        guard let config, let client, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        client.publish("device/\(config.serial)/request", payload: data)
    }

    private func checkHealth() {
        guard config != nil else { return }
        let silence = Date().timeIntervalSince(lastMessage)
        switch phase {
        case .online:
            if silence > 95 {
                phase = .offline("The printer stopped sending updates.")
                reconnectSoon(after: 0)
            } else if silence > 60 || Date().timeIntervalSince(lastPushall) > 300 {
                requestFullReport()
            }
        case .connecting:
            if client != nil, silence > 25 { reconnectSoon(after: 0) }
        default:
            break
        }
    }

    private func scheduleReconnect() {
        let delays: [TimeInterval] = [2, 4, 8, 15, 30]
        // Without a network there's nothing to back off from; the path monitor reconnects when one appears,
        // and the slowest retry covers a monitor that never says so.
        let delay = network?.isUsable == false ? delays.last! : delays[min(attempt, delays.count - 1)]
        attempt += 1
        // Spread out so two printers behind the same route don't retry in lockstep.
        reconnectSoon(after: delay * .random(in: 0.85...1.15))
    }

    /// What this Mac's network looks like, reduced to what decides whether a connection survives it.
    private struct NetworkPath: Equatable {
        var isUsable: Bool
        var interfaces: Set<String>
        var gateways: Set<String>

        init(_ path: NWPath) {
            isUsable = path.status == .satisfied
            interfaces = Set(path.availableInterfaces.map(\.name))
            gateways = Set(path.gateways.map { "\($0)" })
        }
    }

    private func pathChanged(_ new: NetworkPath) {
        let old = network
        network = new
        guard let old, old != new, config != nil else { return }
        // A rejected access code stays rejected whatever the network; everything else deserves a fresh try,
        // including a certificate that failed on another network (where the address may belong to a stranger).
        guard phase != .unauthorized else { return }
        guard new.isUsable else {
            retry?.invalidate()
            closeClient()
            phase = .offline("This Mac isn't on a network.")
            return
        }
        // A connection that's talking survives an interface coming up (a VPN, a second link); it doesn't
        // survive its network going away or changing underneath it (same Wi-Fi interface, new gateway).
        if phase == .online, old.isUsable, new.interfaces.isSuperset(of: old.interfaces), new.gateways == old.gateways { return }
        attempt = 0
        // Give DHCP and the routes a moment to settle; further changes in that moment push it back.
        reconnectSoon(after: 1.5)
    }

    private func reconnectSoon(after delay: TimeInterval) {
        guard config != nil else { return }
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.open() }
        }
    }

    private func suspend() {
        retry?.invalidate()
        closeClient()
    }

    /// Some firmware sends bytes that aren't valid UTF-8; fall back to Latin-1 rather than drop the report.
    private static func decode(_ data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return json }
        guard let text = String(data: data, encoding: .isoLatin1), let utf8 = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: utf8) as? [String: Any]
    }
}
