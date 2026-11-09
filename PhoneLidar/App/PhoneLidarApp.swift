import SwiftUI
import UIKit

@main
struct PhoneLidarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ScanStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
        }
    }
}
