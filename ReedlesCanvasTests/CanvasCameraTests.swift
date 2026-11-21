import Foundation
import XCTest
#if !os(Linux)
@testable import ReedlesCanvas
#endif

final class CanvasCameraTests: XCTestCase {
    func testWorldAndScreenRoundTripAtDistantOrigins() {
        let point = CGPoint(x: 724.125, y: 491.75)
        let origins = [CGPoint.zero, CGPoint(x: -1_000_000_000.25, y: 1_000_000_000.75)]
        for origin in origins {
            for scale: CGFloat in [0.5, 1.375, 4] {
                let camera = CanvasCamera(origin: origin, scale: scale)
                XCTAssertEqual(camera.screenPoint(for: origin), .zero)
                assertPoint(camera.screenPoint(for: camera.worldPoint(at: point)), equals: point)
                let world = CGPoint(x: origin.x - 53.25, y: origin.y + 84.5)
                assertPoint(camera.worldPoint(at: camera.screenPoint(for: world)), equals: world)
            }
        }
    }

    func testPanTranslatesContentByScreenDistanceAtNonUnitScale() {
        let camera = CanvasCamera(origin: CGPoint(x: 320, y: -180), scale: 2.5)
        let stroke = CGPoint(x: 360, y: -100)
        XCTAssertEqual(camera.screenPoint(for: stroke), CGPoint(x: 100, y: 200))
        let panned = camera.panned(by: CGPoint(x: 75, y: -50))
        XCTAssertEqual(panned.screenPoint(for: stroke), CGPoint(x: 175, y: 150))
        XCTAssertEqual(panned.panned(by: CGPoint(x: -75, y: 50)), camera)
    }

    func testZoomKeepsAnchorFixedAcrossRepeatedClampedZooms() {
        let initial = CanvasCamera(origin: CGPoint(x: 1_000_000_000.25, y: -10.75), scale: 1.75)
        let screenAnchor = CGPoint(x: 317.125, y: 27.75)
        let ink = initial.worldPoint(at: screenAnchor)
        var camera = initial
        for _ in 0..<100 {
            camera = camera.zoomed(to: 100, around: screenAnchor)
            XCTAssertEqual(camera.scale, CanvasCamera.maximumScale)
            assertPoint(camera.screenPoint(for: ink), equals: screenAnchor)
            camera = camera.zoomed(to: 0.1, around: screenAnchor)
            XCTAssertEqual(camera.scale, CanvasCamera.minimumScale)
            assertPoint(camera.screenPoint(for: ink), equals: screenAnchor)
        }
        let restored = camera.zoomed(to: initial.scale, around: screenAnchor)
        assertPoint(restored.origin, equals: initial.origin)
    }

    func testScrollOffsetsRetainNegativeInsetAndNativeBounceScale() {
        let offset = CGPoint(x: -42, y: 131.25)
        let camera = CanvasCamera(contentOffset: offset, scale: 4.2)
        assertPoint(camera.origin, equals: CGPoint(x: -10, y: 31.25))
        assertPoint(camera.contentOffset, equals: offset)
        assertPoint(camera.screenPoint(for: .zero), equals: CGPoint(x: 42, y: -131.25))
    }

    func testInvalidScaleCannotCorruptAnExistingCamera() {
        let camera = CanvasCamera(origin: CGPoint(x: 10, y: -20), scale: 2)
        for scale: CGFloat in [0, -1, .nan, .infinity] {
            XCTAssertEqual(camera.zoomed(to: scale, around: .zero), camera)
            XCTAssertEqual(CanvasCamera(contentOffset: camera.contentOffset, scale: scale).scale, 1)
        }
    }

    func testSlidingPencilSurfaceKeepsTheCameraAndInkAlignedAtDistantPositions() {
        let size = CGSize(width: 1180, height: 820)
        var window = CanvasWindow()
        for offset: CGFloat in [0, -40_000, 1_000_000.5, -1_000_000.25] {
            let camera = CanvasCamera(origin: CGPoint(x: offset, y: -offset / 2), scale: 1.75)
            let viewport = CanvasWindow.viewport(camera: camera, size: size)
            window.centerIfNeeded(around: viewport)
            let localOffset = window.localOffset(for: camera)
            let restored = window.worldCamera(offset: localOffset, scale: camera.scale)
            assertPoint(restored.origin, equals: camera.origin)
            XCTAssertGreaterThan(localOffset.x, 0)
            XCTAssertLessThan(localOffset.x + size.width, CanvasWindow.side * camera.scale)
            let reference = CGPoint(x: 42.5, y: 372.75)
            assertPoint(restored.screenPoint(for: camera.worldPoint(at: reference)), equals: reference)
            let origin = window.origin
            window.centerIfNeeded(around: viewport.offsetBy(dx: 100, dy: -100))
            XCTAssertEqual(window.origin, origin)
        }
    }

    func testAnimatedZoomKeepsInkUnderTapAcrossFramesInBothDirections() {
        let start = CanvasCamera(origin: CGPoint(x: -421.25, y: 1_587.5), scale: 1.5)
        let tap = CGPoint(x: 137.5, y: 493.25)
        let ink = start.worldPoint(at: tap)
        for target: CGFloat in [0.5, 4] {
            let transition = CanvasZoomTransition(start: start, targetScale: target, anchor: tap)
            var previous = start.scale
            for frame in 1...60 {
                let camera = transition.camera(at: CGFloat(frame) / 60)
                assertPoint(camera.screenPoint(for: ink), equals: tap)
                if target > start.scale {
                    XCTAssertGreaterThan(camera.scale, previous)
                } else {
                    XCTAssertLessThan(camera.scale, previous)
                }
                // Detect a snap even if its final scale and anchor are correct.
                XCTAssertLessThan(abs(camera.scale - previous), abs(target - start.scale) / 5)
                previous = camera.scale
            }
            XCTAssertEqual(previous, target, accuracy: 0.000001)
            // Over equal time intervals, zoom ramps up and settles before stopping.
            let startChange = abs(transition.camera(at: 0.1).scale - start.scale)
            let middleChange = abs(transition.camera(at: 0.55).scale - transition.camera(at: 0.45).scale)
            let endChange = abs(target - transition.camera(at: 0.9).scale)
            XCTAssertLessThan(startChange, middleChange)
            XCTAssertLessThan(endChange, middleChange)
        }
    }

    func testAnimationClampsTimeAndRequestedScaleAtBothEnds() {
        let start = CanvasCamera(origin: CGPoint(x: 710, y: -480), scale: 1.25)
        let tap = CGPoint(x: 91, y: 375)
        for requested: CGFloat in [0.01, 50] {
            let transition = CanvasZoomTransition(start: start, targetScale: requested, anchor: tap)
            for time: CGFloat in [-0.1, 0] {
                assertPoint(transition.camera(at: time).origin, equals: start.origin)
                XCTAssertEqual(transition.camera(at: time).scale, start.scale, accuracy: 0.000001)
            }
            let end = start.zoomed(to: requested, around: tap)
            for time: CGFloat in [1, 1.1] {
                assertPoint(transition.camera(at: time).origin, equals: end.origin)
                XCTAssertEqual(transition.camera(at: time).scale, end.scale, accuracy: 0.000001)
            }
        }
    }

    func testInterruptingZoomCanStartAtDisplayedFrameWithANewAnchor() {
        let start = CanvasCamera(origin: CGPoint(x: 630, y: 270), scale: 1)
        let first = CanvasZoomTransition(start: start, targetScale: 2, anchor: CGPoint(x: 120, y: 80))
        let displayed = first.camera(at: 0.4)
        XCTAssertGreaterThan(displayed.scale, 1)
        XCTAssertLessThan(displayed.scale, 2)
        let secondTap = CGPoint(x: 380, y: 110)
        let ink = displayed.worldPoint(at: secondTap)
        let second = CanvasZoomTransition(start: displayed, targetScale: 1, anchor: secondTap)
        assertPoint(second.camera(at: 0).origin, equals: displayed.origin)
        XCTAssertEqual(second.camera(at: 0).scale, displayed.scale, accuracy: 0.000001)
        for time: CGFloat in [0.1, 0.5, 1] {
            assertPoint(second.camera(at: time).screenPoint(for: ink), equals: secondTap)
        }
    }

    private func assertPoint(_ actual: CGPoint, equals expected: CGPoint,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.00001, file: file, line: line)
    }
}

#if os(Linux)
@main
private enum CameraTestRunner {
    static func main() {
        XCTMain([testCase([
            ("testWorldAndScreenRoundTripAtDistantOrigins", CanvasCameraTests.testWorldAndScreenRoundTripAtDistantOrigins),
            ("testPanTranslatesContentByScreenDistanceAtNonUnitScale", CanvasCameraTests.testPanTranslatesContentByScreenDistanceAtNonUnitScale),
            ("testZoomKeepsAnchorFixedAcrossRepeatedClampedZooms", CanvasCameraTests.testZoomKeepsAnchorFixedAcrossRepeatedClampedZooms),
            ("testScrollOffsetsRetainNegativeInsetAndNativeBounceScale", CanvasCameraTests.testScrollOffsetsRetainNegativeInsetAndNativeBounceScale),
            ("testInvalidScaleCannotCorruptAnExistingCamera", CanvasCameraTests.testInvalidScaleCannotCorruptAnExistingCamera),
            ("testSlidingPencilSurfaceKeepsTheCameraAndInkAlignedAtDistantPositions", CanvasCameraTests.testSlidingPencilSurfaceKeepsTheCameraAndInkAlignedAtDistantPositions),
            ("testAnimatedZoomKeepsInkUnderTapAcrossFramesInBothDirections", CanvasCameraTests.testAnimatedZoomKeepsInkUnderTapAcrossFramesInBothDirections),
            ("testAnimationClampsTimeAndRequestedScaleAtBothEnds", CanvasCameraTests.testAnimationClampsTimeAndRequestedScaleAtBothEnds),
            ("testInterruptingZoomCanStartAtDisplayedFrameWithANewAnchor", CanvasCameraTests.testInterruptingZoomCanStartAtDisplayedFrameWithANewAnchor)
        ])])
    }
}
#endif
