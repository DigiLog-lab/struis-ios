import ImageIO
import QuickLookThumbnailing
import UIKit

/// Decodes only the pixels needed by the destination, away from UI updates.
enum PreparedImage {
    nonisolated static func decode(_ data: Data, maxPixelSize: Int?) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw APIError.invalidResponse
            }
            let image: CGImage?
            if let maxPixelSize {
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            } else {
                // Preserve the original orientation and resolution for zooming.
                guard let original = UIImage(data: data), let prepared = original.preparingForDisplay() else {
                    throw APIError.invalidResponse
                }
                return prepared
            }
            guard let image else { throw APIError.invalidResponse }
            return UIImage(cgImage: image)
        }.value
    }

    /// ファイルの画像を、長い辺 `maxPixelSize` px までに縮めてデコードする(原寸はデコードしない)。
    /// 画素の数で上限を決めるので、画面倍率で大きくならない(吹き出し・全画面表示の画像、信頼性計画 P3 の 4)。
    nonisolated static func decode(contentsOf url: URL, maxPixelSize: Int) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                      kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary)
            else { throw CocoaError(.fileReadCorruptFile) }
            return UIImage(cgImage: image)
        }.value
    }

    /// 入力欄の小さな縮小表示(画像と PDF の 1 ページ目)。QuickLook が作り、だめなら ImageIO で縮める。
    nonisolated static func thumbnail(of url: URL, pixelSize: Int) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: pixelSize, height: pixelSize), scale: 1, representationTypes: .thumbnail
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.uiImage
        }
        return try? await decode(contentsOf: url, maxPixelSize: pixelSize)
    }
}
