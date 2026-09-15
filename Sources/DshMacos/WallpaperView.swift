import AppKit
import SwiftUI

struct WallpaperView: View {
    let settings: WallpaperSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                baseColor

                if settings.isVisible {
                    visibleWallpaper(size: proxy.size)
                } else {
                    fallbackGradient
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private func visibleWallpaper(size: CGSize) -> some View {
        switch wallpaperMediaKind(forPath: settings.path) {
        case .video where FileManager.default.fileExists(atPath: settings.path):
            mediaChrome(size: size) {
                LoopingVideoWallpaper(
                    url: URL(fileURLWithPath: settings.path),
                    fit: settings.fit
                )
            }
        case .animatedImage where FileManager.default.fileExists(atPath: settings.path):
            mediaChrome(size: size) {
                AnimatedImageWallpaper(
                    url: URL(fileURLWithPath: settings.path),
                    fit: settings.fit
                )
            }
        case .image:
            if let image = NSImage(contentsOfFile: settings.path) {
                mediaChrome(size: size) {
                    wallpaperImage(image, size: size)
                }
            } else {
                fallbackGradient
            }
        default:
            fallbackGradient
        }
    }

    @ViewBuilder
    private func mediaChrome<Content: View>(size: CGSize, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: size.width, height: size.height)
            .opacity(settings.opacity)
            .blur(radius: settings.blur)
        readabilityOverlay
    }

    private var baseColor: Color {
        colorScheme == .dark
            ? Color(red: 0.025, green: 0.04, blue: 0.065)
            : Color(red: 0.965, green: 0.975, blue: 0.99)
    }

    private var fallbackGradient: LinearGradient {
        let colors = colorScheme == .dark
            ? [
                Color(red: 0.04, green: 0.08, blue: 0.14),
                Color(red: 0.025, green: 0.04, blue: 0.065),
                Color(red: 0.08, green: 0.035, blue: 0.12)
            ]
            : [
                Color(red: 0.98, green: 0.99, blue: 1),
                Color(red: 0.93, green: 0.96, blue: 0.99),
                Color(red: 0.97, green: 0.94, blue: 0.99)
            ]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var readabilityOverlay: Color {
        colorScheme == .dark
            ? Color.black.opacity(settings.overlay)
            : Color.white.opacity(settings.overlay * 0.72)
    }

    @ViewBuilder
    private func wallpaperImage(_ image: NSImage, size: CGSize) -> some View {
        let alignment = Alignment(
            horizontal: horizontalAlignment,
            vertical: verticalAlignment
        )
        switch settings.fit {
        case .cover:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height, alignment: alignment)
                .clipped()
        case .contain:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height, alignment: alignment)
        case .fill:
            Image(nsImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
        }
    }

    private var horizontalAlignment: HorizontalAlignment {
        if settings.positionX < 0.34 { return .leading }
        if settings.positionX > 0.66 { return .trailing }
        return .center
    }

    private var verticalAlignment: VerticalAlignment {
        if settings.positionY < 0.34 { return .top }
        if settings.positionY > 0.66 { return .bottom }
        return .center
    }
}
