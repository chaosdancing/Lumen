import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingAdd = false
    @State private var editing: MediaSourceConfig?
    @State private var pendingDelete: MediaSourceConfig?

    var body: some View {
        List {
            Section {
                ForEach(store.sources) { source in
                    SourceRow(source: source,
                              state: store.scanState[source.id],
                              itemCount: store.library.filter { $0.sourceID == source.id }.count,
                              onScan: { Task { await store.scan(source) } },
                              onEdit: { editing = source })
                    .contextMenu {
                        Button("编辑…") { editing = source }
                        Button("重新扫描") { Task { await store.scan(source) } }
                        Button("删除", role: .destructive) { pendingDelete = source }
                    }
                }
                if store.sources.isEmpty {
                    Text("还没有媒体源。点右上角 + 添加。")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("当前可用：本地文件夹、WebDAV、在线直链、Emby / Jellyfin。SMB 待 AMSMB2 接入。")
                    .font(.caption)
            }
        }
        .navigationTitle("媒体源")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: { Label("添加", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddSourceSheet().environmentObject(store)
        }
        .sheet(item: $editing) { source in
            AddSourceSheet(editing: source).environmentObject(store)
        }
        .confirmationDialog("删除这个媒体源？",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { source in
            Button("删除「\(source.name)」", role: .destructive) {
                store.removeSource(source.id)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { source in
            Text("只会移除索引，不会删除磁盘上的文件。")
        }
    }
}

private struct SourceRow: View {
    let source: MediaSourceConfig
    let state: AppStore.ScanState?
    let itemCount: Int
    let onScan: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.kind.symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(source.kind.isAvailable ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.name).font(.body.weight(.medium))
                    if !source.kind.isAvailable {
                        Text("未实现").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(source.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let s = state, s.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("已找到 \(s.found)").font(.caption).foregroundStyle(.secondary)
                }
            } else if let s = state, let msg = s.message {
                Text(msg).font(.caption).foregroundStyle(.red).lineLimit(1)
            } else {
                Text("\(itemCount) 个视频").font(.caption).foregroundStyle(.secondary)
            }

            Button { onEdit() } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("编辑这个媒体源（端口/路径/密码）")

            Button("扫描", action: onScan)
                .buttonStyle(.bordered)
                .disabled(!source.kind.isAvailable || (state?.isScanning ?? false))
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 添加源

// MARK: - 添加 / 编辑媒体源

struct AddSourceSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    /// nil = 新增；有值 = 编辑既有源
    var editing: MediaSourceConfig?

    @State private var kind: SourceKind = .local
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var basePath = "/"
    @State private var username = ""
    @State private var password = ""
    @State private var usesHTTPS = false
    @State private var directURL = ""
    @State private var bookmark: Data?
    @State private var pickedFolderName = ""
    @State private var showPassword = false
    @State private var importing = false
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testPassed = false

    /// 从侧边栏「+ 添加文件源 / 添加影视服务器」进入时预设类型
    init(presetKind: SourceKind) {
        self.editing = nil
        _kind = State(initialValue: presetKind)
        switch presetKind {
        case .webdav:          _port = State(initialValue: "5005")
        case .smb:             _port = State(initialValue: "445")
        case .emby, .jellyfin: _port = State(initialValue: "8096")
        default:               _port = State(initialValue: "")
        }
    }

    init(editing: MediaSourceConfig? = nil) {
        self.editing = editing
        _kind = State(initialValue: editing?.kind ?? .webdav)
        _name = State(initialValue: editing?.name ?? "")
        _host = State(initialValue: editing?.host ?? "")
        _port = State(initialValue: (editing?.port ?? 0) == 0 ? "" : String(editing!.port))
        _basePath = State(initialValue: editing?.basePath ?? "/")
        _username = State(initialValue: editing?.username ?? "")
        _password = State(initialValue: editing?.password ?? "")
        _usesHTTPS = State(initialValue: editing?.usesHTTPS ?? false)
        _directURL = State(initialValue: editing?.directURL ?? "")
        _bookmark = State(initialValue: editing?.bookmark)
        _pickedFolderName = State(initialValue: editing?.bookmark == nil ? "" : "已授权的文件夹")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing == nil ? "添加媒体源" : "编辑媒体源")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    kindPicker
                    if kind == .smb {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle").font(.system(size: 12))
                                .foregroundStyle(.orange)
                            Text("SMB 需要 AMSMB2 依赖（当前环境拉不到包，尚未接入）。可以先填好保存，接入后即可扫描。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    fields
                    if let testMessage {
                        testBanner(testMessage)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            Divider().opacity(0.4)

            HStack(spacing: 10) {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.07), in: Capsule())

                Spacer()

                if testing { ProgressView().controlSize(.small) }

                Button("测试连接") { testConnection() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .disabled(!canSave || testing)

                Button("保存") { save() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .disabled(!canSave)
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 600)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { handleFolder($0) }
    }

    // MARK: 类型

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("类型").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(SourceKind.allCases) { k in
                    Button {
                        withAnimation(.smooth(duration: 0.16)) { switchKind(to: k) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: k.symbol).font(.system(size: 12))
                            Text(k.title).font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(kind == k ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(kind == k ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                        )
                        .foregroundStyle(kind == k ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 切类型时把上一个类型的专属字段清掉，避免 Emby 里带着 WebDAV 的端口/路径
    private func switchKind(to newKind: SourceKind) {
        guard newKind != kind else { return }
        let old = kind
        kind = newKind
        guard editing == nil else { return }     // 编辑已有源时保留原值

        if old.isMediaServer != newKind.isMediaServer || old != newKind {
            host = ""
            username = ""
            password = ""
            directURL = ""
            bookmark = nil
            pickedFolderName = ""
        }
        switch newKind {
        case .webdav:
            port = "5005"; basePath = "/"; usesHTTPS = false
        case .smb:
            port = "445"; basePath = "/"; usesHTTPS = false
        case .emby, .jellyfin:
            port = "8096"; basePath = "/"; usesHTTPS = false
        case .http:
            port = ""; basePath = "/"
        case .local:
            port = ""; basePath = "/"
        }
    }

    // MARK: 字段

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("名称") {
                TextField("例如：家里的 NAS", text: $name)
                    .textFieldStyle(.plain)
            }

            switch kind {
            case .local:
                HStack(spacing: 10) {
                    Text("文件夹").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .trailing)
                    Button(bookmark == nil ? "选择文件夹…" : pickedFolderName) { importing = true }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .font(.system(size: 12))
                }

            case .webdav, .smb:
                field("主机") {
                    TextField("IP 或域名（也可整条 URL 粘进来）", text: $host)
                        .textFieldStyle(.plain)
                }
                HStack(spacing: 12) {
                    field("端口", width: 150) {
                        TextField(kind == .webdav ? "5005" : "445", text: $port)
                            .textFieldStyle(.plain)
                    }
                    field("路径", width: 0) {
                        TextField("/video", text: $basePath)
                            .textFieldStyle(.plain)
                    }
                }
                Toggle(isOn: $usesHTTPS) {
                    Text("使用 HTTPS").font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

            case .emby, .jellyfin:
                field("主机") {
                    TextField("IP 或域名", text: $host).textFieldStyle(.plain)
                }
                field("端口") {
                    TextField("8096", text: $port).textFieldStyle(.plain)
                }
                Toggle(isOn: $usesHTTPS) {
                    Text("使用 HTTPS").font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

            case .http:
                field("地址") {
                    TextField("https://example.com/movie.mp4", text: $directURL)
                        .textFieldStyle(.plain)
                }
            }

            if kind == .webdav || kind == .smb || kind == .emby || kind == .jellyfin {
                field("用户名") {
                    TextField("用户名", text: $username).textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                field(kind.isMediaServer ? "API Key" : "密码") {
                    HStack(spacing: 6) {
                        if showPassword {
                            TextField("", text: $password).textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        } else {
                            SecureField("", text: $password).textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        }
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !password.isEmpty {
                    Text("\(password.count) 个字符")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 74)
                }
            }
        }
    }

    private func field<C: View>(_ label: String, width: CGFloat = 0,
                                @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .frame(width: width == 0 ? nil : width)
        }
    }

    private func testBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: testPassed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(testPassed ? Color.green : Color.red)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(testPassed ? Color.primary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 行为

    private var canSave: Bool {
        switch kind {
        case .local:  return bookmark != nil && !name.isEmpty
        case .webdav, .smb: return !host.isEmpty && !name.isEmpty
        case .emby, .jellyfin: return !host.isEmpty && !name.isEmpty && !password.isEmpty
        case .http:
            guard let url = URL(string: directURL), let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https"].contains(scheme) && url.host != nil && !name.isEmpty
        }
    }

    private func handleFolder(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkCreationOptions = [.minimalBookmark]
            #endif
            bookmark = try url.bookmarkData(options: options,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            pickedFolderName = url.lastPathComponent
            if name.isEmpty { name = url.lastPathComponent }
        } catch {
            testMessage = "无法授权该文件夹：\(error.localizedDescription)"
            testPassed = false
        }
    }

    private func makeConfig() -> MediaSourceConfig {
        var config = MediaSourceConfig(kind: kind, name: name.trimmingCharacters(in: .whitespaces))
        if let editing { config.id = editing.id }
        config.host = host.trimmingCharacters(in: .whitespaces)
        config.port = Int(port) ?? 0
        config.basePath = basePath.isEmpty ? "/" : basePath
        config.username = username
        config.password = password
        config.usesHTTPS = usesHTTPS
        config.directURL = directURL.trimmingCharacters(in: .whitespaces)
        config.bookmark = bookmark
        return config
    }

    private func save() {
        let config = makeConfig()
        let saved = editing != nil ? store.updateSource(config) : store.addSource(config)
        guard saved else {
            testPassed = false
            testMessage = "无法将密码保存到钥匙串，请检查应用签名后重试。"
            return
        }
        if config.kind == .http { Task { await store.scan(config) } }
        dismiss()
    }

    private func testConnection() {
        testing = true
        testMessage = nil
        let config = makeConfig().normalized()
        AppLog.info("测试连接 kind=\(config.kind.rawValue) host=\(config.host) port=\(config.port) path=\(config.basePath) https=\(config.usesHTTPS) user=\(config.username) pwdLen=\(config.password.count)")
        Task {
            do {
                let source = try MediaSourceFactory.make(config)
                if config.kind == .http {
                    guard let catalog = source as? CatalogSource else { throw SourceError.invalidURL }
                    _ = try await catalog.fetchCatalog()
                    testPassed = true
                    testMessage = "直链地址格式有效。播放时会连接服务器。"
                } else if let catalog = source as? CatalogSource {
                    let items = try await catalog.fetchCatalog()
                    testPassed = true
                    testMessage = "连接成功，媒体库 \(items.count) 个条目"
                } else {
                    let entries = try await source.list(path: "")
                    let dirs = entries.filter(\.isDirectory).count
                    testPassed = true
                    testMessage = "连接成功，根目录 \(entries.count) 项（\(dirs) 个文件夹 / \(entries.count - dirs) 个视频）"
                }
                AppLog.info("测试连接成功")
            } catch {
                testPassed = false
                var text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if let se = error as? SourceError, case .unauthorized = se {
                    text += "\n· 群晖：控制面板 → 用户与群组，确认该账号有 WebDAV 权限\n· 端口：WebDAV 默认 HTTP 5005 / HTTPS 5006"
                }
                if let se = error as? SourceError, case .badResponse(let status) = se,
                   [403, 405, 501, 502].contains(status) {
                    text += "\n· 这个端口上不是 WebDAV 服务（群晖 5005/5006，DSM 5000/5001）"
                }
                testMessage = text
                AppLog.error("测试连接失败：\(error.logDescription)")
            }
            testing = false
        }
    }
}

// MARK: - 文件源 / 影视服务器 管理页

struct SourceGroupView: View {
    let isServer: Bool

    @EnvironmentObject private var store: AppStore
    @State private var editing: MediaSourceConfig?
    @State private var adding = false

    private var list: [MediaSourceConfig] {
        store.sources.filter { $0.kind.isMediaServer == isServer }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(isServer ? "影视服务器" : "文件源")
                        .font(.system(size: 22, weight: .bold))
                    Spacer()
                    Button {
                        adding = true
                    } label: {
                        Label("添加", systemImage: "plus")
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }

                if list.isEmpty {
                    EmptyStateView(symbol: isServer ? "externaldrive.badge.plus" : "folder.badge.plus",
                                   title: isServer ? "还没有影视服务器" : "还没有文件源",
                                   message: isServer ? "添加 Emby 或 Jellyfin，填服务器地址与 API Key。"
                                                     : "添加本地文件夹、WebDAV 或 SMB。",
                                   actionTitle: nil, action: nil)
                } else {
                    VStack(spacing: 10) {
                        ForEach(list) { source in
                            row(source)
                        }
                    }
                }
            }
            .padding(26)
        }
        .navigationTitle(DeviceInfo.isPad ? "" : (isServer ? "影视服务器" : "文件源"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $adding) {
            AddSourceSheet(presetKind: isServer ? .jellyfin : .webdav)
                .environmentObject(store)
        }
        .sheet(item: $editing) { source in
            AddSourceSheet(editing: source).environmentObject(store)
        }
    }

    private func row(_ source: MediaSourceConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.system(size: 13.5, weight: .medium))
                Text(source.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(store.library.filter { $0.sourceID == source.id }.count) 条")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Button("编辑") { editing = source }
                .controlSize(.small)
            Button("扫描") { Task { await store.scan(source) } }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button("编辑…") { editing = source }
            Button("重新扫描") { Task { await store.scan(source) } }
            Button("删除", role: .destructive) { store.removeSource(source.id) }
        }
    }
}
