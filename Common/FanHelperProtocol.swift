import Foundation

/// XPC interface of the privileged fan helper (runs as root via launchd).
@objc protocol FanHelperProtocol {
    /// Manual mode at `rpm`. The helper never goes below the fan speed that was running
    /// when it took over from automatic control. Replies with an error message or nil.
    func setManual(rpm: Double, reply: @escaping (String?) -> Void)
    /// Back to automatic (system) control.
    func setAutomatic(reply: @escaping (String?) -> Void)
    /// Lowest target currently allowed (RPM), 0 when in automatic mode.
    func floor(reply: @escaping (Double) -> Void)
}

enum FanHelper {
    /// e.g. "com.yourname.MacPulse", from MP_BUNDLE_PREFIX via Info.plist.
    static let appIdentifier = (Bundle.main.object(forInfoDictionaryKey: "MPBundlePrefix") as? String ?? "MacPulse") + ".MacPulse"
    /// launchd label and Mach service name of the helper.
    static let label = appIdentifier + ".FanHelper"
    static let plistName = label + ".plist"
}
