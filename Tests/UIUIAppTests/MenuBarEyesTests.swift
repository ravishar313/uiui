import AppKit
import XCTest
@testable import UIUI

@MainActor
final class MenuBarEyesTests: XCTestCase {
    func testEyeImagesAreCachedTemplatesAtMenuBarSize() {
        for state in StatusMenuController.EyeState.allCases {
            let image = StatusMenuController.eyeImage(state)
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            XCTAssertTrue(image === StatusMenuController.eyeImage(state), "Built once")
        }
    }

    func testEyeStatesDiffer() throws {
        var seen = Set<Data>()
        for state in StatusMenuController.EyeState.allCases {
            seen.insert(try XCTUnwrap(StatusMenuController.eyeImage(state).tiffRepresentation))
        }
        XCTAssertEqual(seen.count, 3)
    }

    /// Set UIUI_EYES_OUT to a directory to write the images for a visual check.
    func testWritesImagesWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["UIUI_EYES_OUT"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for state in StatusMenuController.EyeState.allCases {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 144, pixelsHigh: 144, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 144, height: 144).fill()
            StatusMenuController.eyeImage(state).draw(in: NSRect(x: 0, y: 0, width: 144, height: 144))
            NSGraphicsContext.restoreGraphicsState()
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(state).png"))
        }
    }
}
