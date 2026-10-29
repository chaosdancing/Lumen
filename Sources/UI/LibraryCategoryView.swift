import SwiftUI

/// 先展示分类桶，点击后再进入该分类的影片列表。
struct LibraryCategoryView: View {
    let kind: LibraryQuery.CategoryKind

    @EnvironmentObject private var store: AppStore
    @ObservedObject private var metadata = MetadataStore.shared
    #if os(iOS)
    @EnvironmentObject private var nav: NavModel
    #endif

    var body: some View {
        let snapshot = LibrarySnapshot(store: store, metadata: metadata)
        let categories = LibraryQuery.categories(snapshot.items, kind: kind)
        let entries = Dictionary(snapshot.entries.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if categories.isEmpty {
                    EmptyStateView(symbol: kind.symbol, title: "没有内容",
                                   message: "扫描媒体源后，分类会显示在这里。",
                                   actionTitle: nil, action: nil)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 380), spacing: 18)],
                              spacing: 18) {
                        ForEach(categories) { category in
                            let posters = category.previewIDs.compactMap { entries[$0]?.posterItem }
                            #if os(iOS)
                            Button { nav.open(.category(category.selection)) } label: {
                                card(category, posters: posters)
                            }
                            .buttonStyle(.plain)
                            #else
                            NavigationLink(value: BrowseRoute.category(category.selection)) {
                                card(category, posters: posters)
                            }
                            .buttonStyle(.plain)
                            #endif
                        }
                    }
                }
            }
            .padding(22)
        }
        .navigationTitle(kind.title)
        .task(id: kind) {
            await metadata.scrapeAll(items: store.library, in: store)
        }
    }

    private func card(_ category: LibraryQuery.CategoryCount, posters: [MediaItem]) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.24),
                                              Color.primary.opacity(0.06)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(spacing: 0) {
                ZStack {
                    if posters.isEmpty {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        ForEach(Array(posters.enumerated()), id: \.element.id) { index, item in
                            ArtworkView(item: item, cornerRadius: 7)
                                .frame(width: 78, height: 116)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                                }
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 5)
                                .rotationEffect(.degrees(rotation(index, count: posters.count)))
                                .offset(x: posterOffset(index, count: posters.count),
                                        y: index == 0 ? 3 : 8)
                                .zIndex(index == 0 ? 3 : Double(2 - index))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 148)
                Spacer(minLength: 0)
            }

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(category.selection.title)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(2)
                    Text(kind == .years
                         ? "\(category.count) 部电影"
                         : "\(category.count) 部电影 / 剧集")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 226)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(category.selection.title)，\(category.count) 部\(kind == .years ? "电影" : "电影或剧集")")
    }

    private func posterOffset(_ index: Int, count: Int) -> CGFloat {
        guard count > 1, index > 0 else { return count == 2 ? -16 : 0 }
        return index == 1 ? (count == 2 ? 22 : -47) : 47
    }

    private func rotation(_ index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        if count == 2 { return index == 0 ? -7 : 9 }
        return index == 0 ? 0 : (index == 1 ? -12 : 12)
    }
}
