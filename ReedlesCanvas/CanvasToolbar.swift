import SwiftUI

@MainActor
struct CanvasToolbar: View {
    @ObservedObject var document: DrawingDocument
    @ObservedObject var navigation: CanvasNavigation
    @ObservedObject var assistant: TutorAssistant
    let library: NotePDFLibrary
    @Binding var tutorPanel: TutorControls.Panel?
    let width: CGFloat
    let inTutorExample: Bool
    let openTutorExample: (() -> Void)?
    let exportBackup: () -> Void
    @ScaledMetric(relativeTo: .body) private var singleRowMinimum: CGFloat = 620

    private var compact: Bool { width < singleRowMinimum }

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                             : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 8) {
                Text("리들의 캔버스")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(document.strokeCount)획")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityIdentifier(inTutorExample ? "tutor.exampleStrokeCount" : "canvas.strokeCount")
                if compact { saveButton }
            }
            HStack(spacing: 0) {
                historyButtons
                Menu {
                    Button("현재 위치 기억") { navigation.rememberPosition() }
                    Button("기억한 위치로") { navigation.returnToPosition() }
                        .disabled(navigation.bookmark == nil)
                    Divider()
                    Button("노트 백업 내보내기", action: exportBackup)
                } label: {
                    CanvasMenuLabel(title: "보기", systemImage: "eye", compact: compact)
                }
                .disabled(document.loadError != nil || navigation.isUsingPencil)
                if !inTutorExample {
                    NoteResourceControls(document: document, navigation: navigation, library: library, compact: compact)
                        .disabled(document.loadError != nil || navigation.isUsingPencil)
                    PracticeControls(document: document, navigation: navigation, compact: compact)
                        .disabled(document.loadError != nil || navigation.isUsingPencil)
                }
                TutorControls(document: document, assistant: assistant, panel: $tutorPanel,
                              inExample: inTutorExample, openExample: openTutorExample,
                              pencilInUse: navigation.isUsingPencil, compact: compact)
                    .disabled(document.loadError != nil || navigation.isUsingPencil)
                if !compact { saveButton }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var historyButtons: some View {
        HStack(spacing: 0) {
            Button(action: document.undo) {
                Label("실행 취소", systemImage: "arrow.uturn.backward")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!document.canUndo)
            Button(action: document.redo) {
                Label("다시 실행", systemImage: "arrow.uturn.forward")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!document.canRedo)
        }
        .labelStyle(.iconOnly)
        .disabled(document.loadError != nil || navigation.isUsingPencil)
    }

    private var saveButton: some View {
        Button(action: document.saveNow) {
            Text("저장")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(document.loadError != nil)
        .accessibilityIdentifier("canvas.save")
    }
}

struct CanvasMenuLabel: View {
    let title: String
    let systemImage: String
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                Image(systemName: systemImage).font(.system(size: 20))
            } else {
                Text(title).lineLimit(1)
            }
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(title))
    }
}
