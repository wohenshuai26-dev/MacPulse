import Foundation

/// Apple Silicon CPU die temperature from the HID "PMU tdie*" sensors (°C).
func cpuDieTemperatures() -> (avg: Double?, max: Double?) {
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

/// Speed of the fastest fan and its maximum (RPM); nil on fanless Macs.
func fastestFan() -> (rpm: Double, max: Double)? {
    var actual = [Double](repeating: 0, count: 4)
    var maximum = [Double](repeating: 0, count: 4)
    let n = Int(MPReadFans(&actual, &maximum, 4))
    guard n > 0, let i = actual.prefix(n).indices.max(by: { actual[$0] < actual[$1] }) else { return nil }
    return (actual[i], maximum[i])
}
