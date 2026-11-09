import SwiftUI

@main
struct PhoneLidarApp: App {
    @State private var store = ScanStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
        }
    }
}
