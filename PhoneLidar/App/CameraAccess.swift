import SwiftUI
import AVFoundation
import UIKit

/// Camera permission helper for the scan screens. Without it a denied camera shows only a black view.
enum CameraAccess {
    enum State {
        case checking
        case granted
        case denied
    }

    /// True when the camera may be used. Asks the first time.
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    @MainActor
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Full-screen notice shown when camera access is off.
struct CameraDeniedView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text("Camera is off")
                .font(.headline)
            Text("Turn on Camera for Phone LiDAR in Settings, then scan again.")
                .multilineTextAlignment(.center)
            Button("Open Settings") { CameraAccess.openSettings() }
                .buttonStyle(.borderedProminent)
            Button("Close", action: onClose)
                .buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
