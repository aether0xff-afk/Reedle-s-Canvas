import SwiftUI

@MainActor
struct PracticeControls: View {
    @ObservedObject var document: DrawingDocument
    let navigation: CanvasNavigation
    @State private var solving = false
    @State private var showingStatistics = false
    @State private var errorText: String?

    var body: some View {
        Menu("연습") {
            Button("현재 풀이로 새 문제") { start(nil) }
                .accessibilityIdentifier("practice.new")
            Menu("분야 선택") {
                ForEach(PracticeSkill.allCases, id: \.self) { skill in
                    Button(skill.title) { start(skill) }
                }
            }
            Button("문제 풀기") { solving = true }
                .disabled(document.practice.current == nil)
                .accessibilityIdentifier("practice.solve")
            Button("문제 위치로 이동") {
                if let card = document.practice.current { show(card) }
            }
            .disabled(document.practice.current == nil)
            Button("학습 기록") { showingStatistics = true }
                .disabled(document.practice.statistics.isEmpty)
        }
        .accessibilityIdentifier("practice.menu")
        .sheet(isPresented: $solving) { PracticeAnswerView(document: document) }
        .sheet(isPresented: $showingStatistics) {
            NavigationStack {
                List(PracticeSkill.allCases.filter { document.practice.statistics[$0] != nil }, id: \.self) { skill in
                    if let item = document.practice.statistics[skill] {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(skill.title).font(.headline)
                            Text("다음 난이도 \(item.difficulty) · 답안 \(item.attempts)회 · 오답 \(item.incorrect)회")
                                .foregroundStyle(.secondary)
                            if item.hintsUsed != nil || item.assistedSolutions != nil {
                                Text("힌트 \(item.hintsUsed ?? 0)회 · 재시도나 힌트 후 정답 \(item.assistedSolutions ?? 0)개")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("학습 기록")
                .toolbar { Button("닫기") { showingStatistics = false } }
            }
        }
        .alert("연습문제", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) { }
        } message: { Text(errorText ?? "") }
    }

    private func start(_ skill: PracticeSkill?) {
        do {
            let card = try document.createPracticeProblem(for: skill)
            if document.currentWorldViewport?.contains(card.frame) != true { show(card) }
        } catch {
            errorText = "연습문제를 저장하거나 배치할 수 없습니다."
        }
    }

    private func show(_ card: PracticeCard) {
        let rect = card.frame
        let scale = navigation.projection.camera.scale
        let screenWidth = (document.currentWorldViewport?.width ?? 1_024) * scale
        let screenHeight = (document.currentWorldViewport?.height ?? 768) * scale
        let viewingScale = max(CanvasCamera.minimumScale, min(1, screenWidth / (rect.width + 68),
                                                              screenHeight / (rect.height + 112)))
        navigation.go(to: CanvasCamera(origin: CGPoint(x: rect.midX - screenWidth / (2 * viewingScale),
                                                        y: rect.minY - 38 / viewingScale), scale: viewingScale))
    }
}

@MainActor
private struct PracticeAnswerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var document: DrawingDocument
    @State private var answer = ""
    @State private var feedback: String?

    var body: some View {
        NavigationStack {
            if let card = document.practice.current {
                Form {
                    Section(card.problem.skill.title) {
                        Text(card.problem.prompt).font(.title2)
                            .accessibilityIdentifier("practice.prompt")
                    }
                    if card.solved {
                        Label("정답입니다", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("practice.correct")
                    } else {
                        Section {
                            TextField("답안", text: $answer)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onSubmit { submit(for: card.id) }
                                .accessibilityIdentifier("practice.answer")
                            Button("확인") { submit(for: card.id) }
                                .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("practice.submit")
                            if let feedback { Text(feedback).foregroundStyle(.secondary) }
                        }
                        Section("힌트") {
                            ForEach(card.visibleHints.indices, id: \.self) { index in
                                Text(card.visibleHints[index])
                            }
                            Button("다음 힌트") {
                                do { try document.revealPracticeHint(for: card.id) }
                                catch { feedback = "힌트를 저장할 수 없습니다." }
                            }
                            .disabled(card.hintCount >= card.problem.hints.count)
                        }
                    }
                }
                .navigationTitle("연습문제")
                .toolbar { Button("닫기") { dismiss() } }
            }
        }
    }

    private func submit(for id: UUID) {
        do {
            switch try document.submitPracticeAnswer(answer, for: id) {
            case .correct, .closed: feedback = nil
            case .retry: feedback = "한 번 더 풀어 보세요."
            case .invalid: feedback = "문제에 맞는 숫자로 입력해 주세요."
            }
        } catch { feedback = "답안 기록을 저장할 수 없습니다." }
    }
}

@MainActor
struct PracticeCanvasCard: View {
    let card: PracticeCard
    @ObservedObject var projection: CanvasProjection

    var body: some View {
        GeometryReader { geometry in
            let camera = projection.camera
            let frame = card.frame
            let rect = camera.screenRect(for: frame)
            if rect.intersects(CGRect(origin: .zero, size: geometry.size)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(card.solved ? "해결 완료" : card.problem.skill.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.15, green: 0.33, blue: 0.44))
                    Text(verbatim: card.problem.prompt)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.black)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(15)
                .frame(width: frame.width, height: frame.height, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0.91, green: 0.96, blue: 0.98))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(red: 0.73, green: 0.84, blue: 0.89), lineWidth: 1)
                }
                .scaleEffect(camera.scale)
                .position(x: rect.midX, y: rect.midY)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
