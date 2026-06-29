//
//  IsleApp.swift
//  Isle
//
//  Created by Timur Badretdinov on 29/06/2026.
//

import SwiftUI

@main
struct IsleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible scene: Isle lives as a borderless floating fragment,
        // managed imperatively by AppDelegate. `Settings` provides a valid
        // (and hidden-until-invoked) scene without spawning a window on launch.
        Settings {
            EmptyView()
        }
    }
}
