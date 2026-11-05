import Foundation
import ImageIO

/// Prepares the disposable workspace for a plan and collects files after the turn.
nonisolated enum WorkspaceStager {
    static func prepare(plan: TurnPlan, assets: AssetCache) throws {
        UnitDeletion.gate.lock(); defer { UnitDeletion.gate.unlock() }
        guard TurnPlan.isSafeWorkspaceID(plan.id) else { throw CocoaError(.fileWriteNoPermission) }
        let root = plan.hostWorkspace
        let manager = FileManager.default
        // Later rounds of a turn reuse the workspace. Empty it rather than replacing the
        // directory: the command worker may still sit in it, and a removed directory makes
        // its next command fail with "invalid cwd".
        if manager.fileExists(atPath: root.path) {
            for entry in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                try manager.removeItem(at: entry)
            }
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for copy in plan.workspace.copies ?? [] {
            let source = try TurnPlan.stageableHostURL(copy.hostPath)
            let target = root.appendingPathComponent(copy.path, isDirectory: true)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: source.path) {
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.copyItem(at: source, to: target)
            }
        }
        for dir in plan.workspace.dirs {
            try manager.createDirectory(at: root.appendingPathComponent(dir, isDirectory: true), withIntermediateDirectories: true)
        }
        for file in plan.workspace.files {
            let target = root.appendingPathComponent(file.path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text: String
            if let name = file.asset {
                // The cache is an actor; read synchronously via a detached helper.
                text = try AssetCacheSync.text(assets, name: name)
            } else {
                text = file.inline ?? ""
            }
            try text.write(to: target, atomically: true, encoding: .utf8)
            if file.executable {
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
        }
        for image in plan.turn?.images ?? [] {
            let target = root.appendingPathComponent(image.path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            if let limit = image.maxDimension {
                try TimelineCaptureImage.stageReduced(from: TurnPlan.stageableHostURL(image.hostPath), to: target, limit: limit)
            } else {
                try stageModelImage(from: TurnPlan.stageableHostURL(image.hostPath), to: target)
            }
        }
    }

    /// The prompt image budget (the one the earlier Codex path used, codex-rs core/src/image_preparation.rs):
    /// at most 2048 px per side and 2,500 patches of 32 px. Within it, JPEG/PNG bytes are sent
    /// unchanged, so the image input loses no detail the model would get. Workspace tools
    /// (Python, view_image) see only the staged copy.
    static let modelImageMaxDimension = 2048
    static let modelImageMaxPatches = 2_500

    static func modelImageFits(width: Int, height: Int) -> Bool {
        max(width, height) <= modelImageMaxDimension
            && ((width + 31) / 32) * ((height + 31) / 32) <= modelImageMaxPatches
    }

    /// Oversized images are downsampled in the app to the budget above (the model never
    /// gets more detail). JPEG/PNG data already within the budget (including PDF page
    /// images) is copied unchanged. Oversized images and other formats (HEIC, TIFF,
    /// WebP, ...) are converted: PNG sources and images with an alpha channel to PNG,
    /// the rest to JPEG. If ImageIO cannot convert, the original is copied as before.
    /// Workspace tools then see only this reduced copy, so cropping cannot recover
    /// detail beyond the budget.
    static func stageModelImage(from source: URL, to target: URL) throws {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            try FileManager.default.copyItem(at: source, to: target)
            return
        }
        let type = CGImageSourceGetType(image) as String?
        if modelImageFits(width: width, height: height), type == "public.jpeg" || type == "public.png" {
            try FileManager.default.copyItem(at: source, to: target)
            return
        }
        // Largest long edge whose aspect-preserving size fits the budget. The patch
        // count does not depend on orientation, so the stored dimensions suffice.
        let longest = max(width, height)
        var edge = min(longest, modelImageMaxDimension)
        while edge > 1 {
            let scale = Double(edge) / Double(longest)
            let w = max(1, Int((Double(width) * scale).rounded()))
            let h = max(1, Int((Double(height) * scale).rounded()))
            if modelImageFits(width: w, height: h) { break }
            edge -= 1
        }
        // ImageIO subsamples while decoding, so the app never holds the full image
        // either. Its rounding can differ by a pixel from the estimate above.
        var thumbnail: CGImage?
        for candidate in stride(from: edge, to: max(0, edge - 8), by: -1) {
            guard let made = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: candidate,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary) else { break }
            if modelImageFits(width: made.width, height: made.height) { thumbnail = made; break }
        }
        // Keep PNG sources lossless and keep any alpha channel (JPEG has none);
        // everything else becomes JPEG.
        let opaque: Bool = {
            guard let thumbnail, type != "public.png" else { return false }
            switch thumbnail.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return true
            default: return false
            }
        }()
        let encoded = NSMutableData()
        guard let thumbnail,
              let destination = CGImageDestinationCreateWithData(encoded, (opaque ? "public.jpeg" : "public.png") as CFString, 1, nil) else {
            try FileManager.default.copyItem(at: source, to: target)
            return
        }
        CGImageDestinationAddImage(destination, thumbnail, (opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try FileManager.default.copyItem(at: source, to: target)
            return
        }
        try (encoded as Data).write(to: target, options: .atomic)
    }

    /// `collect` patterns are `<dir>/*.<ext>` (only the memory queue today).
    static func collect(plan: TurnPlan) throws -> [TurnOutcome.CollectedFile] {
        guard TurnPlan.isSafeWorkspaceID(plan.id), !plan.collect.isEmpty, plan.limits.collectMaxFiles > 0 else { return [] }
        var files: [TurnOutcome.CollectedFile] = []
        var totalBytes = 0
        let root = plan.hostWorkspace
        for pattern in plan.collect {
            let parts = pattern.split(separator: "/").map(String.init)
            guard let last = parts.last, last.hasPrefix("*.") else { continue }
            let suffix = String(last.dropFirst(1))
            let directory = root.appendingPathComponent(parts.dropLast().joined(separator: "/"), isDirectory: true)
            let entries = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])) ?? [])
                .filter { $0.lastPathComponent.hasSuffix(suffix) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for entry in entries {
                guard files.count < plan.limits.collectMaxFiles else { break }
                let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                let size = values.fileSize ?? 0
                guard totalBytes + size <= plan.limits.collectMaxBytes else { break }
                guard let text = try? String(contentsOf: entry, encoding: .utf8) else { continue }
                totalBytes += size
                let relative = String(entry.path.dropFirst(root.path.count + 1))
                files.append(TurnOutcome.CollectedFile(path: relative, text: text))
            }
        }
        return files
    }

    static func cleanup(plan: TurnPlan) {
        guard TurnPlan.isSafeWorkspaceID(plan.id) else { return }
        guard plan.sharesWorkspace else {
            try? FileManager.default.removeItem(at: plan.hostWorkspace)
            return
        }
        // A conversation's directory stays (it is the thread's cwd, and the command worker may sit in
        // it); only this turn's files go. The next turn stages its own.
        let manager = FileManager.default
        for entry in (try? manager.contentsOfDirectory(at: plan.hostWorkspace, includingPropertiesForKeys: nil)) ?? [] {
            try? manager.removeItem(at: entry)
        }
    }
}

/// Synchronous bridge for reading asset text from non-async code.
nonisolated enum AssetCacheSync {
    static func text(_ cache: AssetCache, name: String) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<String, Error> = .failure(AssetError.missing(name))
        Task.detached {
            do { result = .success(try await cache.text(name)) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}
