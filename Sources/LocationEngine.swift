import Foundation

/// Runs every job on one dedicated thread. idevice adapter handles must stay on the thread that made them.
final class WorkerThread: Thread {
    private let cond = NSCondition()
    private var jobs: [() -> Void] = []

    override init() {
        super.init()
        name = "idevice-worker"
        start()
    }

    func async(_ job: @escaping () -> Void) {
        cond.lock()
        jobs.append(job)
        cond.signal()
        cond.unlock()
    }

    override func main() {
        while true {
            cond.lock()
            while jobs.isEmpty { cond.wait() }
            let job = jobs.removeFirst()
            cond.unlock()
            job()
        }
    }
}

struct EngineError: Error, CustomStringConvertible {
    let description: String
}

/// Talks to the phone's own developer services through the LocalDevVPN loopback tunnel
/// and holds a DVT LocationSimulation session open.
final class LocationEngine {
    static let pairingURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist")
    }()

    private let worker = WorkerThread()
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var remoteServer: OpaquePointer?
    private var locSim: OpaquePointer?

    var deviceIPs = ["10.7.0.1", "10.7.0.2"]

    static var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: pairingURL.path)
    }

    func set(lat: Double, lon: Double, done: @escaping (Result<Void, EngineError>) -> Void) {
        worker.async {
            let result = self.withSession { location_simulation_set($0, lat, lon) }
            DispatchQueue.main.async { done(result) }
        }
    }

    func clear(done: @escaping (Result<Void, EngineError>) -> Void) {
        worker.async {
            var result: Result<Void, EngineError> = .success(())
            if let sim = self.locSim, let err = location_simulation_clear(sim) {
                result = .failure(Self.take(err))
            }
            self.disconnect()
            DispatchQueue.main.async { done(result) }
        }
    }

    // MARK: - worker thread only

    /// Runs `call` on the open session. On failure, reconnects once and retries.
    private func withSession(_ call: (OpaquePointer) -> UnsafeMutablePointer<IdeviceFfiError>?) -> Result<Void, EngineError> {
        for attempt in 0..<2 {
            if locSim == nil {
                if case .failure(let e) = connect() { return .failure(e) }
            }
            guard let sim = locSim else { break }
            if let err = call(sim) {
                let e = Self.take(err)
                disconnect()
                if attempt == 1 { return .failure(e) }
            } else {
                return .success(())
            }
        }
        return .failure(EngineError(description: "Сессия не открылась"))
    }

    private func connect() -> Result<Void, EngineError> {
        guard Self.hasPairingFile else {
            return .failure(EngineError(description: "Нет pairing-файла. Импортируйте его в настройках."))
        }
        var lastError = EngineError(description: "Нет связи с устройством")
        for ip in deviceIPs {
            switch connect(ip: ip) {
            case .success: return .success(())
            case .failure(let e): lastError = EngineError(description: "\(ip): \(e.description)")
            }
        }
        return .failure(lastError)
    }

    private func connect(ip: String) -> Result<Void, EngineError> {
        disconnect()

        var pairing: OpaquePointer?
        if let err = idevice_pairing_file_read(Self.pairingURL.path, &pairing) {
            return .failure(Self.take(err, "Pairing-файл"))
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(62078).bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)

        // The provider consumes the pairing file on success.
        var provider: OpaquePointer?
        let provErr = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                idevice_tcp_provider_new($0, pairing, "GPSSpoof", &provider)
            }
        }
        if let err = provErr {
            idevice_pairing_file_free(pairing)
            return .failure(Self.take(err, "TCP"))
        }

        var proxy: OpaquePointer?
        let proxyErr = core_device_proxy_connect(provider, &proxy)
        idevice_provider_free(provider)
        if let err = proxyErr { return .failure(Self.take(err, "CoreDeviceProxy (включён LocalDevVPN?)")) }

        var rsdPort: UInt16 = 0
        if let err = core_device_proxy_get_server_rsd_port(proxy, &rsdPort) {
            core_device_proxy_free(proxy)
            return .failure(Self.take(err, "RSD порт"))
        }

        // Consumes the proxy.
        var adp: OpaquePointer?
        if let err = core_device_proxy_create_tcp_adapter(proxy, &adp) {
            return .failure(Self.take(err, "Туннель"))
        }
        adapter = adp

        // The handshake consumes the stream.
        var stream: OpaquePointer?
        if let err = adapter_connect(adp, rsdPort, &stream) {
            disconnect()
            return .failure(Self.take(err, "RSD"))
        }
        var hs: OpaquePointer?
        if let err = rsd_handshake_new(stream, &hs) {
            disconnect()
            return .failure(Self.take(err, "RSD handshake"))
        }
        handshake = hs

        var rs: OpaquePointer?
        if let err = remote_server_connect_rsd(adp, hs, &rs) {
            disconnect()
            return .failure(Self.take(err, "DVT (включён режим разработчика?)"))
        }
        remoteServer = rs

        var sim: OpaquePointer?
        if let err = location_simulation_new(rs, &sim) {
            disconnect()
            return .failure(Self.take(err, "LocationSimulation"))
        }
        locSim = sim
        return .success(())
    }

    private func disconnect() {
        if let p = locSim { location_simulation_free(p) }
        if let p = remoteServer { remote_server_free(p) }
        if let p = handshake { rsd_handshake_free(p) }
        if let p = adapter { adapter_free(p) }
        locSim = nil; remoteServer = nil; handshake = nil; adapter = nil
    }

    private static func take(_ err: UnsafeMutablePointer<IdeviceFfiError>, _ step: String = "") -> EngineError {
        let msg = err.pointee.message.map { String(cString: $0) } ?? "?"
        let code = err.pointee.code
        idevice_error_free(err)
        return EngineError(description: (step.isEmpty ? "" : step + ": ") + "\(msg) [\(code)]")
    }
}
