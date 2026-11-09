import UIKit

/// The app runs in portrait. Screens that need more width (the topographic replay) unlock landscape while
/// they are open.
@MainActor
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait

    static func allow(_ newMask: UIInterfaceOrientationMask, rotateTo preferred: UIInterfaceOrientationMask? = nil) {
        mask = newMask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ??
                UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        if let preferred {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: preferred))
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
