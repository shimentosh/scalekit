@preconcurrency import ColorSync
import CoreGraphics
import Foundation
import ScaleKitCore

/// Gives the virtual display the mirroring monitor's own color profile.
///
/// macOS builds the virtual display a generic profile with a ~2.2 tone
/// curve. The monitor's profile while it mirrors can differ (1.96 on an ASUS
/// VG34WQML5A), and WindowServer does not always convert between the two:
/// during some animations and page loads the frame reaches the panel
/// unconverted, so mid-tones briefly look lighter. With identical profiles
/// both paths match.
enum VirtualColorProfile {
    /// The monitor's current profile, from its ColorSync device entry, which
    /// is the file macOS rewrites when the monitor joins the mirror set.
    static func iccData(of displayID: CGDirectDisplayID) -> Data? {
        if let url = profileURL(of: displayID), let data = try? Data(contentsOf: url) { return data }
        return CGDisplayCopyColorSpace(displayID).copyICCData() as Data?
    }

    /// Equal apart from the header's creation date, which macOS rewrites
    /// whenever it regenerates a display profile.
    static func isSame(_ a: Data, _ b: Data) -> Bool {
        let date = 24..<36
        guard a.count == b.count, a.count > date.upperBound else { return a == b }
        return a.prefix(date.lowerBound) == b.prefix(date.lowerBound)
            && a.dropFirst(date.upperBound) == b.dropFirst(date.upperBound)
    }

    /// The user's custom profile for the default mode, else the factory one.
    private static func profileURL(of displayID: CGDirectDisplayID) -> URL? {
        guard let device = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), device)?
                  .takeRetainedValue() as? [String: Any],
              let factory = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any],
              let id = factory[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] as? String
        else { return nil }
        let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any]
        let entry = factory[id] as? [String: Any]
        return (custom?[id] ?? entry?[kColorSyncDeviceProfileURL.takeUnretainedValue() as String]) as? URL
    }

    /// Saves `icc` and makes it the virtual display's custom profile for
    /// this user. Returns the ColorSync device ID to clear it again later.
    static func assign(_ icc: Data, to virtualID: CGDirectDisplayID, fileName: String, directory: URL) -> CFUUID? {
        guard let device = CGDisplayCreateUUIDFromDisplayID(virtualID)?.takeRetainedValue() else { return nil }
        let url = directory.appendingPathComponent(fileName).appendingPathExtension("icc")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try icc.write(to: url, options: .atomic)
        } catch {
            Log.virtual.error("Could not save the monitor's color profile: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // A setting left over from a crashed run would make this a no-op that
        // WindowServer never hears about, so clear it first.
        _ = setCustomProfile(kCFNull, device: device)
        guard setCustomProfile(url as CFURL, device: device) else {
            Log.virtual.notice("ColorSync did not accept the monitor's profile for the virtual display")
            return nil
        }
        return device
    }

    /// Removes the custom profile so no setting is left behind for the
    /// virtual display's identity.
    static func clear(device: CFUUID) {
        _ = setCustomProfile(kCFNull, device: device)
    }

    private static func setCustomProfile(_ profile: CFTypeRef, device: CFUUID) -> Bool {
        let info = [
            kColorSyncDeviceDefaultProfileID.takeUnretainedValue(): profile,
            kColorSyncProfileUserScope.takeUnretainedValue(): kCFPreferencesCurrentUser,
        ] as CFDictionary
        return ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), device, info)
    }
}
