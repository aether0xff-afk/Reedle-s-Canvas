import Foundation

struct TutorFormula: Equatable {
    indirect enum Element: Equatable {
        case text(String)
        case fraction(numerator: [Element], denominator: [Element])
        case radical([Element])
        case scripts(base: Element, upper: [Element]?, lower: [Element]?)

        var plainText: String {
            switch self {
            case .text(let text): return text
            case .fraction(let numerator, let denominator):
                return "(\(Self.join(numerator)))/(\(Self.join(denominator)))"
            case .radical(let value): return "√(\(Self.join(value)))"
            case .scripts(let base, let upper, let lower):
                return base.plainText + Self.scriptText(lower, raised: false) + Self.scriptText(upper, raised: true)
            }
        }

        private static func join(_ elements: [Element]) -> String {
            elements.map(\.plainText).joined()
        }

        private static let upperCharacters = Dictionary(uniqueKeysWithValues: zip("0123456789+-−", "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁻"))
        private static let lowerCharacters = Dictionary(uniqueKeysWithValues: zip("0123456789+-−", "₀₁₂₃₄₅₆₇₈₉₊₋₋"))

        private static func scriptText(_ elements: [Element]?, raised: Bool) -> String {
            guard let elements else { return "" }
            let text = join(elements)
            let table = raised ? upperCharacters : lowerCharacters
            let formatted = text.compactMap { table[$0] }
            if formatted.count == text.count { return String(formatted) }
            return (raised ? "^" : "_") + "(\(text))"
        }
    }

    let rows: [[Element]]

    init(_ source: String) {
        rows = source.split(separator: "\n", omittingEmptySubsequences: false).map { row in
            Parser(row).parse()
        }
    }

    var isStructured: Bool {
        rows.joined().contains { element in
            if case .text = element { return false }
            return true
        }
    }

    var plainText: String { rows.map { $0.map(\.plainText).joined() }.joined(separator: "\n") }

    private struct Parser {
        private static let symbols = [
            "times": "×", "cdot": "·", "div": "÷", "pm": "±", "sqrt": "√", "pi": "π",
            "theta": "θ", "alpha": "α", "beta": "β", "gamma": "γ", "Delta": "Δ", "mu": "μ", "Omega": "Ω",
            "ge": "≥", "geq": "≥", "le": "≤", "leq": "≤", "neq": "≠", "approx": "≈",
            "infty": "∞", "rightarrow": "→", "to": "→"
        ]
        private static let breaks = Set("+-−×·÷*/=≈≤≥≠→,:;()[]")
        private static let escaped = Set("{}^_\\")
        private static let maximumDepth = 6
        private let source: [Character]
        private let closingBraces: [Int: Int]

        init(_ row: Substring) {
            source = Array(row)
            var opens: [Int] = []
            var pairs: [Int: Int] = [:]
            var escapesNext = false
            for (index, char) in source.enumerated() {
                if escapesNext {
                    escapesNext = false
                } else if char == "\\" {
                    escapesNext = true
                } else if char == "{" {
                    opens.append(index)
                } else if char == "}", let opening = opens.popLast() {
                    pairs[opening] = index
                }
            }
            closingBraces = pairs
        }

        func parse() -> [Element] { elements(in: source.indices, depth: 0) }

        private func elements(in bounds: Range<Int>, depth: Int) -> [Element] {
            var elements: [Element] = []
            var word = ""
            var index = bounds.lowerBound
            while index < bounds.upperBound {
                let element = atom(at: &index, end: bounds.upperBound, depth: depth)
                let scripted = canHaveScripts(element) ? scripts(on: element, at: &index, end: bounds.upperBound, depth: depth) : element
                if case .text(let text) = scripted, !text.contains(where: { $0.isWhitespace || Self.breaks.contains($0) }) {
                    word += text
                } else {
                    if !word.isEmpty {
                        elements.append(.text(word))
                        word = ""
                    }
                    elements.append(scripted)
                }
            }
            if !word.isEmpty { elements.append(.text(word)) }
            return elements
        }

        private func canHaveScripts(_ element: Element) -> Bool {
            if case .text(let text) = element, let last = text.last {
                return !last.isWhitespace && !"{^_".contains(last)
            }
            return true
        }

        private func atom(at index: inout Int, end: Int, depth: Int) -> Element {
            let char = source[index]
            index += 1
            guard char == "\\", index < end else { return .text(String(char)) }
            if Self.escaped.contains(source[index]) {
                let literal = source[index]
                index += 1
                return .text(String(literal))
            }
            let start = index
            while index < end, source[index].asciiValue != nil, source[index].isLetter { index += 1 }
            let name = String(source[start..<index])
            if depth < Self.maximumDepth, let first = group(at: index, end: end) {
                if name == "frac", let second = group(at: first.upperBound + 1, end: end) {
                    index = second.upperBound + 1
                    return .fraction(numerator: elements(in: first, depth: depth + 1),
                                     denominator: elements(in: second, depth: depth + 1))
                }
                if name == "sqrt" {
                    index = first.upperBound + 1
                    return .radical(elements(in: first, depth: depth + 1))
                }
            }
            return .text(Self.symbols[name] ?? "\\" + name)
        }

        private func group(at index: Int, end: Int) -> Range<Int>? {
            guard let close = closingBraces[index], close < end, close > index + 1 else { return nil }
            return (index + 1)..<close
        }

        private func scripts(on base: Element, at index: inout Int, end: Int, depth: Int) -> Element {
            guard depth < Self.maximumDepth else { return base }
            var upper: [Element]?
            var lower: [Element]?
            while index + 1 < end {
                let marker = source[index]
                guard (marker == "^" && upper == nil) || (marker == "_" && lower == nil) else { break }
                var operand = index + 1
                guard let value = script(at: &operand, end: end, depth: depth + 1) else { break }
                if marker == "^" { upper = value } else { lower = value }
                index = operand
            }
            if upper == nil, lower == nil { return base }
            return .scripts(base: base, upper: upper, lower: lower)
        }

        private func script(at index: inout Int, end: Int, depth: Int) -> [Element]? {
            if let bounds = group(at: index, end: end) {
                index = bounds.upperBound + 1
                return elements(in: bounds, depth: depth)
            }
            let char = source[index]
            var cursor = index + ("+-−".contains(char) ? 1 : 0)
            let start = cursor
            while cursor < end, let ascii = source[cursor].asciiValue, (48...57).contains(ascii) { cursor += 1 }
            if cursor > start {
                let value = String(source[index..<cursor])
                index = cursor
                return [.text(value)]
            }
            guard char.isLetter || char == "\\" else { return nil }
            return [atom(at: &index, end: end, depth: depth)]
        }
    }
}

struct TutorFormulaLayout: Equatable {
    struct Metrics {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    enum Mark: Equatable {
        case text(String, fontSize: CGFloat, baseline: CGPoint)
        case stroke([CGPoint], width: CGFloat)

        func offset(x: CGFloat, y: CGFloat) -> Self {
            func point(_ source: CGPoint) -> CGPoint { CGPoint(x: source.x + x, y: source.y + y) }
            switch self {
            case .text(let text, let size, let baseline): return .text(text, fontSize: size, baseline: point(baseline))
            case .stroke(let points, let width): return .stroke(points.map(point), width: width)
            }
        }
    }

    let size: CGSize
    let marks: [Mark]

    init?(_ formula: TutorFormula, pointSize: CGFloat, maximumWidth: CGFloat,
          measure: @escaping (String, CGFloat) -> Metrics) {
        let builder = Builder(baseSize: pointSize, measure: measure)
        let lineMetrics = measure("0", pointSize)
        var width: CGFloat = 0
        var height: CGFloat = 0
        var marks: [Mark] = []
        for row in formula.rows {
            var line = Box()
            func appendLine() {
                let baseline = height + max(line.ascent, lineMetrics.ascent)
                width = max(width, line.width)
                marks.append(contentsOf: line.marks.map { $0.offset(x: 0, y: baseline) })
                height = baseline + max(line.descent, lineMetrics.descent) + pointSize * 0.16
            }
            for element in row {
                let box = builder.box(element, at: pointSize)
                guard box.width <= maximumWidth else { return nil }
                if line.width + box.width > maximumWidth {
                    appendLine()
                    line = Box()
                }
                if line.width == 0, box.marks.isEmpty { continue }
                line.append(box)
            }
            appendLine()
        }
        size = CGSize(width: width, height: height)
        self.marks = marks
    }

    private struct Box {
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var marks: [Mark] = []

        mutating func append(_ box: Box) {
            marks.append(contentsOf: box.marks.map { $0.offset(x: width, y: 0) })
            width += box.width
            ascent = max(ascent, box.ascent)
            descent = max(descent, box.descent)
        }
    }

    private struct Builder {
        let baseSize: CGFloat
        let measure: (String, CGFloat) -> Metrics

        func box(_ element: TutorFormula.Element, at size: CGFloat) -> Box {
            switch element {
            case .text(let text):
                let metrics = measure(text, size)
                let marks: [Mark] = text.allSatisfy(\.isWhitespace) ? [] : [.text(text, fontSize: size, baseline: .zero)]
                return Box(width: metrics.width, ascent: metrics.ascent, descent: metrics.descent, marks: marks)
            case .fraction(let numerator, let denominator):
                let font = max(baseSize * 0.55, size * 0.80)
                let upper = row(numerator, at: font)
                let lower = row(denominator, at: font)
                let width = max(upper.width, lower.width) + size * 0.22
                let bar = -size * 0.21
                let gap = size * 0.12
                let above = bar - gap - upper.descent
                let below = bar + gap + lower.ascent
                let rule = Mark.stroke([CGPoint(x: 1, y: bar), CGPoint(x: width - 1, y: bar)], width: size * 0.06)
                let marks = upper.marks.map { $0.offset(x: (width - upper.width) / 2, y: above) } + [rule]
                    + lower.marks.map { $0.offset(x: (width - lower.width) / 2, y: below) }
                return Box(width: width, ascent: upper.ascent - above, descent: below + lower.descent, marks: marks)
            case .radical(let radicand):
                let value = row(radicand, at: size)
                let inset = size * 0.63
                let width = inset + value.width + size * 0.13
                let top = -value.ascent - size * 0.12
                let bottom = value.descent + size * 0.03
                let stroke: [CGPoint] = [CGPoint(x: size * 0.03, y: -size * 0.10),
                                         CGPoint(x: size * 0.14, y: -size * 0.19),
                                         CGPoint(x: size * 0.31, y: bottom),
                                         CGPoint(x: size * 0.55, y: top),
                                         CGPoint(x: width - size * 0.03, y: top)]
                let marks = [Mark.stroke(stroke, width: size * 0.06)] + value.marks.map { $0.offset(x: inset, y: 0) }
                return Box(width: width, ascent: -top + size * 0.04, descent: bottom + size * 0.03, marks: marks)
            case .scripts(let base, let upper, let lower):
                var main = box(base, at: size)
                let font = max(baseSize * 0.55, size * 0.66)
                let above = row(upper ?? [], at: font)
                let below = row(lower ?? [], at: font)
                let x = main.width + size * 0.04
                let raised = -max(size * 0.42, main.ascent * 0.70)
                let lowered = max(size * 0.28, main.descent * 0.84)
                main.width = x + max(above.width, below.width)
                if upper != nil {
                    main.ascent = max(main.ascent, above.ascent - raised)
                    main.marks.append(contentsOf: above.marks.map { $0.offset(x: x, y: raised) })
                }
                if lower != nil {
                    main.descent = max(main.descent, below.descent + lowered)
                    main.marks.append(contentsOf: below.marks.map { $0.offset(x: x, y: lowered) })
                }
                return main
            }
        }

        private func row(_ elements: [TutorFormula.Element], at size: CGFloat) -> Box {
            var row = Box()
            for element in elements { row.append(box(element, at: size)) }
            return row
        }
    }
}
