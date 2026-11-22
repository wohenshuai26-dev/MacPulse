import Combine
import Darwin
import Foundation
import os
import WidgetKit

/// Samples CPU temperature, CPU usage and memory on a timer, publishes the result
/// for the app UI and writes it to the App Group so the Control Center controls can show it.
@MainActor
final class Sampler: ObservableObject {
    static let shared = Sampler()

    @Published private(set) var snapshot: Snapshot = .unavailable
    @Published var interval: TimeInterval {
        didSet {
            UserDefaults.standard.set(interval, forKey: "sampleInterval")
            scheduleTimer()
        }
    }

    private let host = mach_host_self()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MacPulse", category: "sampler")
    private var timer: Timer?
    private var prevTicks: [UInt32]?
    private var lastPushed: [String]?
    private var lastPushDate = Date.distantPast

    private init() {
        let saved = UserDefaults.standard.double(forKey: "sampleInterval")
        interval = saved > 0 ? saved : 2
    }

    func start() {
        _ = readCPUUsage() // baseline for the first delta
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sample() }
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func sample() {
        let temps = readTemperatures()
        let fan = readFans()
        let s = Snapshot(date: .now,
                         cpuTemp: temps.avg,
                         cpuTempMax: temps.max,
                         cpuUsage: readCPUUsage(),
                         memUsed: readMemory().used,
                         memTotal: ProcessInfo.processInfo.physicalMemory,
                         fanRPM: fan?.rpm,
                         fanMax: fan?.max)
        snapshot = s
        SnapshotStore.write(s)
        pushToControlCenterIfNeeded(s)
    }

    /// Ask Control Center to re-read the controls only when a displayed value changed
    /// (or every 30 s so the "last updated" time never gets stale).
    private func pushToControlCenterIfNeeded(_ s: Snapshot) {
        let gbText = "\(Int(Snapshot.gb(s.memUsed).rounded()))"
        let fanStep = s.fanRPM.map { "\(Int(($0 / 100).rounded()))" } ?? "-"
        let shown = [s.tempText, s.usageText, gbText, fanStep]
        let changed = lastPushed.map { $0 != shown } ?? true
        guard changed || Date().timeIntervalSince(lastPushDate) > 30 else { return }
        lastPushed = shown
        lastPushDate = .now
        ControlCenter.shared.reloadAllControls()
    }

    // MARK: - Sensors

    /// Apple Silicon CPU die temperature from the HID "PMU tdie*" sensors.
    private func readTemperatures() -> (avg: Double?, max: Double?) {
        guard let raw = MPCopyTemperatureSensors() as? [String: Double] else { return (nil, nil) }
        let valid: (Double) -> Bool = { $0 > 0 && $0 < 130 }
        // M2 and later: "PMU tdie1…n"; M1: "pACC/eACC MTR Temp Sensor…"
        var values = raw.filter { $0.key.hasPrefix("PMU tdie") }.map(\.value).filter(valid)
        if values.isEmpty {
            values = raw.filter { $0.key.contains("MTR Temp Sensor") }.map(\.value).filter(valid)
        }
        if values.isEmpty {
            values = raw.filter { $0.key.contains("tdie") }.map(\.value).filter(valid)
        }
        guard !values.isEmpty else { return (nil, nil) }
        return (values.reduce(0, +) / Double(values.count), values.max())
    }

    /// Fastest fan (RPM) and its maximum, read from the SMC; nil on fanless Macs.
    private func readFans() -> (rpm: Double, max: Double)? {
        var actual = [Double](repeating: 0, count: 4)
        var maximum = [Double](repeating: 0, count: 4)
        let n = Int(MPReadFans(&actual, &maximum, 4))
        guard n > 0, let i = actual.prefix(n).indices.max(by: { actual[$0] < actual[$1] }) else { return nil }
        return (actual[i], maximum[i])
    }

    /// Whole-system CPU usage (0...1) from tick deltas since the previous call.
    private func readCPUUsage() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return snapshot.cpuUsage }
        let t = info.cpu_ticks
        let ticks = [t.0, t.1, t.2, t.3] // user, system, idle, nice
        defer { prevTicks = ticks }
        guard let prev = prevTicks else { return 0 }
        let d = zip(ticks, prev).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        return total > 0 ? (d[0] + d[1] + d[3]) / total : 0
    }

    /// "Memory Used" as Activity Monitor defines it: app memory + wired + compressed.
    private func readMemory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            log.error("host_statistics64 failed: \(kr)")
            return (0, total)
        }
        let page = UInt64(getpagesize())
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }
}
