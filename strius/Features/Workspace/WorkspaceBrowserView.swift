import QuickLook
import SwiftUI

struct WorkspaceBrowserView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.colorScheme) private var scheme

    @State private var listing: WorkspaceListingDTO?
    @State private var searchText = ""
    @State private var searchResults: [WorkspaceEntryDTO]?
    @State private var searchTruncated = false
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var previewItem: WorkspacePreviewItem?

    private var shownEntries: [WorkspaceEntryDTO] {
        searchResults ?? listing?.entries ?? []
    }

    private var shownDirectories: [WorkspaceEntryDTO] {
        shownEntries.filter { $0.kind == .directory }
    }

    private var shownFiles: [WorkspaceEntryDTO] {
        shownEntries.filter { $0.kind == .file }
    }

    var body: some View {
        Group {
            if isLoading && listing == nil {
                ProgressView("Workspaceを読み込んでいます").progressViewStyle(StruisProgressViewStyle())
            } else if listing?.available == false {
                ContentUnavailableView(
                    "Workspaceはまだ空です",
                    systemImage: "folder",
                    description: Text("学習でファイルが作られると、ここに表示されます。")
                )
            } else {
                workspaceContent
            }
        }
        .navigationTitle("ファイル")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "ファイルを検索")
        .task {
            await loadDirectory(path: "")
        }
        .task(id: searchText) {
            await search()
        }
        .fullScreenCover(item: $previewItem) { item in
            WorkspaceFilePreviewView(item: item)
                .onDisappear {
                    guard let directory = item.temporaryDirectory else { return }
                    try? FileManager.default.removeItem(at: directory)
                }
        }
        .alert("ファイルを開けませんでした", isPresented: errorBinding) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "時間をおいて、もう一度お試しください。")
        }
    }

    private var workspaceContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                transparencyCard
                breadcrumbBar

                if shownEntries.isEmpty {
                    ContentUnavailableView(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "このフォルダは空です"
                            : "一致するファイルはありません",
                        systemImage: "folder"
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                }

                if !shownDirectories.isEmpty {
                    WorkspaceSectionHeader(title: "フォルダ", count: shownDirectories.count)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(shownDirectories) { entry in
                            WorkspaceFolderCard(entry: entry) {
                                Task { await open(entry) }
                            }
                        }
                    }
                }

                if !shownFiles.isEmpty {
                    WorkspaceSectionHeader(title: "ファイル", count: shownFiles.count)
                    LazyVStack(spacing: 10) {
                        ForEach(shownFiles) { entry in
                            Button {
                                Task { await open(entry) }
                            } label: {
                                WorkspaceFileRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if listing?.truncated == true || searchTruncated {
                    Label("表示件数に上限があります。", systemImage: "info.circle")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 36)
            .struisRefreshable {
                isRefreshing = true
                defer { isRefreshing = false }
                await loadDirectory(path: listing?.path ?? "")
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .overlay {
            if isLoading && !isRefreshing {
                ProgressView().progressViewStyle(StruisProgressViewStyle())
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var transparencyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent(scheme))
                .frame(width: 34, height: 34)
                .background(Theme.accent(scheme).opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("Workspaceの内容")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))
                Text("AIが参照できるファイルと、Struisが保存している学習データを確認できます。")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(breadcrumbs, id: \.path) { crumb in
                    if crumb.path != "" {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary(scheme))
                    }
                    Button(crumb.label) {
                        Task { await loadDirectory(path: crumb.path) }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(crumb.path == listing?.path ? Theme.textPrimary(scheme) : Theme.accent(scheme))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                }
            }
        }
        .accessibilityLabel("現在のフォルダ")
    }

    private var breadcrumbs: [(label: String, path: String)] {
        let parts = listing?.path.split(separator: "/").map(String.init) ?? []
        return [("Workspace", "")] + parts.enumerated().map { index, part in
            (part, parts.prefix(index + 1).joined(separator: "/"))
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func loadDirectory(path: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            listing = try await api.send(.workspaceListing(path: path))
            searchText = ""
            searchResults = nil
            searchTruncated = false
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Workspaceを読み込めませんでした。"
        }
    }

    private func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            searchTruncated = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            let response: WorkspaceSearchResultsDTO = try await api.send(.workspaceSearch(query: query))
            guard !Task.isCancelled else { return }
            searchResults = response.entries
            searchTruncated = response.truncated
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "ファイルを検索できませんでした。"
        }
    }

    private func open(_ entry: WorkspaceEntryDTO) async {
        if entry.kind == .directory {
            await loadDirectory(path: entry.path)
            return
        }
        guard entry.downloadable else {
            errorMessage = "25MBを超えるため、内容は表示できません。"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await api.fetchData(.workspaceContent(path: entry.path))
            if entry.previewKind == .text {
                guard let text = String(data: response.data, encoding: .utf8) else {
                    errorMessage = "このファイルはUTF-8テキストとして表示できません。"
                    return
                }
                previewItem = WorkspacePreviewItem(entry: entry, text: text, url: nil, temporaryDirectory: nil)
                return
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("struis-workspace-preview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let fileURL = directory.appendingPathComponent(entry.name)
            try response.data.write(to: fileURL, options: .atomic)
            previewItem = WorkspacePreviewItem(entry: entry, text: nil, url: fileURL, temporaryDirectory: directory)
        } catch {
            errorMessage = "ファイルを開けませんでした。"
        }
    }

}

private struct WorkspaceSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            Text("\(count)項目")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WorkspaceFolderCard: View {
    let entry: WorkspaceEntryDTO
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Theme.accent(scheme))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
                .padding(.bottom, 12)
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .lineLimit(2)
                if entry.category == .struisManaged {
                    Text("Struisのデータ")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent(scheme))
                }
                Text("フォルダ · \(entry.modifiedAt.formatted(date: .abbreviated, time: .omitted)) · サイズなし")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Theme.separator(scheme), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

private struct WorkspaceFileRow: View {
    let entry: WorkspaceEntryDTO
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: fileSymbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.accent(scheme))
                .frame(width: 42, height: 42)
                .background(Theme.accent(scheme).opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if entry.category == .struisManaged {
                        Text("Struisのデータ")
                            .foregroundStyle(Theme.accent(scheme))
                    }
                    Text(fileKindLabel)
                    Text(entry.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    if let size = entry.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary(scheme))
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary(scheme))
        }
        .padding(13)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17))
        .overlay {
            RoundedRectangle(cornerRadius: 17)
                .strokeBorder(Theme.separator(scheme), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 17))
    }

    private var fileSymbol: String {
        switch entry.previewKind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .audio: "waveform"
        case .video: "film"
        default: "doc.text"
        }
    }

    private var fileKindLabel: String {
        switch entry.name.split(separator: ".").last?.lowercased() {
        case "md", "markdown": "Markdown"
        case "json": "JSON"
        case "yaml", "yml": "YAML"
        case "csv": "CSV"
        default:
            switch entry.previewKind {
            case .text: "テキスト"
            case .pdf: "PDF"
            case .image: "画像"
            case .audio: "音声"
            case .video: "動画"
            default: "ファイル"
            }
        }
    }
}

private struct WorkspacePreviewItem: Identifiable {
    let id = UUID()
    let entry: WorkspaceEntryDTO
    let text: String?
    let url: URL?
    let temporaryDirectory: URL?
}

private struct WorkspaceFilePreviewView: View {
    let item: WorkspacePreviewItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            Group {
                if let text = item.text {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Theme.accent(scheme))
                                    .frame(width: 42, height: 42)
                                    .background(Theme.accent(scheme).opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("テキストファイル")
                                        .font(.subheadline.weight(.semibold))
                                    Text(previewMetadata)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            Text(text)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .background(Color(uiColor: .systemBackground))
                } else if let url = item.url {
                    QuickLookView(url: url)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(item.entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("閉じる")
                }
                if let url = item.url {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("共有")
                    }
                }
            }
        }
    }

    private var previewMetadata: String {
        let size = item.entry.sizeBytes.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? "サイズ不明"
        return "\(size) · \(item.entry.modifiedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

#Preview {
    NavigationStack {
        WorkspaceBrowserView()
    }
    .environment(APIClient())
}
