import Foundation
#if SPEAKEASY_SPARKLE
import Sparkle
#endif

/// Checks the signed appcast for new releases when the app is built with
/// Sparkle (`SPEAKEASY_SPARKLE_PUBLIC_KEY`); otherwise it is inert and the
/// menu hides "Check for Updates…".
@MainActor
final class SoftwareUpdater {
    #if SPEAKEASY_SPARKLE
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

    var isAvailable: Bool {
        #if SPEAKEASY_SPARKLE
        return Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        #else
        return false
        #endif
    }

    func checkForUpdates() {
        #if SPEAKEASY_SPARKLE
        controller.checkForUpdates(nil)
        #endif
    }
}
