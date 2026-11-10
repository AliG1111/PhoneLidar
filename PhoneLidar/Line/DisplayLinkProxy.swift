import UIKit

/// CADisplayLink keeps a strong reference to its target; this small object breaks the cycle with the owner.
/// The owner captures itself weakly in `callback` and returns false once it is gone, which invalidates the
/// link, so a forgotten link can never keep firing after its owner has been released.
@MainActor
final class DisplayLinkProxy: NSObject {
    private let callback: @MainActor (CADisplayLink) -> Bool

    init(_ callback: @escaping @MainActor (CADisplayLink) -> Bool) {
        self.callback = callback
    }

    /// A link on the main run loop that calls `callback` every screen refresh until it returns false.
    static func makeLink(preferred: Float = 60, _ callback: @escaping @MainActor (CADisplayLink) -> Bool)
        -> CADisplayLink {
        let proxy = DisplayLinkProxy(callback)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: preferred)
        link.add(to: .main, forMode: .common)
        return link
    }

    @objc func tick(_ link: CADisplayLink) {
        if !callback(link) { link.invalidate() }
    }
}
