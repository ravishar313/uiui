import Foundation
import XCTest
@testable import UIUI

final class NotchMosaicTests: XCTestCase {
    func testPhysicalCameraStaysFixedWhenNotchExpands() throws {
        let collapsed = NotchMosaicGeometry(size: CGSize(width: 368, height: 49),
                                             hasCamera: true, cameraWidth: 220, cameraHeight: 38)
        let expanded = NotchMosaicGeometry(size: CGSize(width: 368, height: 164),
                                            hasCamera: true, cameraWidth: 220, cameraHeight: 38)
        let camera = try XCTUnwrap(collapsed.cameraRect)
        XCTAssertEqual(camera, CGRect(x: 74, y: 0, width: 220, height: 38))
        XCTAssertEqual(expanded.cameraRect, camera)
        XCTAssertFalse(expanded.allows(CGRect(x: 120, y: 30, width: 3, height: 3)))
        XCTAssertTrue(expanded.allows(CGRect(x: 120, y: 41, width: 3, height: 3)))
    }

    func testMovedTilesCannotEnterCameraOrItsAntialiasingGutter() throws {
        for size in [CGSize(width: 320, height: 42), CGSize(width: 368, height: 65),
                     CGSize(width: 520, height: 180)] {
            let geometry = NotchMosaicGeometry(size: size, hasCamera: true,
                                                cameraWidth: 220, cameraHeight: 38)
            let exclusion = try XCTUnwrap(geometry.cameraRect).insetBy(dx: -0.75, dy: -0.75)
            var visible = 0
            for row in 0..<geometry.rows {
                for column in 0..<geometry.columns {
                    for offset in [CGSize.zero, CGSize(width: 0.42, height: -0.42),
                                   CGSize(width: -17, height: 6), CGSize(width: 70, height: 32)] {
                        guard let tile = geometry.tileRect(column: column, row: row, offset: offset) else { continue }
                        visible += 1
                        XCTAssertTrue(geometry.bounds.contains(tile))
                        XCTAssertFalse(exclusion.intersects(tile), "Movement cannot bypass physical exclusion")
                    }
                }
            }
            XCTAssertGreaterThan(visible, 0, "Safe screen wings must remain drawable")
        }
    }

    func testNoCameraUsesCenterScreenPixels() {
        let geometry = NotchMosaicGeometry(size: CGSize(width: 368, height: 49),
                                            hasCamera: false, cameraWidth: 220, cameraHeight: 38)
        XCTAssertNil(geometry.cameraRect)
        XCTAssertTrue(geometry.allows(CGRect(x: 180, y: 12, width: 3, height: 3)))
    }

    func testUnknownPhysicalCameraMeasurementFailsDark() {
        let geometry = NotchMosaicGeometry(size: CGSize(width: 368, height: 49),
                                            hasCamera: true, cameraWidth: CGFloat.nan, cameraHeight: 38)
        XCTAssertEqual(geometry.cameraRect, geometry.bounds)
        XCTAssertFalse(geometry.allows(CGRect(x: 20, y: 12, width: 3, height: 3)))
    }

    func testCompactExpandedTranscriptRowIsQuietWithoutDimmingHeaderWings() {
        let expanded = NotchMosaicGeometry(size: CGSize(width: 368, height: 65),
                                            hasCamera: true, cameraWidth: 220, cameraHeight: 38)
        XCTAssertEqual(expanded.readingOpacity(at: CGPoint(x: 40, y: 20)), 1)
        XCTAssertEqual(expanded.readingOpacity(at: CGPoint(x: 184, y: 51)), 0.18, accuracy: 0.001)
        XCTAssertEqual(expanded.readingOpacity(at: CGPoint(x: 184, y: 63)), 1)
        let collapsed = NotchMosaicGeometry(size: CGSize(width: 368, height: 49),
                                             hasCamera: true, cameraWidth: 220, cameraHeight: 38)
        XCTAssertEqual(collapsed.readingOpacity(at: CGPoint(x: 184, y: 45)), 1)
        let noCamera = NotchMosaicGeometry(size: CGSize(width: 368, height: 59),
                                            hasCamera: false, cameraWidth: 0, cameraHeight: 0)
        XCTAssertEqual(noCamera.readingOpacity(at: CGPoint(x: 184, y: 44)), 0.18, accuracy: 0.001)
    }

    func testDenseGridAndWorkBudgetAcrossPanelAndLargePreviewSizes() {
        for size in [CGSize(width: 320, height: 42), CGSize(width: 368, height: 65),
                     CGSize(width: 520, height: 180), CGSize(width: 4_000, height: 2_000),
                     CGSize(width: 16_384, height: 16_384)] {
            let geometry = NotchMosaicGeometry(size: size, hasCamera: false, cameraWidth: 0, cameraHeight: 0)
            XCTAssertLessThanOrEqual(geometry.tileCount, NotchMosaicMetrics.maximumTiles)
            XCTAssertGreaterThan(geometry.tileCount, 0)
        }
        let ordinary = NotchMosaicGeometry(size: CGSize(width: 368, height: 65),
                                            hasCamera: false, cameraWidth: 0, cameraHeight: 0)
        XCTAssertGreaterThan(ordinary.tileCount, 900, "Keep the requested fine, numerous mosaic cells")
        XCTAssertEqual(ordinary.pitch, 4.75)
        XCTAssertEqual(NotchMosaicMetrics.tileSize, 3)
        XCTAssertLessThan(NotchMosaicMetrics.maximumTranslation, 0.5)
    }

    func testInvalidOrTinyLayoutsHaveNoUnsafeTiles() {
        for size in [CGSize.zero, CGSize(width: -1, height: 44),
                     CGSize(width: CGFloat.infinity, height: CGFloat.nan), CGSize(width: 1, height: 1)] {
            let geometry = NotchMosaicGeometry(size: size, hasCamera: true,
                                                cameraWidth: CGFloat.nan, cameraHeight: CGFloat.infinity)
            XCTAssertEqual(geometry.tileCount, 0)
            XCTAssertNil(geometry.tileRect(column: 0, row: 0))
        }
    }

    func testDispatchAndCancelAreCompletelyDarkAtTheirDeadlines() {
        for (phase, deadline) in [(NotchFeedbackPhase.dispatched, 0.46), (.cancelled, 0.26)] {
            let before = NotchMosaicMetrics.progress(phase: phase, elapsed: deadline - 0.01)
            let at = NotchMosaicMetrics.progress(phase: phase, elapsed: deadline)
            XCTAssertGreaterThan(NotchMosaicMetrics.intensity(phase: phase, progress: before), 0)
            XCTAssertEqual(NotchMosaicMetrics.intensity(phase: phase, progress: at), 0)
            XCTAssertFalse(NotchMosaicMetrics.requestsFrames(phase: phase, elapsed: deadline, reduceMotion: false))
            let receiptEnd = NotchMosaicMetrics.progress(phase: phase, elapsed: 0.65)
            XCTAssertEqual(NotchMosaicMetrics.intensity(phase: phase, progress: receiptEnd), 0)
        }
    }

    func testOnlyCaptureAndProcessingContinueFramesAfterArrival() {
        let phases: [NotchFeedbackPhase] = [.idle, .preparing, .recording, .processing, .dispatched,
                                            .success, .needsInput, .cancelled, .message, .copied, .queued]
        for phase in phases {
            XCTAssertEqual(NotchMosaicMetrics.requestsFrames(phase: phase, elapsed: 4, reduceMotion: false),
                           phase == .recording || phase == .processing)
            XCTAssertFalse(NotchMosaicMetrics.requestsFrames(phase: phase, elapsed: 0, reduceMotion: true))
        }
        XCTAssertEqual(NotchMosaicMetrics.frameInterval, 1.0 / 30.0)
        XCTAssertEqual(NotchMosaicMetrics.intensity(phase: .idle, progress: 0), 0)
        XCTAssertGreaterThan(NotchMosaicMetrics.intensity(phase: .copied, progress: 1), 0)
        XCTAssertGreaterThan(NotchMosaicMetrics.intensity(phase: .needsInput, progress: 1), 0)
    }
}
