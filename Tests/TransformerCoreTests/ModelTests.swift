import CoreGraphics
import Foundation
import Testing
@testable import TransformerCore

@Test("Quarter turns swap dimensions before aspect fitting")
func quarterTurnAspectFit() {
    let size = TransformGeometry.orientedSize(
        sourceWidth: 1920,
        sourceHeight: 1080,
        rotation: .degrees90
    )
    let fitted = TransformGeometry.aspectFitRectangle(
        sourceWidth: 1920,
        sourceHeight: 1080,
        targetWidth: 1920,
        targetHeight: 1080,
        rotation: .degrees90
    )

    #expect(size == PixelSize(width: 1080, height: 1920))
    #expect(abs(fitted.x - 656.25) < 0.0001)
    #expect(abs(fitted.y) < 0.0001)
    #expect(abs(fitted.width - 607.5) < 0.0001)
    #expect(abs(fitted.height - 1080) < 0.0001)
}

@Test("Mirrors operate in post-rotation axes")
func mirrorAfterRotation() {
    let source = CGRect(x: 0, y: 0, width: 100, height: 50)
    let target = CGRect(x: 0, y: 0, width: 50, height: 100)

    let rotated = TransformGeometry.affineTransform(
        sourceExtent: source,
        targetBounds: target,
        transform: DisplayTransform(rotation: .degrees90)
    )
    let mirrored = TransformGeometry.affineTransform(
        sourceExtent: source,
        targetBounds: target,
        transform: DisplayTransform(
            rotation: .degrees90,
            mirrorHorizontally: true
        )
    )

    let rotatedOrigin = CGPoint.zero.applying(rotated)
    let mirroredOrigin = CGPoint.zero.applying(mirrored)
    #expect(abs(rotatedOrigin.x) < 0.0001)
    #expect(abs(rotatedOrigin.y - 100) < 0.0001)
    #expect(abs(mirroredOrigin.x - 50) < 0.0001)
    #expect(abs(mirroredOrigin.y - 100) < 0.0001)
    let extent = source.applying(mirrored).standardized
    #expect(abs(extent.minX - target.minX) < 0.0001)
    #expect(abs(extent.minY - target.minY) < 0.0001)
    #expect(abs(extent.width - target.width) < 0.0001)
    #expect(abs(extent.height - target.height) < 0.0001)
}

@Test("Orientation transform keeps only source-sized pixels")
func orientationTransformUsesSourcePixelCount() {
    let source = CGRect(x: 0, y: 0, width: 1920, height: 540)
    let affine = TransformGeometry.orientedAffineTransform(
        sourceExtent: source,
        transform: DisplayTransform(
            rotation: .degrees90,
            mirrorHorizontally: true
        )
    )
    let extent = source.applying(affine).standardized

    #expect(abs(extent.minX) < 0.0001)
    #expect(abs(extent.minY) < 0.0001)
    #expect(abs(extent.width - 540) < 0.0001)
    #expect(abs(extent.height - 1920) < 0.0001)
}

@Test("Transform values survive Codable round trips")
func transformCodableRoundTrip() throws {
    for rotation in DisplayRotation.allCases {
        let original = DisplayTransform(
            rotation: rotation,
            mirrorHorizontally: true,
            mirrorVertically: rotation.rawValue.isMultiple(of: 180)
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(
            DisplayTransform.self,
            from: data
        ) == original)
    }
}

@Test("Display identity prefers exact hardware serial")
func displayIdentityUsesSerial() {
    let stored = identity(serial: 42, name: "Display A")
    let candidates = [
        identity(serial: 7, name: "Display A"),
        identity(serial: 42, name: "Umbenannt")
    ]

    #expect(
        DisplayIdentityMatcher.uniqueMatch(
            for: stored,
            among: candidates
        ) == 1
    )
}

@Test("Display identity fallback must be unique")
func displayFallbackMustBeUnique() {
    let stored = identity(
        vendor: nil,
        product: nil,
        serial: nil,
        name: "Extern",
        width: 1920,
        height: 1080
    )
    let matching = identity(
        vendor: nil,
        product: nil,
        serial: nil,
        name: "extern",
        width: 1080,
        height: 1920
    )

    #expect(
        DisplayIdentityMatcher.uniqueMatch(
            for: stored,
            among: [matching]
        ) == 0
    )
    #expect(
        DisplayIdentityMatcher.uniqueMatch(
            for: stored,
            among: [matching, matching]
        ) == nil
    )
}

@Test("Known conflicting hardware does not use the name fallback")
func displayHardwareConflictFailsClosed() {
    let stored = identity(vendor: 1, product: 2, serial: nil, name: "Extern")
    let candidate = identity(
        vendor: 1,
        product: 3,
        serial: nil,
        name: "Extern"
    )

    #expect(
        DisplayIdentityMatcher.uniqueMatch(
            for: stored,
            among: [candidate]
        ) == nil
    )
}

@Test("A stored serial never downgrades to a weaker match")
func displaySerialDoesNotDowngrade() {
    let stored = identity(serial: 42, name: "Display A")
    let candidate = identity(serial: nil, name: "Display A")

    #expect(
        DisplayIdentityMatcher.uniqueMatch(
            for: stored,
            among: [candidate]
        ) == nil
    )
}

@Test("Settings normalize to exactly three named slots")
func settingsNormalizePresetSlots() {
    let malformed = AppSettings(
        activePresetIndex: 99,
        presets: [PresetSlot(name: "   ")],
        autoStartOutput: true
    )
    let normalized = malformed.normalized()

    #expect(normalized.presets.count == 3)
    #expect(normalized.presets.map(\.name) == [
        "Preset 1", "Preset 2", "Preset 3"
    ])
    #expect(normalized.activePresetIndex == 2)
    #expect(normalized.autoStartOutput)
}

@Test("Complete settings survive persistence codec")
func settingsCodecRoundTrip() throws {
    var settings = AppSettings.defaults
    settings.activePresetIndex = 1
    settings.autoStartOutput = true
    settings.presets[1] = PresetSlot(
        name: "Ausgabe unten",
        configuration: PresetConfiguration(
            source: identity(serial: 11, name: "Quelle"),
            target: identity(serial: 22, name: "Ziel"),
            transform: DisplayTransform(
                rotation: .degrees270,
                mirrorHorizontally: true,
                mirrorVertically: true
            )
        )
    )

    let decoded = try AppSettingsCodec.decode(
        AppSettingsCodec.encode(settings)
    )
    #expect(decoded == settings)
}

private func identity(
    vendor: UInt32? = 10,
    product: UInt32? = 20,
    serial: UInt32?,
    name: String,
    width: Int = 1920,
    height: Int = 1080
) -> PersistentDisplayIdentity {
    PersistentDisplayIdentity(
        vendorID: vendor,
        productID: product,
        serialNumber: serial,
        localizedName: name,
        nativePixelWidth: width,
        nativePixelHeight: height
    )
}
