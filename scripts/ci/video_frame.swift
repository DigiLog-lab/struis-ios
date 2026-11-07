// One frame of a video as a PNG: swift scripts/ci/video_frame.swift <video> <seconds> <output.png>
// The UI test failure screenshot: XCTest keeps each failed test's screen recording in the result bundle,
// and this takes the frame at the moment of the failure (macOS runners have no ffmpeg).
import AVFoundation
import AppKit

@main
struct VideoFrame {
    static func main() async {
        let args: [String] = CommandLine.arguments
        guard args.count == 4, let seconds = Double(args[2]) else {
            FileHandle.standardError.write(Data("usage: video_frame.swift <video> <seconds> <output.png>\n".utf8))
            exit(2)
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = .zero
        do {
            let duration: Double = CMTimeGetSeconds(try await asset.load(.duration))
            let at = CMTime(seconds: max(0, min(seconds, duration - 0.05)), preferredTimescale: 600)
            let (image, _) = try await generator.image(at: at)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                exit(1)
            }
            try data.write(to: URL(fileURLWithPath: args[3]))
            print("frame at \(CMTimeGetSeconds(at))s of \(duration)s -> \(args[3])")
        } catch {
            FileHandle.standardError.write(Data("video_frame: \(error)\n".utf8))
            exit(1)
        }
    }
}
