import SwiftUI

extension Notification.Name {
    static let lumenFind = Notification.Name("lumen.find")
}

struct LibrarySearchView: View {
    @State private var query = ""
    @FocusState private var focused: Bool
    var focusRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称、原名、剧名或已缓存的演员", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .accessibilityLabel("搜索媒体库")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 22)
            .padding(.top, 14)
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "推荐观看 · 继续观看优先，其次未看高分与最近添加"
                 : "仅搜索媒体库内已缓存的信息，不会在线刮削")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
            BrowseView(destination: .search, searchText: query)
        }
        .navigationTitle("搜索")
        .onAppear { focused = true }
        .onChange(of: focusRequest) { _, _ in focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .lumenFind)) { _ in focused = true }
    }
}
