import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum WallpaperMediaKind: String, Equatable {
    case none
    case image
    case animatedImage
    case video
}

struct WallpaperFilePolicy: Equatable {
    var kind: WallpaperMediaKind
    var maxBytes: Int
}

func wallpaperMediaKind(forPath path: String) -> WallpaperMediaKind {
    wallpaperFilePolicy(pathExtension: URL(fileURLWithPath: path).pathExtension)?.kind ?? .none
}

func wallpaperFilePolicy(pathExtension: String) -> WallpaperFilePolicy? {
    switch pathExtension.lowercased() {
    case "png", "jpg", "jpeg", "webp", "heic", "heif":
        return WallpaperFilePolicy(kind: .image, maxBytes: 20 * 1_024 * 1_024)
    case "gif":
        return WallpaperFilePolicy(kind: .animatedImage, maxBytes: 40 * 1_024 * 1_024)
    case "mp4", "m4v", "mov":
        return WallpaperFilePolicy(kind: .video, maxBytes: 250 * 1_024 * 1_024)
    default:
        return nil
    }
}

func wallpaperVideoGravity(for fit: WallpaperFit) -> AVLayerVideoGravity {
    switch fit {
    case .cover:
        return .resizeAspectFill
    case .contain:
        return .resizeAspect
    case .fill:
        return .resize
    }
}

func wallpaperPickerContentTypes() -> [UTType] {
    [.png, .jpeg, .webP, .heic, .gif, .mpeg4Movie, .quickTimeMovie]
}
