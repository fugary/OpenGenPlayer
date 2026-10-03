//
//  GenPlayer_macOSApp.swift
//  GenPlayer_macOS
//
//  Created by Gary Fu on 2026/4/10.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GenPlayerShell
import GenPlayerCore

class MacAppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        MacLegacyContainerMigrator.migrateIfNeeded()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        MacPlayerWindowManager.shared.isOpeningExternalFile = true
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            MacPlayerWindowManager.shared.openLocalFileURL(url, hideMainWindow: true)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MacPlayerWindowManager.shared.isOpeningExternalFile = true
        for url in urls {
            MacPlayerWindowManager.shared.openLocalFileURL(url, hideMainWindow: true)
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let activeWindows = MacPlayerWindowManager.shared.activeWindows.values.compactMap { $0.window }
        let visibleWindows = activeWindows.filter { $0.isVisible && !$0.isMiniaturized }
        if visibleWindows.isEmpty {
            let showedExisting = MacPlayerWindowManager.shared.showMainWindow()
            return showedExisting // Return true to prevent SwiftUI from creating a new window if we already restored one
        }
        
        // Use asyncAfter to run AFTER macOS finishes its own window ordering
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in activeWindows {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.orderFrontRegardless()
            }
            MacPlayerWindowManager.shared.currentPlayerWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let showMainItem = NSMenuItem(
            title: platformShellString("Show Main Window"),
            action: #selector(handleDockShowMainWindow),
            keyEquivalent: ""
        )
        showMainItem.target = self
        menu.addItem(showMainItem)
        return menu
    }
    
    @objc private func handleDockShowMainWindow() {
        MacPlayerWindowManager.shared.showMainWindow()
    }
}

@main
struct GenPlayer_macOSApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    
    var body: some Scene {
        WindowGroup("Gen Player") {
            GenPlayerMacRootView()
                .onOpenURL { url in
                    MacPlayerWindowManager.shared.openLocalFileURL(url, hideMainWindow: true)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(platformShellString("About Gen Player")) {
                    MacPlayerWindowManager.shared.showMainWindow()
                    MacNavigationManager.shared.targetSettingsTab = "About"
                    NotificationCenter.default.post(name: .macNavigateToSettingsAbout, object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button(platformShellString("Settings...")) {
                    MacPlayerWindowManager.shared.showMainWindow()
                    NotificationCenter.default.post(name: .macNavigateToSettingsAbout, object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(replacing: .newItem) {
                Button(platformShellString("Show Main Window")) {
                    MacPlayerWindowManager.shared.showMainWindow()
                }
                .keyboardShortcut("n", modifiers: [.command])
                
                Divider()
                
                Button(platformShellString("Open File...")) {
                    openFilePanel()
                }
                .keyboardShortcut("o", modifiers: [.command])
                
                Button(platformShellString("Open URL...")) {
                    openURLPanel()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }

            CommandGroup(after: .newItem) {
                Divider()

                Button(platformShellString("Import Servers...")) {
                    MacServerBackupManager.shared.importServers()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                
                Button(platformShellString("Export Servers...")) {
                    MacServerBackupManager.shared.exportServers()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .help) {
                Button(platformShellString("Gen Player Website")) {
                    if let url = URL(string: "https://genplayer.fugary.com/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Button(platformShellString("Release Notes")) {
                    if let url = URL(string: "https://genplayer.fugary.com/changelog.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Divider()
                
                Button(platformShellString("Privacy Policy")) {
                    if let url = URL(string: "https://genplayer.fugary.com/privacy.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Divider()
                
                Button(platformShellString("Send Feedback")) {
                    MacFeedbackManager.shared.sendFeedback()
                }
            }
            
            CommandGroup(after: .windowArrangement) {
                Button(platformShellString("Show Main Window")) {
                    MacPlayerWindowManager.shared.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command])
                
                Divider()

                Button(platformShellString("Always on Top")) {
                    if let fileId = MacPlayerWindowManager.shared.currentPlayerFileId {
                        MacPlayerWindowManager.shared.togglePinToTop(for: fileId)
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                
                Divider()
                
                Button(platformShellString("Close Other Windows")) {
                    MacPlayerWindowManager.shared.closeOtherWindows(except: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .option])
            }
        }
    }
    
    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .audio]
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                MacPlayerWindowManager.shared.openLocalFileURL(url)
            }
        }
    }
    
    private func openURLPanel() {
        let alert = NSAlert()
        alert.messageText = platformShellString("Open URL")
        alert.informativeText = platformShellString("Enter the network stream URL to play:")
        alert.alertStyle = .informational
        alert.addButton(withTitle: platformShellString("Open"))
        alert.addButton(withTitle: platformShellString("Cancel"))
        
        let inputTextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        inputTextField.placeholderString = "https://example.com/stream.mp4"
        if let pasteboardString = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pasteboardURL = URL(string: pasteboardString), pasteboardURL.scheme != nil {
            inputTextField.stringValue = pasteboardString
        }
        alert.accessoryView = inputTextField
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let urlString = inputTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !urlString.isEmpty {
                _ = MacPlayerWindowManager.shared.openNetworkURLString(urlString)
            }
        }
    }
}

