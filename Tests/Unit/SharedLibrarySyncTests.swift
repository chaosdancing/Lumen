import XCTest
@testable import Lumen

final class SharedLibrarySyncTests: XCTestCase {
    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }
    private var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }

    func testMetadataCatalogRoundTripKeepsPortableFields() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var meta = MediaMetadata(itemID: "old-source#movies/a.mkv")
        meta.title = "耳をすませは"
        meta.originalTitle = "耳をすませば"
        meta.seriesTitle = "侧耳倾听"
        meta.overview = "示例简介"
        meta.rating = 8.1
        meta.genres = ["动画", "剧情"]
        meta.cast = [CastMember(tmdbID: 1, name: "本名", role: "主角")]
        meta.releaseDate = "1995-07-15"
        meta.certification = "PG"
        meta.runtimeMinutes = 111
        meta.mediaType = "movie"
        meta.tmdbID = 12345
        meta.updatedAt = date

        var catalog = SharedMetadataCatalog()
        catalog.updatedAt = date
        catalog.entries["movies/a.mkv"] = SharedMetadataEntry(meta: meta)

        let decoded = try decoder.decode(SharedMetadataCatalog.self, from: encoder.encode(catalog))
        XCTAssertEqual(decoded.schema, 1)
        let entry = try XCTUnwrap(decoded.entries["movies/a.mkv"])
        let item = MediaItem(id: "new-source#movies/a.mkv",
                             sourceID: UUID(),
                             path: "movies/a.mkv",
                             fileName: "a.mkv",
                             title: "a",
                             seriesTitle: nil,
                             season: nil,
                             episode: nil,
                             year: 1995,
                             size: nil)
        let rebuilt = entry.metadata(for: item, sourceFingerprint: "fingerprint",
                                     cacheVersion: 3, preferNFO: false, language: "zh-CN")
        XCTAssertEqual(rebuilt.title, "耳をすませは")
        XCTAssertEqual(rebuilt.genres, ["动画", "剧情"])
        XCTAssertEqual(rebuilt.rating, 8.1)
        XCTAssertEqual(rebuilt.releaseDate, "1995-07-15")
        XCTAssertEqual(rebuilt.tmdbID, 12345)
        XCTAssertEqual(rebuilt.source, "shared")
        XCTAssertEqual(rebuilt.sourceFingerprint, "fingerprint")
        XCTAssertEqual(rebuilt.itemID, item.id)
    }


    func testLocalSourceWriteSharedOverwrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var config = MediaSourceConfig(kind: .local, name: "temp")
        config.basePath = directory.path
        let source = try LocalMediaSource(config: config)
        let path = ".lumen-cache/library-metadata.json"

        try await source.writeShared(Data("first".utf8), path: path)
        try await source.writeShared(Data("second".utf8), path: path)
        let data = try await source.data(for: path)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "second")
    }

    func testLibraryStateRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var state = SharedLibraryState()
        state.updatedAt = date
        state.progress["movies/a.mkv"] = SharedProgress(position: 42, duration: 100, updatedAt: date)
        state.favorites["movies/a.mkv"] = SharedFavorite(favorite: true, updatedAt: date)

        let decoded = try decoder.decode(SharedLibraryState.self, from: encoder.encode(state))
        XCTAssertEqual(decoded.schema, 1)
        XCTAssertEqual(decoded.progress["movies/a.mkv"]?.position, 42)
        XCTAssertEqual(decoded.progress["movies/a.mkv"]?.duration, 100)
        XCTAssertEqual(decoded.favorites["movies/a.mkv"]?.favorite, true)
    }
}
