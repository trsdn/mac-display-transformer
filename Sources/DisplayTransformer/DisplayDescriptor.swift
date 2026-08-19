import AppKit
import CoreGraphics
import TransformerCore

struct DisplayDescriptor: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let identity: PersistentDisplayIdentity

    var label: String {
        "\(name) — \(pixelWidth)×\(pixelHeight) — ID \(id)"
    }
}

@MainActor
enum DisplayCatalog {
    static func connectedDisplays() -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else {
                return nil
            }

            let currentMode = CGDisplayCopyDisplayMode(displayID)
            let nativeMode =
                (CGDisplayCopyAllDisplayModes(displayID, nil)
                    as? [CGDisplayMode])?
                    .max {
                        ($0.pixelWidth * $0.pixelHeight)
                            < ($1.pixelWidth * $1.pixelHeight)
                    }
            let nativeWidth = nativeMode?.pixelWidth
                ?? currentMode?.pixelWidth
                ?? CGDisplayPixelsWide(displayID)
            let nativeHeight = nativeMode?.pixelHeight
                ?? currentMode?.pixelHeight
                ?? CGDisplayPixelsHigh(displayID)
            return DisplayDescriptor(
                id: displayID,
                name: screen.localizedName,
                pixelWidth: CGDisplayPixelsWide(displayID),
                pixelHeight: CGDisplayPixelsHigh(displayID),
                identity: PersistentDisplayIdentity(
                    vendorID: CGDisplayVendorNumber(displayID),
                    productID: CGDisplayModelNumber(displayID),
                    serialNumber: CGDisplaySerialNumber(displayID),
                    localizedName: screen.localizedName,
                    nativePixelWidth: nativeWidth,
                    nativePixelHeight: nativeHeight
                )
            )
        }
        .sorted {
            if $0.name == $1.name {
                return $0.id < $1.id
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func screen(withID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    static func resolve(
        _ identity: PersistentDisplayIdentity?,
        among displays: [DisplayDescriptor]
    ) -> DisplayDescriptor? {
        guard let identity,
              let index = DisplayIdentityMatcher.uniqueMatch(
                for: identity,
                among: displays.map(\.identity)
              ) else {
            return nil
        }
        return displays[index]
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(number.uint32Value)
    }
}
