import SwiftUI

@main
struct ReminderScreenSyncApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .windowStyle(.titleBar)

        MenuBarExtra(AppConstants.shortAppName, systemImage: "arrow.triangle.2.circlepath") {
            MenuBarView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
