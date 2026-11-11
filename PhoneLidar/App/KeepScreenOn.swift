import SwiftUI
import UIKit

/// Stops the screen from auto-locking while a capture or a long reconstruction is on screen.
/// The setting is always reset when the view goes away.
private struct KeepScreenOn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

extension View {
    func keepScreenOn() -> some View {
        modifier(KeepScreenOn())
    }
}
