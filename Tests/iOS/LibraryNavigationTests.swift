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
        XCTAssertTrue(app.buttons["library.categories"].waitForExistence(timeout: 5))
        app.buttons["library.categories"].tap()
        app.buttons["媒体库"].firstMatch.tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "iPad 横屏首页"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCUIDevice.shared.orientation = .portrait
    }

    func testTopLevelCategoriesAndSearch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let categories = app.buttons["library.categories"]
        XCTAssertTrue(categories.waitForExistence(timeout: 20))

        // iPad 顶栏快捷入口：年代 / 评分 / 分级 / 类型
        for title in ["年代", "评分", "分级", "类型"] {
            let chip = app.buttons["library.quick.\(title)"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5), title)
            chip.tap()
            XCTAssertTrue(categories.waitForExistence(timeout: 5))
            XCTAssertTrue(categories.label.contains(title))
        }

        // 分类菜单仍保留电影 / 电视剧 / 媒体库等入口
        for title in ["电影", "电视剧", "媒体库"] {
            categories.tap()
            let choice = app.buttons[title].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), title)
            choice.tap()
            XCTAssertTrue(categories.waitForExistence(timeout: 5))
            XCTAssertTrue(categories.label.contains(title))
        }

        let search = app.buttons["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let field = app.textFields["搜索媒体库"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("NoSuchFilm123456")
        XCTAssertTrue(app.staticTexts["没有内容"].waitForExistence(timeout: 5))
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(app.staticTexts["推荐观看 · 继续观看优先，其次未看高分与最近添加"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPadSectionMenuConsolidatesSourcesServersSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let categories = app.buttons["library.categories"]
        XCTAssertTrue(categories.waitForExistence(timeout: 20))

        // 文件源 / 服务器 / 设置收进左侧下拉
        categories.tap()
        let menuShot = XCTAttachment(screenshot: app.screenshot())
        menuShot.name = "iPad 顶栏下拉菜单"
        menuShot.lifetime = .keepAlways
        add(menuShot)
        app.buttons["文件源"].firstMatch.tap()
        let sections = app.buttons["app.sections"]
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
        app.buttons["媒体库"].firstMatch.tap()
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
        XCTAssertTrue(categories.label.contains("媒体库"))
    }

}
