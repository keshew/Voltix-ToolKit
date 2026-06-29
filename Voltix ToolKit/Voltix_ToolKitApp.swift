import SwiftUI

@main
struct Voltix_ToolKitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootContentView()
        }
    }
}
