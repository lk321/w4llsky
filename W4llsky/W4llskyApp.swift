//
//  W4llskyApp.swift
//  W4llsky
//
//  Created by Antonio Orozco on 22/08/26.
//

import SwiftUI

@main
struct W4llskyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // No WindowGroup: it auto-opens a window at launch regardless of activation
    // policy. MenuBarController creates the one main window on demand instead.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
