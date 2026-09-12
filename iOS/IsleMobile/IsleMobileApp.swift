import SwiftUI

@main
struct IsleMobileApp: App {
    init() {
        MobileOpenRouterCredentials.bootstrapFromEnvironment()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
