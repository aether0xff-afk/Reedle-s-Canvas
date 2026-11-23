import SwiftUI

/// A passive hint so the first Pencil stroke can begin anywhere on the canvas.
struct CanvasWelcomeView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tint)
                .padding(22)
                .background(Color.accentColor.opacity(0.07), in: Circle())
            Text("생각이 시작되는 곳")
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
            VStack(spacing: 8) {
                Text("Apple Pencil로 첫 줄을 써 보세요.")
                Text("손가락으로 이동하고, 두 손가락으로 확대해요.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: 430)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct CanvasTutorStatus: View {
    @ObservedObject var assistant: TutorAssistant
    @ObservedObject var document: DrawingDocument
    let pencilInUse: Bool
    let openSettings: () -> Void
    let showProposal: (TutorProposal) -> Void

    private enum Action: Equatable { case settings, cancel, proposal, question, save }
    private struct Presentation {
        let title: String
        let detail: String
        let symbol: String
        let actionTitle: String
        let action: Action
        var attention = false
    }

    private var presentation: Presentation {
        if document.saveError != nil {
            return Presentation(title: "필기를 보관하고 있어요", detail: "저장을 다시 시도할 수 있습니다",
                                symbol: "externaldrive.badge.exclamationmark", actionTitle: "다시 저장", action: .save, attention: true)
        }
        if assistant.busy {
            let title: String
            switch assistant.progress {
            case .reading: title = "필기를 읽고 있어요"
            case .drafting: title = "답변을 쓰고 있어요"
            case nil: title = "풀이를 살펴볼 준비 중"
            }
            return Presentation(title: title, detail: "계속 필기하면 튜터가 기다립니다",
                                symbol: "sparkles", actionTitle: "멈춤", action: .cancel)
        }
        if assistant.pendingProposal != nil {
            return Presentation(title: "새 판서 제안이 있어요", detail: "내용을 확인하고 캔버스에 적용하세요",
                                symbol: "text.bubble", actionTitle: "제안 보기", action: .proposal)
        }
        if let message = assistant.status {
            return Presentation(title: "튜터 알림", detail: message, symbol: "exclamationmark.circle",
                                actionTitle: "설정", action: .settings, attention: true)
        }
        if assistant.connection.endpoint == nil {
            if assistant.connection.enabled {
                return Presentation(title: "연결 설정이 필요해요", detail: "서버 주소와 접속 토큰을 확인해 주세요",
                                    symbol: "link", actionTitle: "설정", action: .settings, attention: true)
            }
            let configured = !assistant.connection.server.isEmpty
            return Presentation(title: configured ? "내 필기에 집중하는 중" : "나만의 학습 공간",
                                detail: "필기는 이 기기에 자동으로 저장됩니다", symbol: "pencil.line",
                                actionTitle: configured ? "튜터 설정" : "튜터 연결", action: .settings)
        }
        if assistant.connection.automatic {
            return Presentation(title: "필기 후 자동 판서", detail: "펜을 떼면 튜터가 풀이를 살펴봅니다",
                                symbol: "sparkles", actionTitle: "질문", action: .question)
        }
        return Presentation(title: "조용히 모드", detail: "질문할 때만 튜터에게 필기를 보냅니다",
                            symbol: "moon", actionTitle: "질문", action: .question)
    }

    var body: some View {
        let state = presentation
        HStack(spacing: 10) {
            if assistant.busy {
                ProgressView().controlSize(.small).frame(width: 24)
            } else {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.attention ? Color.orange : Color.accentColor)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(state.actionTitle) { perform(state.action) }
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .disabled(pencilInUse || document.loadError != nil
                          || (state.action == .question && document.strokeCount == 0))
                .accessibilityIdentifier("canvas.tutorPrimaryAction")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.7))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .accessibilityIdentifier("canvas.tutorStatus")
    }

    private func perform(_ action: Action) {
        switch action {
        case .settings: openSettings()
        case .cancel: assistant.cancelRequest()
        case .question: assistant.request(in: document, manual: true)
        case .proposal:
            if let proposal = assistant.pendingProposal { showProposal(proposal) }
        case .save: document.saveNow()
        }
    }
}
