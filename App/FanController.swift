import Foundation
import ServiceManagement

/// Installs the privileged fan helper (a launchd daemon inside the app bundle)
/// and talks to it over XPC. Nothing connects to the helper until the user
/// switches the fan to manual.
@MainActor
final class FanController: ObservableObject {
    static let shared = FanController()

    enum HelperState: Equatable {
        case notInstalled, needsApproval, ready
        case unavailable(String)
    }

    @Published private(set) var helperState: HelperState = .notInstalled
    @Published private(set) var floor: Double = 0
    @Published var errorMessage: String?

    private let daemon = SMAppService.daemon(plistName: FanHelper.plistName)
    private var connection: NSXPCConnection?

    private init() { refreshState() }

    func refreshState() {
        switch daemon.status {
        case .enabled: helperState = .ready
        case .requiresApproval: helperState = .needsApproval
        // A daemon that was never registered often reports .notFound rather than .notRegistered.
        case .notRegistered, .notFound: helperState = .notInstalled
        @unknown default: helperState = .unavailable("無法使用風扇控制")
        }
    }

    /// Registers the helper; macOS then asks the user to allow it in Login Items.
    func install() {
        do {
            try daemon.register()
            errorMessage = nil
        } catch {
            errorMessage = "安裝失敗：\(error.localizedDescription)"
        }
        refreshState()
        if helperState == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Manual mode at `rpm` (the helper raises it to at least the takeover speed).
    func setManual(rpm: Double) {
        guard helperState == .ready else { return }
        proxy()?.setManual(rpm: rpm) { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                self?.fetchFloor()
            }
        }
    }

    func setAutomatic() {
        guard connection != nil else { return }
        proxy()?.setAutomatic { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                self?.floor = 0
            }
        }
    }

    private func fetchFloor() {
        proxy()?.floor { [weak self] value in
            Task { @MainActor in self?.floor = value }
        }
    }

    private func proxy() -> FanHelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: FanHelper.label, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            c.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = "無法連線到風扇控制幫手"
                self?.connection?.invalidate()
                self?.connection = nil
                self?.refreshState()
            }
        } as? FanHelperProtocol
    }
}
