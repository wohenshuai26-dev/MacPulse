import AppIntents
import Foundation

extension Notification.Name {
    static let macPulseOpenDashboard = Notification.Name("MacPulseOpenDashboard")
}

/// Tapping a MacPulse control opens the app's dashboard window.
/// Compiled into both the app and the controls extension; with `openAppWhenRun`
/// the system runs `perform()` inside the app process.
struct OpenDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "打開 MacPulse"
    static let description = IntentDescription("顯示 MacPulse 系統監測面板")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .macPulseOpenDashboard, object: nil)
        return .result()
    }
}
