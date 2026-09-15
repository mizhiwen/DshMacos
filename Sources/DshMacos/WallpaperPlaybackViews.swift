import AVFoundation
import AppKit
import SwiftUI

struct LoopingVideoWallpaper: NSViewRepresentable {
    let url: URL
    let fit: WallpaperFit

    func makeNSView(context: Context) -> LoopingWallpaperVideoView {
        let view = LoopingWallpaperVideoView()
        view.load(url: url, gravity: wallpaperVideoGravity(for: fit))
        return view
    }

    func updateNSView(_ nsView: LoopingWallpaperVideoView, context: Context) {
        nsView.load(url: url, gravity: wallpaperVideoGravity(for: fit))
    }
}

final class LoopingWallpaperVideoView: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var loadedURL: URL?
    private var loadedGravity: AVLayerVideoGravity?
    private var resignObserver: NSObjectProtocol?
    private var becomeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        player.isMuted = true
        if #available(macOS 13.3, *) {
            player.preventsDisplaySleepDuringVideoPlayback = false
        }
        playerLayer.player = player
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.player.pause()
        }
        becomeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.player.play()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let becomeObserver { NotificationCenter.default.removeObserver(becomeObserver) }
        player.pause()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func load(url: URL, gravity: AVLayerVideoGravity) {
        playerLayer.videoGravity = gravity
        loadedGravity = gravity
        guard loadedURL != url else { return }
        loadedURL = url
        let item = AVPlayerItem(url: url)
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
    }
}

struct AnimatedImageWallpaper: NSViewRepresentable {
    let url: URL
    let fit: WallpaperFit

    func makeNSView(context: Context) -> AnimatedWallpaperImageView {
        let view = AnimatedWallpaperImageView()
        view.update(url: url, fit: fit)
        return view
    }

    func updateNSView(_ nsView: AnimatedWallpaperImageView, context: Context) {
        nsView.update(url: url, fit: fit)
    }
}

final class AnimatedWallpaperImageView: NSImageView {
    private var loadedURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        animates = true
        imageFrameStyle = .none
        isEditable = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(url: URL, fit: WallpaperFit) {
        imageScaling = {
            switch fit {
            case .cover, .contain:
                return .scaleProportionallyUpOrDown
            case .fill:
                return .scaleAxesIndependently
            }
        }()
        guard loadedURL != url else { return }
        loadedURL = url
        image = NSImage(contentsOf: url)
        animates = true
    }

    override var isOpaque: Bool { false }
}
