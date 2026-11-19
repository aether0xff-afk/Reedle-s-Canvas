import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var document = DrawingDocument()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("리들의 캔버스")
                    .font(.headline)
                Spacer()
                Text("\(document.strokeCount)획")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("저장") { document.saveNow() }
                    .disabled(document.loadError != nil)
            }
            .padding(.horizontal)
            .frame(height: 52)

            if let loadError = document.loadError {
                ContentUnavailableView(
                    "필기를 열 수 없습니다",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                PencilCanvasView(document: document)
                    .background(Color.white)
            }
        }
        .alert("저장 실패", isPresented: $document.showSaveError) {
            Button("확인", role: .cancel) { }
        } message: {
            Text(document.saveError ?? "저장할 수 없습니다.")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { document.saveNow() }
        }
    }
}
