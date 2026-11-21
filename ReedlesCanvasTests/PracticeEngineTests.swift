import Foundation
import XCTest
#if !os(Linux)
@testable import ReedlesCanvas
#endif

final class PracticeEngineTests: XCTestCase {
    private let frame = CGRect(x: 120, y: 70, width: 290, height: 112)

    func testPracticeFollowsTheSubjectAndOperationInTheRecentWork() {
        func previous(_ kind: TutorSubject, _ transcript: String) -> TutorRecentEvent {
            TutorRecentEvent(revision: 8, kind: kind, transcript: transcript, feedback: "")
        }
        XCTAssertEqual(PracticeSkill.related(to: previous(.math, "2 + 2 = 4")), .addition)
        XCTAssertEqual(PracticeSkill.related(to: previous(.math, "3x − 5 = 10")), .equation)
        XCTAssertEqual(PracticeSkill.related(to: previous(.math, "６＝２ｘ")), .equation)
        XCTAssertNil(PracticeSkill.related(to: previous(.math, "x² + 1 = 10")))
        XCTAssertEqual(PracticeSkill.related(to: previous(.math, "24 / 6 = 4")), .division)
        XCTAssertEqual(PracticeSkill.related(to: previous(.chemistry, "H₂O Lewis structure")), .valence)
        XCTAssertEqual(PracticeSkill.related(to: previous(.physics, "F = ma, 힘 벡터")), .force)
        XCTAssertEqual(PracticeSkill.related(to: previous(.physics, "10 m / 2 s = 5 m/s")), .speed)
        XCTAssertNil(PracticeSkill.related(to: previous(.unknown, "x = 4")))
    }

    func testHintsUnlockOneAtATimeAndAnswerGradingIsExact() throws {
        var journal = PracticeJournal()
        journal.start(skill: .force, excluding: nil, frame: frame)
        let problem = try XCTUnwrap(journal.current?.problem)
        XCTAssertTrue(journal.current?.visibleHints.isEmpty == true)
        XCTAssertTrue(journal.revealHint())
        XCTAssertEqual(journal.current?.visibleHints.count, 1)
        XCTAssertEqual(journal.submit("answer = 4"), .invalid)
        XCTAssertEqual(journal.submit("\(problem.answer + 1) N"), .retry)
        XCTAssertEqual(journal.submit("\(problem.answer) kg"), .invalid)
        XCTAssertEqual(journal.submit("\(problem.answer).0 N"), .correct)
        XCTAssertEqual(journal.current?.solved, true)
        XCTAssertFalse(journal.revealHint())
        XCTAssertEqual(journal.submit(String(problem.answer)), .closed)
        XCTAssertEqual(journal.statistics[.force]?.attempts, 2)
        XCTAssertEqual(journal.statistics[.force]?.incorrect, 1)
        XCTAssertEqual(journal.statistics[.force]?.hintsUsed, 1)
        XCTAssertEqual(journal.statistics[.force]?.assistedSolutions, 1)
    }

    func testLocalizedAnswersAndPreviouslySeenMolecules() {
        let equation = PracticeProblem(id: UUID(), skill: .equation, difficulty: 1, prompt: "x + 12 = 0",
                                       hints: [], answer: -12, unit: nil)
        XCTAssertEqual(equation.check("ｘ＝−１２．００"), .correct)
        XCTAssertEqual(equation.check("ｘ＝−１３"), .retry)
        XCTAssertEqual(equation.check("−１ ２"), .invalid)
        let molecule = PracticeProblem.make(for: .valence, at: 1, excluding: ["H₂O의 루이스 구조", "NH₃의 원자가 전자"])
        XCTAssertTrue(molecule.prompt.hasPrefix("CH₄"))
    }

    func testHintsResetPromotionAndRepeatedRetriesLowerDifficultyOncePerProblem() throws {
        var journal = PracticeJournal()
        func solve() throws {
            journal.start(skill: .addition, excluding: nil, frame: frame)
            let problem = try XCTUnwrap(journal.current?.problem)
            XCTAssertEqual(journal.submit(String(problem.answer)), .correct)
        }

        try solve()
        journal.start(skill: .addition, excluding: nil, frame: frame)
        XCTAssertTrue(journal.revealHint())
        try solve()
        XCTAssertEqual(journal.statistics[.addition]?.difficulty, 1)
        XCTAssertEqual(journal.statistics[.addition]?.hintsUsed, 1)
        for _ in 0..<3 { try solve() }
        XCTAssertEqual(journal.statistics[.addition]?.difficulty, 3)

        journal.start(skill: .addition, excluding: nil, frame: frame)
        let problem = try XCTUnwrap(journal.current?.problem)
        for _ in 0..<2 { XCTAssertEqual(journal.submit(String(problem.answer + 1)), .retry) }
        XCTAssertEqual(journal.statistics[.addition]?.difficulty, 2)
        XCTAssertEqual(journal.statistics[.addition]?.incorrect, 2)
        XCTAssertEqual(journal.submit(String(problem.answer)), .correct)
        XCTAssertEqual(journal.statistics[.addition]?.assistedSolutions, 1)
    }

    func testPriorStatisticsDecodeWithOptionalNewCounters() throws {
        let data = Data(#"{"difficulty":2,"attempts":7,"incorrect":2,"cleanStreak":1}"#.utf8)
        let stats = try JSONDecoder().decode(PracticeStats.self, from: data)
        XCTAssertEqual(stats.difficulty, 2)
        XCTAssertEqual(stats.attempts, 7)
        XCTAssertNil(stats.hintsUsed)
        XCTAssertNil(stats.assistedSolutions)
    }

    func testDifficultyAdaptsAndLearningStateRoundTripsWithoutOriginalInk() throws {
        var journal = PracticeJournal()
        var prompts = Set<String>()
        for _ in 0..<2 {
            journal.start(skill: .addition, excluding: "2 + 2 = 4", frame: frame)
            let problem = try XCTUnwrap(journal.current?.problem)
            XCTAssertNotEqual(problem.prompt, "2 + 2")
            prompts.insert(problem.prompt)
            XCTAssertEqual(journal.submit(String(problem.answer)), .correct)
        }
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(journal.statistics[.addition]?.difficulty, 2)
        journal.start(skill: .addition, excluding: nil, frame: frame)
        let next = try XCTUnwrap(journal.current?.problem)
        XCTAssertEqual(next.difficulty, 2)
        XCTAssertEqual(journal.submit(String(next.answer + 1)), .retry)
        XCTAssertEqual(journal.statistics[.addition]?.difficulty, 1)
        let saved = try JSONEncoder().encode(journal)
        XCTAssertEqual(try JSONDecoder().decode(PracticeJournal.self, from: saved), journal)
        XCTAssertEqual(journal.current?.frame, frame)
        XCTAssertNil(journal.statistics[.valence])
    }

    func testGeneratedProblemsHaveSolutionsAcrossAllLevels() throws {
        for skill in PracticeSkill.allCases {
            for level in 1...3 {
                let problem = PracticeProblem.make(for: skill, at: level, excluding: [])
                XCTAssertEqual(problem.difficulty, level)
                XCTAssertEqual(problem.hints.count, 3)
                XCTAssertEqual(problem.check(String(problem.answer)), .correct)
                XCTAssertEqual(problem.check(String(problem.answer + 1)), .retry)
                XCTAssertEqual(problem.check(String(repeating: "9", count: 50)), .invalid)
                XCTAssertFalse(problem.hints.contains(String(problem.answer)))
            }
        }
    }
}

#if os(Linux)
@main
private enum PracticeTestRunner {
    static func main() {
        XCTMain([testCase([
            ("testPracticeFollowsTheSubjectAndOperationInTheRecentWork", PracticeEngineTests.testPracticeFollowsTheSubjectAndOperationInTheRecentWork),
            ("testHintsUnlockOneAtATimeAndAnswerGradingIsExact", PracticeEngineTests.testHintsUnlockOneAtATimeAndAnswerGradingIsExact),
            ("testLocalizedAnswersAndPreviouslySeenMolecules", PracticeEngineTests.testLocalizedAnswersAndPreviouslySeenMolecules),
            ("testHintsResetPromotionAndRepeatedRetriesLowerDifficultyOncePerProblem", PracticeEngineTests.testHintsResetPromotionAndRepeatedRetriesLowerDifficultyOncePerProblem),
            ("testPriorStatisticsDecodeWithOptionalNewCounters", PracticeEngineTests.testPriorStatisticsDecodeWithOptionalNewCounters),
            ("testDifficultyAdaptsAndLearningStateRoundTripsWithoutOriginalInk", PracticeEngineTests.testDifficultyAdaptsAndLearningStateRoundTripsWithoutOriginalInk),
            ("testGeneratedProblemsHaveSolutionsAcrossAllLevels", PracticeEngineTests.testGeneratedProblemsHaveSolutionsAcrossAllLevels),
        ])])
    }
}
#endif
