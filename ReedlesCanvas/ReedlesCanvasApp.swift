import SwiftUI

@main
struct ReedlesCanvasApp: App {
    @State private var showingExample = false

    var body: some Scene {
        WindowGroup {
            ContentView { showingExample = true }
                .sheet(isPresented: $showingExample) { TutorExampleView() }
        }
    }
}
