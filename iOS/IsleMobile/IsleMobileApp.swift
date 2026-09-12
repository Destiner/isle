import SwiftUI

@main
struct IsleMobileApp: App {
    init() {
        MobileOpenRouterCredentials.bootstrapFromEnvironment()
        MobileFastmailCredentials.bootstrapFromEnvironment()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
