import Foundation

enum PracticeSkill: String, CaseIterable, Codable {
    case addition, subtraction, multiplication, division, equation, valence, speed, force

    var title: String {
        switch self {
        case .addition: return "덧셈"
        case .subtraction: return "뺄셈"
        case .multiplication: return "곱셈"
        case .division: return "나눗셈"
        case .equation: return "일차방정식"
        case .valence: return "루이스 구조와 원자가 전자"
        case .speed: return "속력"
        case .force: return "힘과 가속도"
        }
    }

    static func related(to event: TutorRecentEvent?) -> Self? {
        guard let event else { return nil }
        let text = PracticeProblem.form(event.transcript)
        switch event.kind {
        case .math:
            if text.contains("x") {
                let sides = text.split(separator: "=", omittingEmptySubsequences: false)
                let linear = #"^[+-]?(?:[0-9]+|(?:[0-9]+\*?)?x)(?:[+-](?:[0-9]+|(?:[0-9]+\*?)?x))*$"#
                return sides.count == 2 && sides.allSatisfy {
                    $0.range(of: linear, options: .regularExpression) != nil
                } ? .equation : nil
            }
            if text.contains("/") || text.contains("나눗셈") { return .division }
            if text.contains("*") || text.contains("곱셈") { return .multiplication }
            if text.contains("-") || text.contains("뺄셈") { return .subtraction }
            if text.contains("+") || text.contains("덧셈") { return .addition }
            return nil
        case .chemistry:
            return .valence
        case .physics:
            let forceTerms = ["힘", "가속도", "질량", "f=ma", "force", "acceleration", "뉴턴"]
            return forceTerms.contains(where: text.contains) ? .force : .speed
        case .text, .unknown:
            return nil
        }
    }
}

enum PracticeGrade: Equatable {
    case invalid, retry, correct, closed
}

struct PracticeProblem: Identifiable, Codable, Equatable {
    let id: UUID
    let skill: PracticeSkill
    let difficulty: Int
    let prompt: String
    let hints: [String]
    let answer: Int
    let unit: String?

    func check(_ input: String) -> PracticeGrade {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 96 else { return .invalid }
        var number = Self.normalized(trimmed)
        if let unit, number.lowercased().hasSuffix(unit.lowercased()) {
            number = String(number.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
        }
        if skill == .equation {
            number = number.replacingOccurrences(of: #"(?i)^x\s*=\s*"#, with: "", options: .regularExpression)
        }
        guard number.utf8.count <= 24,
              number.range(of: #"^[+-]?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let given = Decimal(string: number, locale: Locale(identifier: "en_US_POSIX")) else { return .invalid }
        return given == Decimal(answer) ? .correct : .retry
    }

    static func make(for skill: PracticeSkill, at requestedLevel: Int, excluding earlier: [String]) -> Self {
        let level = min(3, max(1, requestedLevel))
        let banned = Set(earlier.flatMap { text in
            let normalized = form(text)
            return [normalized, String(normalized.split(separator: "=", maxSplits: 1).first ?? "")]
        })
        let molecules = skill == .valence ? Set(earlier.flatMap { text in
            normalized(text).lowercased().split { char in
                char.asciiValue == nil || (!char.isLetter && !char.isNumber)
            }.map(String.init)
        }) : []
        let rolled = Int.random(in: 0..<10_000)
        for offset in 0..<24 {
            let problem = build(skill: skill, level: level, salt: rolled + offset)
            guard !banned.contains(form(problem.prompt)) else { continue }
            if skill == .valence, let molecule = problem.prompt.split(separator: "의", maxSplits: 1).first,
               molecules.contains(form(String(molecule))) { continue }
            return problem
        }
        return build(skill: skill, level: level, salt: rolled + 24)
    }

    fileprivate static func form(_ text: String) -> String {
        normalized(text).lowercased().filter { !$0.isWhitespace }
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
    }

    private static func build(skill: PracticeSkill, level: Int, salt: Int) -> Self {
        func problem(_ prompt: String, _ answer: Int, _ hints: [String], unit: String? = nil) -> Self {
            Self(id: UUID(), skill: skill, difficulty: level, prompt: prompt, hints: hints, answer: answer, unit: unit)
        }
        let span = [7, 50, 250][level - 1]
        let base = [2, 12, 100][level - 1]
        let a = base + salt % span, b = base + (salt / 5) % span
        let groups = 2 + salt % (level + 4), count = 2 + (salt / 7) % (level * 5)
        switch skill {
        case .addition:
            return problem("\(a) + \(b)", a + b, [
                "두 수를 더하는 문제예요.", "큰 수에서 시작해 작은 수를 나누어 더해 보세요.",
                "일의 자리부터 더하고 10이 넘으면 다음 자리로 올려 보세요."
            ])
        case .subtraction:
            let high = max(a, b) + groups, low = min(a, b)
            return problem("\(high) − \(low)", high - low, [
                "큰 수에서 작은 수만큼 빼 보세요.", "작은 수의 십의 자리와 일의 자리를 나눠 보세요.",
                "올바른 차이에 뺀 수를 더하면 처음 수가 나와야 해요."
            ])
        case .multiplication:
            return problem("\(groups) × \(count)", groups * count, [
                "같은 크기의 묶음이 몇 개 있는지 생각해 보세요.", "\(count)를 \(groups)번 더하는 것과 같아요.",
                "\(count)를 십의 자리와 일의 자리로 나눠 각각 곱한 뒤 합쳐 보세요."
            ])
        case .division:
            return problem("\(groups * count) ÷ \(groups)", count, [
                "전체를 같은 크기의 묶음으로 나누는 문제예요.", "묶음의 수는 \(groups)개예요.",
                "떠올린 한 묶음의 수에 \(groups)를 곱해 전체와 같은지 확인해 보세요."
            ])
        case .equation:
            return problem("\(groups)x + \(b) = \(groups * count + b)", count, [
                "x가 있는 항을 한쪽에 남겨 보세요.", "식의 양쪽에서 \(b)를 빼 보세요.",
                "양쪽을 \(groups)으로 나눈 뒤 원래 식에 대입해 보세요."
            ])
        case .valence:
            let sets: [[(String, String, Int)]] = [
                [("H₂O", "수소는 1개, 산소는 6개씩이에요.", 8),
                 ("NH₃", "질소는 5개, 수소는 1개씩이에요.", 8),
                 ("CH₄", "탄소는 4개, 수소는 1개씩이에요.", 8)],
                [("CO₂", "탄소는 4개, 산소는 6개씩이에요.", 16),
                 ("O₂", "산소 원자 하나의 원자가 전자는 6개예요.", 12),
                 ("N₂", "질소 원자 하나의 원자가 전자는 5개예요.", 10)],
                [("HCN", "수소는 1개, 탄소는 4개, 질소는 5개예요.", 10),
                 ("H₂O₂", "수소는 1개, 산소는 6개씩이에요.", 14),
                 ("C₂H₆", "탄소는 4개, 수소는 1개씩이에요.", 14)]
            ]
            let (molecule, valences, total) = sets[level - 1][salt % 3]
            return problem("\(molecule)의 원자가 전자는 모두 몇 개인가요?", total, [
                "화학식에 있는 원소와 원자 수를 찾아보세요.", valences,
                "원자마다 전자 수와 원자 수를 곱해 전부 더해 보세요."
            ], unit: "개")
        case .speed:
            return problem("\(groups)초 동안 \(groups * count)m를 이동했어요. 평균 속력은 몇 m/s인가요?", count, [
                "이동 거리와 걸린 시간을 읽어 보세요.", "속력은 이동 거리를 걸린 시간으로 나눈 값이에요.",
                "속력에 시간을 곱해 주어진 거리와 같은지 확인해 보세요."
            ], unit: "m/s")
        case .force:
            return problem("\(groups)kg 물체의 가속도가 \(count)m/s²예요. 알짜힘은 몇 N인가요?", groups * count, [
                "질량, 가속도, 알짜힘을 이어 주는 법칙을 떠올려 보세요.", "뉴턴의 두 번째 법칙 F = ma를 써 보세요.",
                "질량과 가속도의 수치를 곱해 N으로 표현하세요."
            ], unit: "N")
        }
    }
}

struct PracticeCard: Identifiable, Codable, Equatable {
    let problem: PracticeProblem
    let frame: CGRect
    var hintCount = 0
    var misses = 0
    var solved = false
    var id: UUID { problem.id }
    var visibleHints: [String] { Array(problem.hints.prefix(max(0, hintCount))) }
}

struct PracticeStats: Codable, Equatable {
    var difficulty = 1
    var attempts = 0
    var incorrect = 0
    var cleanStreak = 0
    var hintsUsed: Int? = nil
    var assistedSolutions: Int? = nil
}

/// Long-term counters are separate from the tutor's recent transcript history.
struct PracticeJournal: Codable, Equatable {
    private(set) var current: PracticeCard?
    private(set) var statistics: [PracticeSkill: PracticeStats] = [:]

    mutating func start(skill: PracticeSkill, excluding source: String?, frame: CGRect) {
        let earlier = [source, current?.problem.prompt].compactMap { $0 }
        let level = statistics[skill]?.difficulty ?? 1
        current = PracticeCard(problem: PracticeProblem.make(for: skill, at: level, excluding: earlier), frame: frame)
    }

    mutating func revealHint() -> Bool {
        guard let card = current, !card.solved, card.hintCount < card.problem.hints.count else { return false }
        current?.hintCount += 1
        var stats = statistics[card.problem.skill, default: PracticeStats()]
        stats.hintsUsed = (stats.hintsUsed ?? 0) + 1
        stats.cleanStreak = 0
        statistics[card.problem.skill] = stats
        return true
    }

    mutating func submit(_ response: String) -> PracticeGrade {
        guard var card = current, !card.solved else { return .closed }
        let grade = card.problem.check(response)
        guard grade == .retry || grade == .correct else { return grade }
        let skill = card.problem.skill
        var stats = statistics[skill, default: PracticeStats()]
        stats.attempts += 1
        if grade == .retry {
            if card.misses == 0 { stats.difficulty = max(1, stats.difficulty - 1) }
            card.misses += 1
            stats.incorrect += 1
            stats.cleanStreak = 0
        } else {
            card.solved = true
            if card.misses == 0 && card.hintCount == 0 {
                stats.cleanStreak += 1
            } else {
                stats.cleanStreak = 0
                stats.assistedSolutions = (stats.assistedSolutions ?? 0) + 1
            }
            if stats.cleanStreak == 2 {
                stats.difficulty = min(3, stats.difficulty + 1)
                stats.cleanStreak = 0
            }
        }
        current = card
        statistics[skill] = stats
        return grade
    }
}
