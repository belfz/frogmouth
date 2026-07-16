import AVFoundation
import AVKit
import SwiftUI

/// AVKit's SwiftUI `VideoPlayer` crashes on macOS 15 when this app is compiled
/// with the Xcode 26 SDK. Hosting `AVPlayerView` directly avoids that framework
/// compatibility bug while retaining native playback controls.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    var controlsStyle: AVPlayerViewControlsStyle = .floating

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = controlsStyle
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
        if view.controlsStyle != controlsStyle {
            view.controlsStyle = controlsStyle
        }
    }
}
