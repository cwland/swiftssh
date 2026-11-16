import Foundation
import LocalAuthentication
import AppCore

/// Face ID / Touch ID, falling back to the device passcode, for the app lock.
enum DeviceAuthenticator {
    /// Asks once. A device with no passcode can't authenticate at all: `.unavailable`.
    /// Not main-actor isolated: the context never leaves this call.
    static func authenticate(reason: String) async -> AppLockAuthentication {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable("This device has no passcode, so SwiftSSH can't lock. Set a passcode in Settings to use the app lock.")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                ? .success : .failed("SwiftSSH is still locked. Tap Unlock to try again.")
        } catch {
            return .failed("SwiftSSH is still locked. Tap Unlock to try again.")
        }
    }

    /// The name of what unlocks this device, for the Settings switch and the lock screen.
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }
}
