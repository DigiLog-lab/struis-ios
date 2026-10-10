import CoreTransferable
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// 添付の入口(信頼性計画 P3 の 1、取り込みの要件 R9〜R12)。質問画面とオンボーディングが同じ規則で受け付ける:
/// - 渡せるのは PDF と画像だけ。形式は拡張子ではなく中身で決める。
/// - 1 回の送信あたり `maxCount` 件・合計 `maxTotalBytes` まで。大きさは読み込む前に確かめる。
/// - ファイルは主スレッドの外でアプリの一時フォルダへ複写し、メモリには載せない(400MB でも増えない)。
/// - 渡せないもの(動画・docx・上限超え・壊れたもの・読めない画像・白紙の PDF)は、名前と理由を返して受け付けない。
/// - パスワード付きの PDF は、学習者にパスワードを聞いて PDFKit で解錠できれば、解錠した写しを受け付ける。
nonisolated enum AttachmentIntake {
    static let maxCount = 8
    static let maxTotalBytes = 100 * 1024 * 1024
    /// 画像の画素数の上限(これを超える画像は ImageIO でも縮小に時間とメモリがかかる)。
    static let maxImagePixels = 250_000_000
    /// 入力欄・オンボーディングに出す上限の説明(実際の上限と同じ値から作る)。
    static let limitDescription = "PDFまたは画像・\(maxCount)件・合計\(maxTotalBytes / 1024 / 1024)MBまで"

    struct Rejection: Hashable, Sendable {
        let filename: String
        let reason: String
        var line: String { "\(filename): \(reason)" }
    }

    /// パスワードを聞く PDF(一時フォルダに複写済み)。
    struct LockedPDF: Identifiable, Hashable, Sendable {
        let id = UUID()
        let filename: String
        let stagedURL: URL
        let source: ComposerAttachment.Source
    }

    enum Outcome: Sendable {
        /// `notice` は受け付けたが学習者に知らせること(白紙のページがある、など)。
        case accepted(ComposerAttachment, notice: String?)
        case rejected(Rejection)
        case needsPassword(LockedPDF)
    }

    /// 入力欄にすでにある添付を差し引いた、残りの枠。
    struct Budget: Sendable {
        var count: Int
        var bytes: Int
        init(existing: [ComposerAttachment]) {
            count = maxCount - existing.count
            bytes = maxTotalBytes - existing.reduce(0) { $0 + $1.bytes }
        }
        init(count: Int, bytes: Int) {
            self.count = count
            self.bytes = bytes
        }
    }

    // MARK: - Staging

    /// 入力欄の添付の置き場所(送信すると `ChatStore.storeAttachments` が保存先へ複写する)。
    static var stagingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("composer-intake", isDirectory: true)
    }

    /// 1 日より前の置き場所を片付ける(送られなかった下書きの添付)。
    static func removeStaleStaging() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-86_400)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < limit { try? manager.removeItem(at: entry) }
        }
    }

    static func newStagingURL(filename: String) throws -> URL {
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(safeFilename(filename))
    }

    static func safeFilename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }

    /// メモリ上のデータ(カメラ・答案の写真)を一時フォルダに置いて添付にする。
    static func staged(data: Data, filename: String, contentType: String, source: ComposerAttachment.Source) -> ComposerAttachment? {
        guard let url = try? newStagingURL(filename: filename), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return ComposerAttachment(filename: filename, contentType: contentType, fileURL: url, bytes: data.count, source: source)
    }

    // MARK: - Files

    /// Files で選んだもの。主スレッドの外で、1 件ずつ大きさ → 形式 → 中身の順に確かめる。
    @concurrent
    static func importFiles(_ urls: [URL], budget initial: Budget) async -> [Outcome] {
        var budget = initial
        var outcomes: [Outcome] = []
        for url in urls {
            let outcome = importFile(url, budget: budget)
            if case .accepted(let attachment, _) = outcome {
                budget.count -= 1
                budget.bytes -= attachment.bytes
            } else if case .needsPassword = outcome {
                budget.count -= 1
            }
            outcomes.append(outcome)
        }
        return outcomes
    }

    private static func importFile(_ url: URL, budget: Budget) -> Outcome {
        let filename = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey])
        if values?.isDirectory == true {
            return .rejected(Rejection(filename: filename, reason: "フォルダは添付できません。中のファイルを選んでください"))
        }
        guard values?.isRegularFile == true, let size = values?.fileSize else {
            return .rejected(Rejection(filename: filename, reason: "ファイルを読み込めませんでした"))
        }
        guard budget.count > 0 else {
            return .rejected(Rejection(filename: filename, reason: "一度に添付できるのは\(maxCount)件までです"))
        }
        guard size > 0 else { return .rejected(Rejection(filename: filename, reason: "空のファイルです")) }
        // 中身を読む前に、形式(先頭の数バイト)と大きさで断る。
        guard let kind = DocumentReader.sniff(url) else {
            return .rejected(Rejection(filename: filename, reason: unsupportedReason(url)))
        }
        guard size <= budget.bytes else {
            return .rejected(Rejection(filename: filename, reason: tooLargeReason(size: size, budget: budget)))
        }
        let staged: URL
        do {
            staged = try newStagingURL(filename: filename)
            // 同じボリュームなら複製(クローン)、違えば少しずつ写す。メモリには載せない。
            try FileManager.default.copyItem(at: url, to: staged)
        } catch {
            return .rejected(Rejection(filename: filename, reason: "ファイルを読み込めませんでした"))
        }
        return validate(staged: staged, filename: filename, kind: kind, bytes: size, source: .files)
    }

    // MARK: - Photos

    /// 写真ライブラリの 1 枚(`PhotoFile` が一時フォルダに受け取ったもの)。
    @concurrent
    static func importPhoto(_ file: PhotoFile, budget: Budget) async -> Outcome {
        let filename = file.url.lastPathComponent
        guard budget.count > 0 else {
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
            return .rejected(Rejection(filename: filename, reason: "一度に添付できるのは\(maxCount)件までです"))
        }
        let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= budget.bytes else {
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
            return .rejected(Rejection(filename: filename, reason: tooLargeReason(size: size, budget: budget)))
        }
        guard let kind = DocumentReader.sniff(file.url) else {
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
            return .rejected(Rejection(filename: filename, reason: "この写真は読み込めませんでした(対応していない形式です)"))
        }
        return validate(staged: file.url, filename: filename, kind: kind, bytes: size, source: .photoLibrary)
    }

    // MARK: - Validation

    /// 一時フォルダに置いたものの中身を確かめる。受け付けないものは一時フォルダから消す。
    static func validate(staged: URL, filename: String, kind: DocumentReader.Kind, bytes: Int, source: ComposerAttachment.Source) -> Outcome {
        let outcome: Outcome
        switch kind {
        case .pdf:
            outcome = validatePDF(staged: staged, filename: filename, bytes: bytes, source: source)
        case .image(let type):
            outcome = validateImage(staged: staged, filename: filename, type: type, bytes: bytes, source: source)
        }
        if case .rejected = outcome { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        return outcome
    }

    private static func validatePDF(staged: URL, filename: String, bytes: Int, source: ComposerAttachment.Source) -> Outcome {
        guard let document = PDFDocument(url: staged) else {
            return .rejected(Rejection(filename: filename, reason: "PDFが壊れているため開けません"))
        }
        if document.isLocked {
            return .needsPassword(LockedPDF(filename: filename, stagedURL: staged, source: source))
        }
        return acceptPDF(document, staged: staged, filename: filename, bytes: bytes, source: source)
    }

    private static func acceptPDF(_ document: PDFDocument, staged: URL, filename: String, bytes: Int, source: ComposerAttachment.Source) -> Outcome {
        let count = document.pageCount
        guard count > 0 else { return .rejected(Rejection(filename: filename, reason: "PDFにページがありません")) }
        // モデルに画像で渡す最初のページが白紙なら知らせる(全部白紙なら受け付けない)。
        let checked = min(count, ChatStore.pdfPageImageLimit)
        var blank: [Int] = []
        for index in 0..<checked {
            autoreleasepool {
                if let page = document.page(at: index), DocumentReader.isBlank(page) { blank.append(index + 1) }
            }
        }
        if blank.count == checked {
            // 先頭が白紙でも、後ろのページに内容があれば受け付ける(表紙の後の空白ページなど)。断るのは全体が白紙の時だけ。
            // 調べるのに時間がかかりすぎる時は、内容が無いと決めつけずに受け付けて知らせる。
            let started = Date()
            var laterContent: Bool?
            for index in checked..<count {
                if Date().timeIntervalSince(started) > 5 { break }
                let blankPage = autoreleasepool { document.page(at: index).map(DocumentReader.isBlank) ?? true }
                if !blankPage { laterContent = true; break }
                if index == count - 1 { laterContent = false }
            }
            if count == checked || laterContent == false {
                return .rejected(Rejection(filename: filename, reason: "白紙のPDFです(文字も絵も見つかりません)"))
            }
        }
        let name = (filename as NSString).pathExtension.lowercased() == "pdf" ? filename : filename + ".pdf"
        let attachment = ComposerAttachment(
            filename: name, contentType: "application/pdf", fileURL: staged, bytes: bytes, source: source, detail: "PDF・\(count)ページ"
        )
        let notice = blank.isEmpty ? nil : "\(filename): \(DocumentTool.ranges(blank))ページ目が白紙です(そのまま渡します)"
        return .accepted(attachment, notice: notice)
    }

    /// パスワードで解錠し、解錠した写しを受け付ける。違うパスワードなら nil。
    @concurrent
    static func unlock(_ locked: LockedPDF, password: String) async -> Outcome? {
        guard let document = PDFDocument(url: locked.stagedURL) else {
            try? FileManager.default.removeItem(at: locked.stagedURL.deletingLastPathComponent())
            return .rejected(Rejection(filename: locked.filename, reason: "PDFが壊れているため開けません"))
        }
        guard document.unlock(withPassword: password), !document.isLocked else { return nil }
        // モデルの道具(struis.document)もパスワード無しで読めるように、解錠した写しを保存する。
        let unlocked = locked.stagedURL.deletingLastPathComponent().appendingPathComponent("unlocked-" + locked.stagedURL.lastPathComponent)
        // 解錠した文書をそのまま書くと暗号化が残る環境がある。その時はページを新しい文書へ移して書く。
        var written = document.write(to: unlocked) && PDFDocument(url: unlocked).map { !$0.isLocked && !$0.isEncrypted } == true
        if !written {
            let copy = PDFDocument()
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage { copy.insert(page, at: copy.pageCount) }
            }
            try? FileManager.default.removeItem(at: unlocked)
            written = copy.write(to: unlocked)
        }
        guard written, let reopened = PDFDocument(url: unlocked), !reopened.isLocked else {
            try? FileManager.default.removeItem(at: locked.stagedURL.deletingLastPathComponent())
            return .rejected(Rejection(filename: locked.filename, reason: "パスワード付きのPDFを開けませんでした"))
        }
        try? FileManager.default.removeItem(at: locked.stagedURL)
        let bytes = (try? unlocked.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let outcome = acceptPDF(reopened, staged: unlocked, filename: locked.filename, bytes: bytes, source: locked.source)
        if case .rejected = outcome { try? FileManager.default.removeItem(at: unlocked.deletingLastPathComponent()) }
        return outcome
    }

    static func discard(_ locked: LockedPDF) {
        try? FileManager.default.removeItem(at: locked.stagedURL.deletingLastPathComponent())
    }

    private static func validateImage(staged: URL, filename: String, type: UTType, bytes: Int, source: ComposerAttachment.Source) -> Outcome {
        guard let info = DocumentReader.imageInfo(staged), DocumentReader.imageDecodes(staged) else {
            return .rejected(Rejection(filename: filename, reason: "画像を読み込めませんでした(壊れているか、対応していない形式です)"))
        }
        // 細工したメタデータでも落ちないよう、桁あふれを確かめてから比べる。
        let pixels = info.width.multipliedReportingOverflow(by: info.height)
        guard !pixels.overflow, pixels.partialValue <= maxImagePixels else {
            return .rejected(Rejection(filename: filename, reason: "画像が大きすぎます(\(info.width)×\(info.height))"))
        }
        // 名前の拡張子と、渡す形式を中身に合わせる(拡張子の無い JPEG、HEIC を .jpg と名付けた写真など)。
        let ext = type.preferredFilenameExtension ?? "img"
        let stem = (filename as NSString).deletingPathExtension
        let currentExt = (filename as NSString).pathExtension
        let name = UTType(filenameExtension: currentExt) == type ? filename : (stem.isEmpty ? "image" : stem) + "." + ext
        let parts = DocumentReader.imagePartCount(width: info.width, height: info.height)
        var detail = "\(info.width)×\(info.height)"
        if parts > 1 { detail += "・\(parts)枚に分けて渡します" }
        let attachment = ComposerAttachment(
            filename: name, contentType: type.preferredMIMEType ?? "image/jpeg", fileURL: staged, bytes: bytes, source: source, detail: detail
        )
        let notice = info.frames > 1 ? "\(name): 動く画像は最初のコマだけを渡します" : nil
        return .accepted(attachment, notice: notice)
    }

    // MARK: - Reasons

    private static func unsupportedReason(_ url: URL) -> String {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .movie) == true || type?.conforms(to: .audiovisualContent) == true {
            return "動画・音声は渡せません。PDFか画像を選んでください"
        }
        if type?.conforms(to: .svg) == true { return "SVGの画像は読めません。PNGかJPEGにしてください" }
        if type?.conforms(to: .image) == true { return "画像を読み込めませんでした(壊れているか、対応していない形式です)" }
        if type?.conforms(to: .pdf) == true { return "PDFが壊れているため開けません" }
        let ext = url.pathExtension.isEmpty ? "この形式" : ".\(url.pathExtension)"
        return "\(ext)は読めません。PDFか画像にして添付してください"
    }

    private static func tooLargeReason(size: Int, budget: Budget) -> String {
        let megabytes = { (bytes: Int) in String(format: "%.0fMB", max(1, Double(bytes) / 1_048_576)) }
        if budget.bytes < maxTotalBytes {
            return "大きすぎます(\(megabytes(size)))。1回に添付できるのは合計\(maxTotalBytes / 1_048_576)MBまでです(残り\(megabytes(max(0, budget.bytes))))"
        }
        return "大きすぎます(\(megabytes(size)))。1回に添付できるのは合計\(maxTotalBytes / 1_048_576)MBまでです"
    }
}

/// 写真ライブラリの 1 枚を、メモリに載せずにファイルで受け取る(元の名前と形式のまま)。
nonisolated struct PhotoFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let target = try AttachmentIntake.newStagingURL(filename: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PhotoFile(url: target)
        }
    }
}
