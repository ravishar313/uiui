import SwiftUI
import XCTest
@testable import UIUI

final class NotchContinuousDrawingTests: XCTestCase {
    func testContinuousStyleClipExcludesPhysicalCameraAndGutterAtEveryPanelHeight() {
        for height: CGFloat in [41, 46, 49, 65, 180] {
            let geometry = NotchMosaicGeometry(size: CGSize(width: 368, height: height),
                                                hasCamera: true, cameraWidth: 220, cameraHeight: 38)
            let path = NotchContinuousDrawing.screenPath(geometry: geometry)
            XCTAssertFalse(path.contains(CGPoint(x: 184, y: 20), eoFill: true))
            XCTAssertFalse(path.contains(CGPoint(x: 73.5, y: 20), eoFill: true))
            XCTAssertTrue(path.contains(CGPoint(x: 40, y: 20), eoFill: true))
            XCTAssertTrue(path.contains(CGPoint(x: 184, y: 40), eoFill: true))
        }
    }

    func testUnknownCameraMeasurementClipsAllContinuousLight() {
        let geometry = NotchMosaicGeometry(size: CGSize(width: 368, height: 65),
                                            hasCamera: true, cameraWidth: 0, cameraHeight: 38)
        let path = NotchContinuousDrawing.screenPath(geometry: geometry)
        for point in [CGPoint(x: 40, y: 20), CGPoint(x: 184, y: 50), CGPoint(x: 330, y: 20)] {
            XCTAssertFalse(path.contains(point, eoFill: true))
        }
    }

    func testNoCameraClipPreservesCenterPixels() {
        let geometry = NotchMosaicGeometry(size: CGSize(width: 360, height: 59),
                                            hasCamera: false, cameraWidth: 0, cameraHeight: 0)
        XCTAssertTrue(NotchContinuousDrawing.screenPath(geometry: geometry)
            .contains(CGPoint(x: 180, y: 15), eoFill: true))
    }

    func testQuietTranscriptStripsCoverSurfaceExactlyOnce() {
        for (camera, height) in [(true, CGFloat(65)), (false, CGFloat(59))] {
            let geometry = NotchMosaicGeometry(size: CGSize(width: 368, height: height),
                                                hasCamera: camera, cameraWidth: 220, cameraHeight: 38)
            let regions = NotchContinuousDrawing.lightRegions(geometry: geometry)
            XCTAssertEqual(regions.count, 3)
            XCTAssertEqual(regions.first?.rect.minY, 0)
            XCTAssertEqual(regions.last?.rect.maxY, height)
            XCTAssertEqual(regions[0].rect.maxY, regions[1].rect.minY)
            XCTAssertEqual(regions[1].rect.maxY, regions[2].rect.minY)
            XCTAssertEqual(regions[1].opacity, 0.18)
            XCTAssertEqual(regions[0].opacity, 1)
            XCTAssertEqual(regions[2].opacity, 1)
            XCTAssertEqual(regions.reduce(0) { $0 + $1.rect.height }, height)
        }
        let collapsed = NotchMosaicGeometry(size: CGSize(width: 316, height: 41),
                                             hasCamera: true, cameraWidth: 220, cameraHeight: 38)
        XCTAssertEqual(NotchContinuousDrawing.lightRegions(geometry: collapsed).count, 1)
        XCTAssertEqual(NotchContinuousDrawing.lightRegions(geometry: collapsed).first?.opacity, 1)
    }
}
