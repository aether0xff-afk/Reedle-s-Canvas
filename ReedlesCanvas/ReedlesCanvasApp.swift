import SwiftUI

@main
struct ReedlesCanvasApp: App {
    @State private var showingExample = false

    var body: some Scene {
        WindowGroup {
            ContentView { showingExample = true }
                .frame(width: testContentWidth)
                .sheet(isPresented: $showingExample) { TutorExampleView() }
        }
    }

    private var testContentWidth: CGFloat? {
        #if DEBUG && (targetEnvironment(simulator) || REEDLE_UI_TEST_SUPPORT)
        if let raw = ProcessInfo.processInfo.environment["REEDLE_UI_TEST_CONTENT_WIDTH"],
           let width = Double(raw), width.isFinite, (320...1_366).contains(width) {
            return CGFloat(width)
        }
        #endif
        return nil
    }
}
