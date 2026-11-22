import SwiftUI

@main
struct DeviceLabApp: App {
    var body: some Scene {
        WindowGroup { DeviceLabView(sourceCommit: DeviceLabBuildInfo.sourceCommit) }
    }
}
