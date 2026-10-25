import Foundation

struct MetadataLoadState: Equatable {
    var isLoading = false
    var text: String?
    var error: String?
}

enum MetadataMerge {
    /// The preferred record wins only for populated fields, never for empty placeholders.
    static func merge(preferred: MediaMetadata?, fallback: MediaMetadata?,
                      itemID: String) -> MediaMetadata? {
        guard var result = fallback ?? preferred else { return nil }
        result.itemID = itemID
        guard let preferred else { return result }
        var provenance = result.fieldSources ?? [:]
        for (key, value) in [("title", result.title), ("seriesTitle", result.seriesTitle),
                             ("originalTitle", result.originalTitle), ("overview", result.overview),
                             ("posterPath", result.posterPath), ("backdropPath", result.backdropPath),
                             ("releaseDate", result.releaseDate), ("mediaType", result.mediaType),
                             ("certification", result.certification)] where value?.isEmpty == false {
            if provenance[key] == nil { provenance[key] = result.source }
        }
        if !result.genres.isEmpty, provenance["genres"] == nil { provenance["genres"] = result.source }
        if !result.cast.isEmpty, provenance["cast"] == nil { provenance["cast"] = result.source }
        if result.rating != nil, provenance["rating"] == nil { provenance["rating"] = result.source }
        func string(_ key: String, _ value: String?, _ target: inout String?) {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                target = value
                provenance[key] = preferred.fieldSources?[key] ?? preferred.source
            }
        }
        string("title", preferred.title, &result.title)
        string("seriesTitle", preferred.seriesTitle, &result.seriesTitle)
        string("originalTitle", preferred.originalTitle, &result.originalTitle)
        string("overview", preferred.overview, &result.overview)
        string("posterPath", preferred.posterPath, &result.posterPath)
        string("backdropPath", preferred.backdropPath, &result.backdropPath)
        string("releaseDate", preferred.releaseDate, &result.releaseDate)
        string("mediaType", preferred.mediaType, &result.mediaType)
        if let value = preferred.certification?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            result.certification = value
            result.certificationRegion = preferred.certificationRegion
            provenance["certification"] = preferred.source
        }
        if let value = preferred.rating, value.isFinite, (0...10).contains(value) {
            result.rating = value; provenance["rating"] = preferred.source
        }
        if let value = preferred.voteCount { result.voteCount = value }
        if let value = preferred.tmdbID { result.tmdbID = value }
        if let value = preferred.runtimeMinutes { result.runtimeMinutes = value }
        if !preferred.genres.isEmpty { result.genres = preferred.genres; provenance["genres"] = preferred.source }
        if !preferred.cast.isEmpty { result.cast = preferred.cast; provenance["cast"] = preferred.source }
        result.fieldSources = provenance
        result.source = preferred.source
        result.updatedAt = Date()
        return result
    }

    static func episode(local: MediaMetadata?, series: MediaMetadata?,
                        item: MediaItem) -> MediaMetadata? {
        // A series premiere, score, plot or title is not episode metadata.
        guard var result = local ?? (series == nil ? nil : MediaMetadata(itemID: item.id)) else { return nil }
        result.itemID = item.id
        result.seriesTitle = series?.title ?? series?.seriesTitle ?? item.seriesTitle
        result.mediaType = "episode"
        return result
    }
}

/// XMLParser handles entities, CDATA, attributes and nested rating/actor nodes.
final class NFXMLDecoder: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [Node] = []
        init(_ name: String, _ attributes: [String: String]) {
            self.name = name.lowercased(); self.attributes = attributes
        }
        func value(_ name: String) -> String? {
            let value = children.first { $0.name == name }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
    }
    private var stack: [Node] = []
    private var root: Node?
    static func decode(_ data: Data, itemID: String) -> MediaMetadata? {
        guard data.count <= 2 * 1024 * 1024 else { return nil }
        let delegate = NFXMLDecoder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root,
              ["movie", "tvshow", "episodedetails"].contains(root.name) else { return nil }
        var result = MediaMetadata(itemID: itemID)
        result.source = "nfo"
        result.mediaType = root.name == "tvshow" ? "tv" : root.name == "movie" ? "movie" : "episode"
        result.title = root.value("title")
        result.seriesTitle = root.name == "tvshow" ? result.title : root.value("showtitle")
        result.originalTitle = root.value("originaltitle")
        result.overview = root.value("plot") ?? root.value("outline")
        result.releaseDate = root.value("premiered") ?? root.value("aired") ?? root.value("year")
        result.runtimeMinutes = root.value("runtime").flatMap(Int.init)
        let ratings = root.children.first { $0.name == "ratings" }?.children ?? []
        let rating = ratings.first { $0.attributes["default"] == "true" } ?? ratings.first
        result.rating = (root.value("rating") ?? rating?.value("value")).flatMap(Double.init)
            .flatMap { (0...10).contains($0) ? $0 : nil }
        result.voteCount = (root.value("votes") ?? rating?.value("votes")).flatMap(Int.init)
        result.genres = root.children.filter { $0.name == "genre" }
            .compactMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).nonempty }
        result.cast = root.children.filter { $0.name == "actor" }.prefix(20).compactMap {
            guard let name = $0.value("name") else { return nil }
            return CastMember(name: name, role: $0.value("role") ?? "", profilePath: $0.value("thumb"))
        }
        result.posterPath = root.value("thumb")
        result.backdropPath = root.children.first { $0.name == "fanart" }?.value("thumb")
        if let value = root.value("mpaa") ?? root.value("certification") {
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result.certificationRegion = parts[0].trimmingCharacters(in: .whitespaces)
                result.certification = parts[1].trimmingCharacters(in: .whitespaces)
            } else { result.certification = value }
        }
        for node in root.children where node.name == "uniqueid" && node.attributes["type"] == "tmdb" {
            result.tmdbID = Int(node.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let node = Node(name, attributes)
        stack.last?.children.append(node)
        if stack.isEmpty { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        stack.last?.text += String(decoding: data, as: UTF8.self)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        if let node = stack.popLast() { stack.last?.text += node.text }
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
