//
//  GenPlayer_tvOSApp.swift
//  GenPlayer_tvOS
//
//  Created by Gary Fu on 2026/4/10.
//

import SwiftUI
import AVFoundation
import GenPlayerShell

@main
struct GenPlayer_tvOSApp: App {
    init() {
        // Setup global CJK font interceptor to keep font consistency throughout the application
        TVPlaybackCoordinator.setupFontInterceptor()

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure AVAudioSession: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            GenPlayerTVRootView()
        }
    }
}
