import Foundation

// MARK: - 字幕模型

struct SubtitleCue: Identifiable, Hashable {
    let id = UUID()
    var start: Double
    var end: Double
    var text: String

    func contains(_ t: Double) -> Bool { t >= start && t < end }
}

enum SubtitleFormat: String {
    case srt, ass, ssa, vtt
}

// MARK: - 解析

enum SubtitleParser {

    static func format(for path: String) -> SubtitleFormat? {
        SubtitleFormat(rawValue: (path as NSString).pathExtension.lowercased())
    }

    /// 带编码嗅探的文本解码：UTF-8 → UTF-16 → GB18030 → Latin1
    static func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf16LittleEndian), s.contains("\n") { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func parse(data: Data, path: String) -> [SubtitleCue] {
        let text = decodeText(data)
        switch format(for: path) {
        case .ass, .ssa: return parseASS(text)
        case .vtt:       return parseSRTLike(text, commaDecimal: false)
        default:         return parseSRTLike(text, commaDecimal: true)
        }
    }

    // MARK: SRT / VTT

    private static func parseSRTLike(_ text: String, commaDecimal: Bool) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timeLine = lines[timeLineIndex]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count >= 2 else { continue }
            let start = parseTimestamp(parts[0], commaDecimal: commaDecimal)
            let endRaw = parts[1].split(separator: " ").first.map(String.init) ?? parts[1]
            let end = parseTimestamp(endRaw, commaDecimal: commaDecimal)
            guard let s = start, let e = end, e > s else { continue }

            let body = lines[(timeLineIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: s, end: e, text: stripTags(body)))
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func parseTimestamp(_ raw: String, commaDecimal: Bool) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if !commaDecimal { s = s.replacingOccurrences(of: ".", with: ",") }
        s = s.replacingOccurrences(of: ".", with: ",")
        let parts = s.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }
        var seconds: Double = 0
        for (i, p) in parts.enumerated() {
            let isLast = i == parts.count - 1
            let value = Double(p.replacingOccurrences(of: ",", with: ".")) ?? 0
            seconds = seconds * 60 + value
            if isLast { break }
        }
        return seconds
    }

    // MARK: ASS / SSA

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var inEvents = false
        var textIndex = -1

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased().hasPrefix("[events]")
                continue
            }
            guard inEvents else { continue }

            if line.lowercased().hasPrefix("format:") {
                let fields = line.dropFirst("format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                textIndex = fields.firstIndex(of: "text") ?? -1
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }

            let payload = line.dropFirst("dialogue:".count)
            // Text 字段可能含逗号，按字段数切分
            var fields = payload.split(separator: ",", maxSplits: max(0, 9), omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 10 else { continue }
            if textIndex >= 0 && textIndex < fields.count - 1 {
                let head = fields[0..<textIndex]
                let tail = fields[textIndex...].joined(separator: ",")
                fields = Array(head) + [tail]
            }
            let start = parseASSTime(fields[1])
            let end = parseASSTime(fields[2])
            guard let s = start, let e = end, e > s else { continue }
            let body = fields.last ?? ""
            let cleaned = stripTags(body)
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            cues.append(SubtitleCue(start: s, end: e, text: cleaned))
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func parseASSTime(_ raw: String) -> Double? {
        // 0:00:01.50
        let parts = raw.components(separatedBy: ":")
        guard parts.count == 3 else { return nil }
        let h = Double(parts[0]) ?? 0
        let m = Double(parts[1]) ?? 0
        let s = Double(parts[2].replacingOccurrences(of: ",", with: ".")) ?? 0
        return h * 3600 + m * 60 + s
    }

    /// 去掉 HTML/ASS 内联样式标签
    private static func stripTags(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "<[^>]{1,12}>", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        out = out.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        return out
    }
}

// MARK: - 当前激活的 cue

enum SubtitleTimeline {
    static func activeIndex(in cues: [SubtitleCue], at time: Double) -> Int? {
        guard !cues.isEmpty else { return nil }
        // 二分：cue 已按 start 排序
        var low = 0, high = cues.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard var i = found else { return nil }
        // 往回找可能仍有效的（长台词重叠）
        while i >= 0 {
            if cues[i].contains(time) { return i }
            if cues[i].end < time - 0.5 { break }
            i -= 1
        }
        return nil
    }
}
