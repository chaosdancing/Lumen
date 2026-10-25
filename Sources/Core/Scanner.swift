import Foundation

/// 文件名 → 结构化条目。规则参考常见命名约定，不联网、不依赖 TMDB。
enum MediaItemParser {

    private static let releaseNoise: [String] = [
        "1080p", "2160p", "720p", "480p", "4k", "uhd", "hdr", "hdr10", "dv", "dolbyvision",
        "bluray", "blu-ray", "bdrip", "brrip", "webrip", "web-dl", "webdl", "hdtv", "dvdrip",
        "x264", "x265", "h264", "h265", "hevc", "avc", "10bit", "8bit", "aac", "ac3", "dts",
        "truehd", "atmos", "remux", "proper", "repack", "extended", "unrated", "internal"
    ]

    /// S01E02 / s1e2 / 1x02
    /// 关键：两侧加数字边界。否则 `1280x720` 里的 "80x720" 会被当成 S80E720。
    private static let seasonEpisode = try! NSRegularExpression(
        pattern: "(?i)(?<![0-9])(?:s(\\d{1,2})[ ._-]?e(\\d{1,3})|(\\d{1,2})x(\\d{1,3}))(?![0-9])"
    )
    /// 第01集 / 第01话
    private static let chineseEpisode = try! NSRegularExpression(pattern: "第\\s*(\\d{1,3})\\s*[集话話]")
    /// 单独一季目录：Season 1 / S01 / 第一季
    /// `S01` / `Season 1` / `Better.Call.Saul.S01` 都算季目录
    /// 季目录：`S01` / `Season 1` / `Westworld (2016) Season 1 S01 (1080p ...)` / `Westworld.S04.1080p`
    /// 注意要排除 `S01-S04` 这种"季区间"，那是剧集根目录不是季目录。
    private static let seasonRange = try! NSRegularExpression(
        pattern: "(?i)(?:^|[. _-])s\\d{1,2}\\s*[-~]\\s*s?\\d{1,2}(?:[. _-]|$)"
    )
    private static let seasonAnywhere = try! NSRegularExpression(
        pattern: "(?i)\\bseason\\s*[._-]?\\s*(\\d{1,2})\\b"
    )
    private static let seasonShort = try! NSRegularExpression(
        pattern: "(?i)(?:^|[^a-z0-9])s(\\d{1,2})(?:[^a-z0-9]|$)"
    )
    private static let chineseSeason = try! NSRegularExpression(pattern: "^第\\s*([一二三四五六七八九十\\d]{1,3})\\s*季$")
    /// 年份 19xx / 20xx
    private static let yearRegex = try! NSRegularExpression(pattern: "(?<![0-9])(19\\d{2}|20\\d{2})(?![0-9])")

    static func parse(entry: RemoteEntry, sourceID: UUID) -> MediaItem {
        let fileName = entry.name
        let stem = (fileName as NSString).deletingPathExtension

        var series: String?
        var season: Int?
        var episode: Int?
        var titlePrefix = ""

        let range = NSRange(stem.startIndex..., in: stem)
        if let m = seasonEpisode.firstMatch(in: stem, range: range) {
            if m.range(at: 1).location != NSNotFound {
                season = Int((stem as NSString).substring(with: m.range(at: 1)))
                episode = Int((stem as NSString).substring(with: m.range(at: 2)))
            } else {
                season = Int((stem as NSString).substring(with: m.range(at: 3)))
                episode = Int((stem as NSString).substring(with: m.range(at: 4)))
            }
            titlePrefix = (stem as NSString).substring(to: m.range.location)
        } else if let m = chineseEpisode.firstMatch(in: stem, range: range) {
            episode = Int((stem as NSString).substring(with: m.range(at: 1)))
            titlePrefix = (stem as NSString).substring(to: m.range.location)
        }

        // 合理性兜底：季 > 40 或集 > 1000 基本是把分辨率/码率当成了季集
        if let s = season, s > 40 { season = nil; episode = nil }
        if let e = episode, e > 1000 { season = nil; episode = nil }

        if episode != nil {
            // 目录层级：…/剧名/季/SxxEyy.mkv → 剧名取"季"的上一级；否则退回文件名前缀
            let comps = entry.path.split(separator: "/").map(String.init)
            let parent = comps.count >= 2 ? comps[comps.count - 2] : ""
            let grand = comps.count >= 3 ? comps[comps.count - 3] : ""

            let parentIsSeason = seasonFromFolder(parent) != nil
            let parentIsGeneric = isGenericFolder(parent)

            var candidate: String?
            if parentIsSeason {
                if !grand.isEmpty && !isGenericFolder(grand) {
                    candidate = cleanTitle(grand)
                } else {
                    let derived = showNameFromSeasonFolder(parent)
                    candidate = derived.isEmpty ? nil : derived
                }
            } else if !parentIsGeneric && !parent.isEmpty {
                candidate = cleanTitle(parent)
            }
            if candidate == nil || candidate!.isEmpty {
                let fromName = cleanTitle(titlePrefix)
                candidate = fromName.isEmpty ? nil : fromName
            }
            series = candidate
            if season == nil { season = seasonFromFolder(parent) ?? 1 }
        }

        var title: String
        var year: Int?
        if series != nil {
            title = stem
            if let s = season, let e = episode {
                title = String(format: "S%02dE%02d", s, e)
            }
        } else {
            var cleaned = cleanTitle(stem)
            year = extractYear(stem)
            if cleaned.isEmpty {
                let comps = entry.path.split(separator: "/").map(String.init)
                let parent = comps.count >= 2 ? comps[comps.count - 2] : ""
                cleaned = cleanTitle(parent)
            }
            title = cleaned
        }

        return MediaItem(
            id: "\(sourceID.uuidString)#\(entry.path)",
            sourceID: sourceID,
            path: entry.path,
            fileName: fileName,
            title: title.isEmpty ? stem : title,
            seriesTitle: series,
            season: season,
            episode: episode,
            year: year,
            size: entry.size
        )
    }

    /// 花絮/特典/样片目录，扫描时整目录跳过（否则会被当成一部剧）
    static func isJunkFolder(_ name: String) -> Bool {
        let junk: Set<String> = [
            "extras", "extra", "featurettes", "featurette", "behind the scenes",
            "sample", "samples", "trailers", "trailer", "screenshots", "subs", "subtitles",
            "花絮", "特典", "预告", "预告片", "样片", "字幕", "截图", "其他"
        ]
        return junk.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// "Movies" / "TV" / "视频" 这类容器目录，不能当剧名
    private static func isGenericFolder(_ name: String) -> Bool {
        let generic: Set<String> = [
            "movies", "movie", "films", "film", "tv", "tv shows", "tvshows", "shows",
            "videos", "video", "media", "downloads", "download", "anime", "series",
            "episodes", "episode", "seasons", "complete", "collection",
            "电影", "影片", "视频", "剧集", "电视剧", "动画", "下载", "媒体", "影视",
            "番剧", "综艺", "纪录片", "合集", "其他"
        ]
        return generic.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func seasonFromFolder(_ name: String) -> Int? {
        guard !name.isEmpty else { return nil }
        let range = NSRange(name.startIndex..., in: name)

        // `S01-S04` 是季区间，属于剧集根目录，不是季目录
        if seasonRange.firstMatch(in: name, range: range) != nil { return nil }

        if let m = seasonAnywhere.firstMatch(in: name, range: range),
           m.range(at: 1).location != NSNotFound {
            return Int((name as NSString).substring(with: m.range(at: 1)))
        }
        if let m = seasonShort.firstMatch(in: name, range: range),
           m.range(at: 1).location != NSNotFound {
            return Int((name as NSString).substring(with: m.range(at: 1)))
        }
        if let m = chineseSeason.firstMatch(in: name, range: range) {
            let raw = (name as NSString).substring(with: m.range(at: 1))
            return Int(raw) ?? chineseNumber(raw)
        }
        return nil
    }

    /// 从季目录名反推剧名：`Westworld (2016) Season 1 S01 (1080p ...)` → `Westworld`
    static func showNameFromSeasonFolder(_ name: String) -> String {
        var head = name
        let range = NSRange(name.startIndex..., in: name)
        if let m = seasonAnywhere.firstMatch(in: name, range: range) {
            head = String(name[..<Range(m.range, in: name)!.lowerBound])
        } else if let m = seasonShort.firstMatch(in: name, range: range) {
            head = String(name[..<Range(m.range, in: name)!.lowerBound])
        } else if let m = chineseSeason.firstMatch(in: name, range: range) {
            head = String(name[..<Range(m.range, in: name)!.lowerBound])
        }
        return cleanTitle(head)
    }

    private static func chineseNumber(_ s: String) -> Int? {
        let map: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                                     "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]
        if s == "十" { return 10 }
        if s.count == 1 { return map[s.first!] }
        if s.count == 2, s.hasSuffix("十"), let d = map[s.first!] { return d * 10 }
        if s.count == 3, s.hasPrefix("十"), let d = map[Array(s)[1]] { return 10 + d }
        return nil
    }

    private static func extractYear(_ s: String) -> Int? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = yearRegex.firstMatch(in: s, range: range) else { return nil }
        return Int((s as NSString).substring(with: m.range(at: 1)))
    }

    /// 去掉发布组标记、分辨率、编码等噪声
    /// 字幕/压片组常见标记：CHS-ENG-LxyLab、CHS_ENG、GB、BIG5、x264-GROUP…
    private static let junkToken = try! NSRegularExpression(
        pattern: "^(?:[A-Za-z]{2,4}(?:[-_][A-Za-z0-9]{2,})+|[A-Z]{2,4}[-_][A-Z0-9]{2,}|(?:chs|cht|eng|chi|jpn|kor|gb|big5|utf-?8|hevc|avc))$"
    )

    static func cleanTitle(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: ".", with: " ")
        // 去掉方括号/圆括号里的内容
        s = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)

        var tokens = s.split(separator: " ").map(String.init)
        tokens.removeAll { token in
            // 去掉 token 两侧的连字符/下划线，`-1080p` 也要能识别
            let core = token.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            let low = core.lowercased()
            if core.isEmpty { return true }
            if releaseNoise.contains(low) { return true }
            if low.hasPrefix("x26") || low.hasPrefix("h26") { return true }
            if low.hasSuffix("bit") { return true }
            if low.range(of: "^\\d{3,4}p$", options: .regularExpression) != nil { return true }
            // 1280x720 / 1024x576 这类分辨率
            if low.range(of: "^\\d{3,4}x\\d{3,4}$", options: .regularExpression) != nil { return true }
            // 年份（任意位置，不只是结尾）
            if low.range(of: "^(19|20)\\d{2}$", options: .regularExpression) != nil { return true }
            // 季区间标记：S01-S06 / S1-S6
            if low.range(of: "^s\\d{1,2}(-s?\\d{1,2})?$", options: .regularExpression) != nil { return true }
            // 音轨标记：FLAC / EAC3 / 2Audio / DDP5.1 / 5.1 / 7.1
            if low.range(of: "^[1-9]?audio$", options: .regularExpression) != nil { return true }
            if low.range(of: "^(flac|eac3|ac3|dts|truehd|atmos|opus|ddp\\d*|aac\\d*)$", options: .regularExpression) != nil { return true }
            // DTSHD-MA / DDP5.1-Atmos 这类带后缀的音轨标记
            if low.range(of: "^(dts|ddp|ac3|eac3|truehd|atmos|flac|aac)[a-z0-9.-]*$", options: .regularExpression) != nil { return true }
            if low.range(of: "^[257]\\.[01]$", options: .regularExpression) != nil { return true }
            // 字幕/组标记
            let range = NSRange(token.startIndex..., in: token)
            if junkToken.firstMatch(in: token, range: range) != nil { return true }
            return false
        }
        // 缩写还原：`R.I.P.D` 被点号拆成 ["R","I","P","D"]，连续 3 个以上单字符就粘回去
        var merged: [String] = []
        var run: [String] = []
        func flushRun() {
            if run.count >= 3 {
                merged.append(run.joined())
            } else {
                merged.append(contentsOf: run)
            }
            run.removeAll()
        }
        for token in tokens {
            if token.count == 1, token.first!.isLetter {
                run.append(token)
            } else {
                flushRun()
                merged.append(token)
            }
        }
        flushRun()

        var result = merged.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if let r = result.range(of: " - ", options: .backwards) {
            let tail = String(result[r.upperBound...])
            if tail.count <= 12 && !tail.contains(" ") { result = String(result[..<r.lowerBound]) }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " -"))
    }
}
