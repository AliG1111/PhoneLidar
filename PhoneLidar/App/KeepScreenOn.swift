import SwiftUI
import UIKit

/// Auto-lock is off while at least one holder needs the screen awake: capture screens, the Remote screen and a
/// phone that allows remote control (`RemoteLink`). Each holder takes and releases its own hold, so one screen going
/// away never turns auto-lock back on while another still needs the screen awake.
@MainActor
enum ScreenAwake {
    private static var holders = Set<UUID>()

    static func set(held: Bool, by holder: UUID) {
        if held {
            holders.insert(holder)
        } else {
            holders.remove(holder)
        }
        let disabled = !holders.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != disabled {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }
}

/// Stops the screen from auto-locking while a capture, a long reconstruction or the Remote screen is on screen.
/// The hold is always released when the view goes away.
private struct KeepScreenOn: ViewModifier {
    @State private var holder = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { ScreenAwake.set(held: true, by: holder) }
            .onDisappear { ScreenAwake.set(held: false, by: holder) }
    }
}

extension View {
    func keepScreenOn() -> some View {
        modifier(KeepScreenOn())
    }
}
