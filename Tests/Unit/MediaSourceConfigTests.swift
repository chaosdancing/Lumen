import XCTest
@testable import Lumen

final class MediaSourceConfigTests: XCTestCase {
    func testPastedHTTPURLKeepsExplicitPortField() {
        var source = MediaSourceConfig(kind: .webdav, name: "NAS")
        source.host = "http://192.168.3.29/video"
        source.port = 5005
        source.basePath = "/video"

        let result = source.normalized()
        XCTAssertEqual(result.host, "192.168.3.29")
        XCTAssertEqual(result.port, 5005)
        XCTAssertFalse(result.usesHTTPS)
        XCTAssertEqual(result.basePath, "/video")
    }

    func testPastedHTTPURLUsesItsPortWhenPortFieldIsEmpty() {
        var source = MediaSourceConfig(kind: .webdav, name: "NAS")
        source.host = "http://192.168.3.29:5005/video"
        source.port = 0

        let result = source.normalized()
        XCTAssertEqual(result.host, "192.168.3.29")
        XCTAssertEqual(result.port, 5005)
        XCTAssertFalse(result.usesHTTPS)
        XCTAssertEqual(result.basePath, "/video")
    }
}
