import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The platform value `claimInstall` sends from an Apple device.
let claimPlatformIOS = "ios"

/// The prefix the web funnel's success screen writes before the claim token
/// (`apps/dashboard/src/runner/clipboard.ts`).
let funnelClipboardMarker = "rovenue-funnel:"

/// The device context a deferred funnel claim carries. The façade fills it so
/// every caller — Swift, the RN module, the Flutter plugin — sends the same
/// values: the server compares the locale's primary subtag against the one the
/// universal-link open recorded (Safari's `Accept-Language`), and an empty
/// locale switches that guard off. macOS is not a claim platform (the server
/// accepts ios|android), so a macOS build sends "ios" with an empty screen.
enum ClaimDeviceContext {
    /// `params` with every empty field filled from this device.
    static func fill(_ params: ClaimInstallParams) async -> ClaimInstallParams {
        let screen = params.screenDims.isEmpty ? await screenDims() : params.screenDims
        return ClaimInstallParams(
            platform: params.platform.isEmpty ? claimPlatformIOS : params.platform,
            locale: params.locale.isEmpty ? locale() : params.locale,
            timezone: params.timezone.isEmpty ? TimeZone.current.identifier : params.timezone,
            screenDims: screen,
            deviceModel: (params.deviceModel?.isEmpty ?? true) ? model() : params.deviceModel,
            installReferrer: params.installReferrer
        )
    }

    /// Nothing supplied: the whole context comes from the device.
    static let empty = ClaimInstallParams(
        platform: claimPlatformIOS, locale: "", timezone: "", screenDims: "",
        deviceModel: nil, installReferrer: nil
    )

    /// The language Safari puts first in `Accept-Language` — the value the
    /// universal-link open stored — as a BCP-47 tag.
    private static func locale() -> String {
        (Locale.preferredLanguages.first ?? Locale.current.identifier)
            .replacingOccurrences(of: "_", with: "-")
    }

    /// Logical bounds × scale, the value Safari reports as
    /// `screen × devicePixelRatio` on the universal-link landing. Not
    /// `nativeBounds`: on downsampled panels (iPhone 12/13 mini) and under
    /// Display Zoom the physical pixels differ from what Safari sees, and the
    /// server's fingerprint match compares the two.
    private static func screenDims() async -> String {
        #if canImport(UIKit) && !os(watchOS)
        let size: CGSize? = await MainActor.run {
            guard let screen = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first?.screen else { return nil }
            return CGSize(
                width: screen.bounds.width * screen.scale,
                height: screen.bounds.height * screen.scale
            )
        }
        guard let size else { return "" }
        // Rounded, not truncated: Safari rounds `screen × devicePixelRatio`,
        // and `Int(2079.999)` would be 2079 against Safari's 2080.
        return "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
        #else
        return ""
        #endif
    }

    /// The hardware identifier (`iPhone17,1`); the simulator reports the
    /// device it simulates.
    private static func model() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The pasteboard read behind `claimFromClipboard`.
enum FunnelClipboard {
    /// The token after the marker, or nil when the pasteboard holds anything else.
    static func token() async -> String? {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        let raw: String? = await MainActor.run { UIPasteboard.general.string }
        guard let s = raw, s.hasPrefix(funnelClipboardMarker) else { return nil }
        let token = String(s.dropFirst(funnelClipboardMarker.count))
        return token.isEmpty ? nil : token
        #else
        return nil
        #endif
    }

    /// Clears the pasteboard only while it still holds our marker, so a
    /// claimed token is not re-claimed or leaked and nothing else is touched.
    static func clearMarker() async {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        await MainActor.run {
            if UIPasteboard.general.string?.hasPrefix(funnelClipboardMarker) == true {
                UIPasteboard.general.string = ""
            }
        }
        #endif
    }
}
