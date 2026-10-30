import XCTest

final class LibraryNavigationTests: XCTestCase {
    func testCarouselSwipeAndRotation() throws {
        let app = XCUIApplication()
        app.launch()
        let carousel = app.descendants(matching: .any)["library.carousel"].firstMatch
        guard carousel.waitForExistence(timeout: 10) else {
            throw XCTSkip("此测试需要媒体库中至少两条内容且启用轮播")
        }
        let page = app.descendants(matching: .any)["library.carousel.page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let original = page.value as? String
        carousel.swipeLeft()
        let changed = NSPredicate { _, _ in (page.value as? String) != original }
        expectation(for: changed, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["app.sections"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "iPad 横屏首页"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCUIDevice.shared.orientation = .portrait
    }

    func testLibraryAndPreferencesQuickLinks() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let sections = app.buttons["app.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 20))
        XCTAssertTrue(sections.label.contains("媒体库"))

        // 媒体库：继续观看 / 电影 / 电视剧
        for title in ["继续观看", "电影", "电视剧"] {
            XCTAssertTrue(app.buttons["library.quick.\(title)"].waitForExistence(timeout: 5), title)
        }
        app.buttons["library.quick.电影"].tap()
        XCTAssertTrue(app.buttons["browse.options"].waitForExistence(timeout: 5))
        let movieShot = XCTAttachment(screenshot: app.screenshot())
        movieShot.name = "iPad 电影顶栏"
        movieShot.lifetime = .keepAlways
        add(movieShot)

        // 再次选择「媒体库」应回到媒体库首页（首页没有排序/筛选菜单）
        sections.tap()
        app.buttons["媒体库"].firstMatch.tap()
        XCTAssertTrue(app.buttons["browse.options"].waitForNonExistence(timeout: 5))

        // 偏好：类型 / 年代 / 评分 / 分级 / 收藏夹
        sections.tap()
        app.buttons["偏好"].firstMatch.tap()
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        XCTAssertTrue(sections.label.contains("偏好"))
        for title in ["类型", "年代", "评分", "分级", "收藏夹"] {
            XCTAssertTrue(app.buttons["preferences.quick.\(title)"].waitForExistence(timeout: 5), title)
        }
        let prefShot = XCTAttachment(screenshot: app.screenshot())
        prefShot.name = "iPad 偏好"
        prefShot.lifetime = .keepAlways
        add(prefShot)

        app.buttons["preferences.quick.类型"].tap()
        XCTAssertTrue(app.staticTexts["按已缓存的影视类型浏览。"].waitForExistence(timeout: 5))
        app.buttons["preferences.quick.收藏夹"].tap()
        XCTAssertTrue(app.buttons["browse.options"].waitForExistence(timeout: 5))

        // 搜索按钮保持在右上角
        let search = app.buttons["preferences.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let field = app.textFields["搜索媒体库"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("NoSuchFilm123456")
        XCTAssertTrue(app.staticTexts["没有内容"].waitForExistence(timeout: 5))
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(app.staticTexts["推荐观看 · 继续观看优先，其次未看高分与最近添加"].exists)
    }

    func testPadSectionMenuConsolidatesSourcesServersSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let sections = app.buttons["app.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 20))
        XCTAssertTrue(sections.label.contains("媒体库"))

        // 下拉包含 媒体库 / 偏好 / 文件源 / 服务器 / 设置
        sections.tap()
        let menuShot = XCTAttachment(screenshot: app.screenshot())
        menuShot.name = "iPad 顶栏下拉菜单"
        menuShot.lifetime = .keepAlways
        add(menuShot)
        app.buttons["文件源"].firstMatch.tap()
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        XCTAssertTrue(sections.label.contains("文件源"))
        let sourcesShot = XCTAttachment(screenshot: app.screenshot())
        sourcesShot.name = "iPad 文件源"
        sourcesShot.lifetime = .keepAlways
        add(sourcesShot)

        sections.tap()
        app.buttons["设置"].firstMatch.tap()
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        XCTAssertTrue(sections.label.contains("设置"))
        let settingsShot = XCTAttachment(screenshot: app.screenshot())
        settingsShot.name = "iPad 设置"
        settingsShot.lifetime = .keepAlways
        add(settingsShot)

        sections.tap()
        app.buttons["偏好"].firstMatch.tap()
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        XCTAssertTrue(sections.label.contains("偏好"))
        XCTAssertTrue(app.buttons["preferences.quick.类型"].waitForExistence(timeout: 5))

        sections.tap()
        app.buttons["媒体库"].firstMatch.tap()
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        XCTAssertTrue(sections.label.contains("媒体库"))
        XCTAssertTrue(app.buttons["library.quick.电影"].waitForExistence(timeout: 5))
    }
}
