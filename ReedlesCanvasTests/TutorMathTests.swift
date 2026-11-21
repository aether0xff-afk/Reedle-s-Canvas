import Foundation
import XCTest
#if !os(Linux)
@testable import ReedlesCanvas
#endif

final class TutorMathTests: XCTestCase {
    private func layout(_ formula: TutorFormula, width: CGFloat = 224) -> TutorFormulaLayout? {
        TutorFormulaLayout(formula, pointSize: 20, maximumWidth: width) { text, font in
            .init(width: CGFloat(text.count) * font * 0.5, ascent: font * 0.75, descent: font * 0.25)
        }
    }

    func testFractionsAndRadicalsHaveStableVectorGeometry() throws {
        let formula = TutorFormula(#"\frac{x^2+1}{\sqrt{a_1}}"#)
        let result = try XCTUnwrap(layout(formula))
        XCTAssertEqual(result, layout(TutorFormula(#"\frac{x^2+1}{\sqrt{a_1}}"#)))
        XCTAssertEqual(formula.plainText, "(x²+1)/(√(a₁))")
        let strokes = result.marks.compactMap { mark -> [CGPoint]? in
            if case .stroke(let points, _) = mark { return points }
            return nil
        }
        XCTAssertEqual(strokes.map(\.count), [2, 5])
        let bar = try XCTUnwrap(strokes.first?.first)
        let x = try XCTUnwrap(baseline(of: "x", in: result))
        let a = try XCTUnwrap(baseline(of: "a", in: result))
        XCTAssertLessThan(x.y, bar.y)
        XCTAssertGreaterThan(a.y, bar.y)
        for point in strokes.joined() {
            XCTAssertTrue(CGRect(origin: .zero, size: result.size).contains(point))
        }
    }

    func testUpperAndLowerScriptsShareTheSameAttachmentWithoutTakingTheNextTerm() throws {
        let formula = TutorFormula("S_4^{2-}+x^12-3")
        XCTAssertEqual(formula.plainText, "S₄²⁻+x¹²-3")
        let result = try XCTUnwrap(layout(formula))
        let base = try XCTUnwrap(baseline(of: "S", in: result))
        let upper = try XCTUnwrap(baseline(of: "2", in: result))
        let lower = try XCTUnwrap(baseline(of: "4", in: result))
        XCTAssertEqual(upper.x, lower.x)
        XCTAssertGreaterThan(upper.x, base.x)
        XCTAssertLessThan(upper.y, base.y)
        XCTAssertGreaterThan(lower.y, base.y)
        XCTAssertEqual(try XCTUnwrap(baseline(of: "3", in: result)).y, base.y)
    }

    func testWrappingKeepsFractionsTogetherAndHonorsExplicitNewlines() throws {
        let row = #"\frac{12}{34}+\frac{56}{78}"#
        let result = try XCTUnwrap(layout(TutorFormula(row + "\n3"), width: 32))
        XCTAssertLessThanOrEqual(result.size.width, 32)
        let top = try ["12", "34", "56", "78", "3"].map { try XCTUnwrap(baseline(of: $0, in: result)?.y) }
        XCTAssertEqual(top, top.sorted())
        XCTAssertEqual(Set(top).count, 5)
    }

    func testUnsupportedCommandsAndIncompleteGroupsRemainReadable() {
        let invalid = TutorFormula(#"\frac{2} + \unknown{4} + \pi값"#)
        XCTAssertFalse(invalid.isStructured)
        XCTAssertEqual(invalid.plainText, #"\frac{2} + \unknown{4} + π값"#)
        XCTAssertNil(layout(TutorFormula(#"\frac{1234567890}{2}"#), width: 32))
    }

    private func baseline(of text: String, in layout: TutorFormulaLayout) -> CGPoint? {
        for mark in layout.marks {
            if case .text(let content, _, let point) = mark, content == text { return point }
        }
        return nil
    }
}

#if os(Linux)
@main
private enum TutorMathTestRunner {
    static func main() {
        XCTMain([testCase([
            ("testFractionsAndRadicalsHaveStableVectorGeometry", TutorMathTests.testFractionsAndRadicalsHaveStableVectorGeometry),
            ("testUpperAndLowerScriptsShareTheSameAttachmentWithoutTakingTheNextTerm", TutorMathTests.testUpperAndLowerScriptsShareTheSameAttachmentWithoutTakingTheNextTerm),
            ("testWrappingKeepsFractionsTogetherAndHonorsExplicitNewlines", TutorMathTests.testWrappingKeepsFractionsTogetherAndHonorsExplicitNewlines),
            ("testUnsupportedCommandsAndIncompleteGroupsRemainReadable", TutorMathTests.testUnsupportedCommandsAndIncompleteGroupsRemainReadable)
        ])])
    }
}
#endif
