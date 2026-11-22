// MacPulseFanHelper — privileged launchd daemon that sets fan speed through the SMC.
//
// Safety rules:
//  • only accepts XPC connections from MacPulse signed by the same team
//  • never targets less than the fan speed that was running when it took over
//  • hands control back to the system when CPU die temperature reaches 90 °C
//  • hands control back when MacPulse disconnects (quit or crash) or the helper stops
import Foundation
import os
import Security

let log = Logger(subsystem: FanHelper.label, category: "helper")
let handBackTemperature = 90.0

final class FanService: NSObject, FanHelperProtocol, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "fan-helper")
    private var connections = 0
    /// Fan speed when manual control started; 0 while automatic.
    private var takeoverFloor = 0.0
    private var watchdog: DispatchSourceTimer?
    private var idleExit: DispatchWorkItem?

    // MARK: XPC

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            self?.queue.async { self?.connectionClosed() }
        }
        queue.sync {
            connections += 1
            idleExit?.cancel()
        }
        connection.resume()
        return true
    }

    private func connectionClosed() {
        connections -= 1
        guard connections <= 0 else { return }
        connections = 0
        restoreAutomatic(reason: "MacPulse disconnected")
        scheduleIdleExit()
    }

    func setManual(rpm: Double, reply: @escaping (String?) -> Void) {
        queue.async {
            if self.takeoverFloor == 0 {
                self.takeoverFloor = (fastestFan()?.rpm ?? 0).rounded()
            }
            let target = max(rpm, self.takeoverFloor)
            guard MPSetFanManual(target) == 0 else {
                self.restoreAutomatic(reason: "SMC write failed")
                reply("無法設定風扇轉速（SMC 寫入失敗）")
                return
            }
            log.notice("manual \(Int(target), privacy: .public) RPM (floor \(Int(self.takeoverFloor), privacy: .public))")
            self.startWatchdog()
            reply(nil)
        }
    }

    func setAutomatic(reply: @escaping (String?) -> Void) {
        queue.async {
            self.restoreAutomatic(reason: "requested")
            reply(nil)
        }
    }

    func floor(reply: @escaping (Double) -> Void) {
        queue.async { reply(self.takeoverFloor) }
    }

    // MARK: Safety

    func restoreAutomatic(reason: String) {
        watchdog?.cancel()
        watchdog = nil
        takeoverFloor = 0
        if MPSetFanAuto() == 0 {
            log.notice("automatic control restored (\(reason, privacy: .public))")
        } else {
            log.error("could not restore automatic control (\(reason, privacy: .public))")
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let t = cpuDieTemperatures().avg, t >= handBackTemperature {
                self.restoreAutomatic(reason: "CPU \(Int(t))°C")
            } else if MPReadFanMode() == 0 {
                // Something else returned the fan to automatic.
                self.watchdog?.cancel()
                self.watchdog = nil
                self.takeoverFloor = 0
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func scheduleIdleExit() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connections == 0, self.takeoverFloor == 0 else { return }
            exit(0) // launchd starts us again on the next connection
        }
        idleExit = work
        queue.asyncAfter(deadline: .now() + 30, execute: work)
    }
}

/// Team ID from this helper's own code signature.
func ownTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
}

// MARK: - main

guard let team = ownTeamIdentifier() else {
    log.error("helper is not signed with a team; refusing to run")
    exit(1)
}

let service = FanService()
// A previous helper may have died while in manual mode.
if MPReadFanMode() == 1 { service.restoreAutomatic(reason: "helper start") }

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        service.restoreAutomatic(reason: "signal \(sig)")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

let listener = NSXPCListener(machServiceName: FanHelper.label)
listener.setConnectionCodeSigningRequirement(
    "identifier \"\(FanHelper.appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
)
listener.delegate = service
listener.resume()
log.notice("fan helper ready for \(FanHelper.appIdentifier, privacy: .public)")
dispatchMain()
