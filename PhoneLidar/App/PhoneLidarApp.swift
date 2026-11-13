import SwiftUI
import UIKit

@main
struct PhoneLidarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: ScanStore
    @State private var link: RemoteLink

    init() {
        let store = ScanStore()
        _store = State(initialValue: store)
        _link = State(initialValue: RemoteLink(store: store))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .environment(link)
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            // The remote link runs only while the app is in the foreground (FR-RMT-12).
            link.scenePhaseChanged(newPhase)
        }
    }
}
