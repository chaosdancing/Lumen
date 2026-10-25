import SwiftUI

/// 文件浏览：像 VidHub 那样点文件源直接进目录树
struct FolderRoute: Hashable {
    let path: String
}

struct FileBrowserView: View {
    let source: MediaSourceConfig

    var body: some View {
        FolderList(source: source, path: "")
            .navigationDestination(for: FolderRoute.self) { route in
                FolderList(source: source, path: route.path)
            }
    }
}

struct FolderList: View {
    let source: MediaSourceConfig
    let path: String

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerPresenter

    @State private var entries: [RemoteEntry] = []
    @State private var errorText: String?
    @State private var loading = true
    @State private var newestFirst = true

    private var sortedEntries: [RemoteEntry] {
        let dirs = entries.filter(\.isDirectory)
        let files = entries.filter { !$0.isDirectory }
        let name: (RemoteEntry, RemoteEntry) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return newestFirst ? dirs.sorted(by: name) + files.sorted(by: name)
                           : dirs.sorted(by: name) + files.sorted(by: name)
    }

    var body: some View {
        Group {
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                EmptyStateView(symbol: "exclamationmark.triangle",
                               title: "打不开这个目录",
                               message: errorText,
                               actionTitle: "重试", action: { Task { await load() } })
            } else if entries.isEmpty {
                EmptyStateView(symbol: "folder",
                               title: "空目录",
                               message: "这里没有可显示的文件。",
                               actionTitle: nil, action: nil)
            } else {
                List {
                    ForEach(sortedEntries, id: \.path) { entry in
                        if entry.isDirectory {
                            NavigationLink(value: FolderRoute(path: entry.path)) {
                                row(entry)
                            }
                        } else if MediaFileType.isVideo(entry.name) {
                            Button {
                                play(entry)
                            } label: {
                                row(entry)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("播放") { play(entry) }
                            }
                        } else {
                            row(entry)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .task(id: path) { await load() }
        .navigationTitle(path.isEmpty ? source.name : (path as NSString).lastPathComponent)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await load() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func row(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" :
                    (MediaFileType.isVideo(entry.name) ? "film" : "doc"))
                .font(.system(size: 17))
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let size = entry.size, !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if entry.isDirectory {
                    Text("文件夹")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func play(_ entry: RemoteEntry) {
        guard !entry.isDirectory, MediaFileType.isVideo(entry.name) else { return }
        let item = MediaItemParser.parse(entry: entry, sourceID: source.id)
        player.play(item)
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let src = try MediaSourceFactory.make(source)
            let list = try await src.list(path: path)
            entries = list
            let shownPath = path.isEmpty ? "/" : path
            AppLog.info("文件浏览 \(source.name):\(shownPath) → \(list.count) 项")
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.error("文件浏览失败 \\(path)：\\(error.logDescription)")
        }
    }
}
