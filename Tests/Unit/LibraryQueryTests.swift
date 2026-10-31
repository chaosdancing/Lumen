import XCTest
@testable import Lumen

final class LibraryQueryTests: XCTestCase {
    func testCarouselRecommendationsPrioritizeContinueWatching() {
        let now = Date()
        let continuing = LibraryQuery.Item(
            id: "continuing", title: "续播",
            addedAt: now.addingTimeInterval(-86_400),
            isContinuing: true, lastPlayedAt: now
        )
        let favorite = LibraryQuery.Item(
            id: "favorite", title: "收藏",
            addedAt: now.addingTimeInterval(-86_400),
            isFavorite: true
        )
        let unwatched = LibraryQuery.Item(
            id: "unwatched", title: "未看",
            rating: 9.9, addedAt: now
        )
        let watched = LibraryQuery.Item(
            id: "watched", title: "已看",
            rating: 10, addedAt: now, isWatched: true
        )

        let picks = LibraryQuery.carouselRecommendations(
            [watched, unwatched, favorite, continuing], limit: 4, now: now
        )

        XCTAssertEqual(picks.map(\.id), ["continuing", "favorite", "unwatched", "watched"])
    }

    func testCarouselRecommendationsRespectLimit() {
        let now = Date()
        let items = (0..<12).map { index in
            LibraryQuery.Item(id: "item-\(index)", title: "Item \(index)", addedAt: now)
        }
        XCTAssertEqual(LibraryQuery.carouselRecommendations(items, limit: 8, now: now).count, 8)
        XCTAssertTrue(LibraryQuery.carouselRecommendations(items, limit: 0, now: now).isEmpty)
    }
}
