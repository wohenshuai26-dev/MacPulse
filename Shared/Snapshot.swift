import Foundation

/// One sample of system stats, written by the app and read by the Control Center controls.
struct Snapshot: Codable, Sendable, Equatable {
    var date: Date
    /// Average CPU die temperature (°C), nil if no sensor could be read.
    var cpuTemp: Double?
    /// Hottest CPU die sensor (°C).
    var cpuTempMax: Double?
    /// Total CPU usage, 0...1.
    var cpuUsage: Double
    var memUsed: UInt64
    var memTotal: UInt64
    /// Fastest fan's speed and its maximum (RPM); nil on fanless Macs.
    var fanRPM: Double? = nil
    var fanMax: Double? = nil

    var memFraction: Double { memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal) }

    /// Data older than this is treated as stale (app not running).
    static let staleAfter: TimeInterval = 90
    var isStale: Bool { Date().timeIntervalSince(date) > Self.staleAfter }

    static let preview = Snapshot(date: .now, cpuTemp: 52, cpuTempMax: 58, cpuUsage: 0.18,
                                  memUsed: 9 << 30, memTotal: 16 << 30, fanRPM: 2400, fanMax: 6500)
    static let unavailable = Snapshot(date: .distantPast, cpuTemp: nil, cpuTempMax: nil, cpuUsage: 0,
                                      memUsed: 0, memTotal: 0)

    // MARK: Formatting

    var tempText: String {
        guard !isStale, let t = cpuTemp else { return "—" }
        return "\(Int(t.rounded()))°C"
    }
    var usageText: String {
        isStale ? "—" : "\(Int((cpuUsage * 100).rounded()))%"
    }
    var memText: String {
        guard !isStale, memTotal > 0 else { return "—" }
        return String(format: "%.1f / %.0f GB", Self.gb(memUsed), Self.gb(memTotal))
    }
    var memPercentText: String {
        guard !isStale, memTotal > 0 else { return "—" }
        return "\(Int((memFraction * 100).rounded()))%"
    }
    var fanText: String {
        guard !isStale, let rpm = fanRPM else { return "—" }
        return "\(Int(rpm.rounded()))"
    }
    var fanFraction: Double {
        guard let rpm = fanRPM, let max = fanMax, max > 0 else { return 0 }
        return min(rpm / max, 1)
    }
    static func gb(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }

    enum Level { case normal, warm, hot }
    var tempLevel: Level {
        guard !isStale, let t = cpuTemp else { return .normal }
        return t >= 85 ? .hot : (t >= 70 ? .warm : .normal)
    }
}

/// Shared storage in the App Group container (a small JSON file).
enum SnapshotStore {
    /// Set at build time from MP_APP_GROUP (Config/Base.xcconfig) via Info.plist.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "MPAppGroup") as? String ?? ""

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("snapshot.json")
    }

    static func write(_ s: Snapshot) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> Snapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
