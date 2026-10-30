import Foundation
import CryptoKit

/// 不使用 sourceID：同一部影片在 Mac 和 iPad 上分别添加片源时仍能对应。
enum ProgressIdentity {
    /// 参与 key 计算的原始字段拼接，用来判断记忆化的 key 是否还能复用（远比正则 + SHA256 便宜）。
    static func fingerprint(for item: MediaItem) -> String {
        "\(item.seriesTitle ?? "")\u{1}\(item.season ?? -1)\u{1}\(item.episode ?? -1)\u{1}\(item.title)\u{1}\(item.fileName)\u{1}\(item.year ?? 0)"
    }

    static func key(for item: MediaItem) -> String {
        let identity: String
        if let series = item.seriesTitle, let season = item.season, let episode = item.episode {
            identity = "episode:\(normalized(series)):\(season):\(episode)"
        } else {
            let title = normalized(item.title)
            let fallback = normalized((item.fileName as NSString).deletingPathExtension)
            identity = "movie:\(title.isEmpty ? fallback : title):\(item.year ?? 0)"
        }
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "progress.v1." + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
    }
}

struct CloudProgress: Codable {
    var position: Double
    var duration: Double
    var updatedAt: Date
    var deleted: Bool

    init(_ record: PlaybackRecord) {
        position = record.position
        duration = record.duration
        updatedAt = record.updatedAt
        deleted = false
    }

    init(deletedAt date: Date) {
        position = 0
        duration = 0
        updatedAt = date
        deleted = true
    }
}

/// 本地文件始终是可靠副本；iCloud KVS 只传小型、逐条更新的进度和清除标记。
@MainActor
final class ProgressCloudSync {
    private let cloud = NSUbiquitousKeyValueStore.default
    private let diskURL = StorePaths.root.appendingPathComponent("progress-sync.json")
    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }()
    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()
    private var records: [String: CloudProgress] = [:]
    private var dirty: Set<String> = []
    private var lastUpload: [String: Date] = [:]
    private var observer: NSObjectProtocol?
    private var persistScheduled = false
    /// 串行，保证 progress-sync.json 的写入顺序
    private static let ioQueue = DispatchQueue(label: "lumen.progress-sync.io", qos: .utility)
    private var onChange: (([String: CloudProgress]) -> Void)?
    private(set) var isAvailable = false

    init() {
        if let data = try? Data(contentsOf: diskURL),
           let saved = try? decoder.decode([String: CloudProgress].self, from: data) {
            records = saved
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start(library: [MediaItem], progress: [String: PlaybackRecord],
               onChange: @escaping ([String: CloudProgress]) -> Void) {
        self.onChange = onChange
        // 旧版本可能在没有 iCloud 权限时已经积累了本地记录。启动时重新标记，
        // 这样权限恢复或换成正式签名后，历史进度也会补传，而不只上传新进度。
        dirty.formUnion(records.keys)
        if !progress.isEmpty {
            let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, record) in progress {
                guard let item = byID[id] else { continue }
                update(record: CloudProgress(record), for: ProgressIdentity.key(for: item))
            }
        }

        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.receiveCloudChange(notification) }
        }
        isAvailable = cloud.synchronize()
        _ = mergeFromCloud()
        onChange(records)
        flush(force: true)
    }

    func record(_ record: PlaybackRecord, for item: MediaItem) {
        update(record: CloudProgress(record), for: ProgressIdentity.key(for: item))
        flush()
    }

    func clear(_ item: MediaItem) {
        update(record: CloudProgress(deletedAt: Date()), for: ProgressIdentity.key(for: item))
        flush(force: true)
    }

    func clearAll() {
        let deleted = CloudProgress(deletedAt: Date())
        for key in records.keys { update(record: deleted, for: key) }
        flush(force: true)
    }

    func currentRecords() -> [String: CloudProgress] { records }

    func flush(force: Bool = false) {
        let now = Date()
        var uploaded: Set<String> = []
        for key in Array(dirty) {
            if !force, let last = lastUpload[key], now.timeIntervalSince(last) < 60 { continue }
            guard let record = records[key], let data = try? encoder.encode(record) else { continue }
            cloud.set(data, forKey: key)
            lastUpload[key] = now
            dirty.remove(key)
            uploaded.insert(key)
        }
        if force {
            isAvailable = cloud.synchronize()
            // synchronize() 返回 false 时通常表示 entitlement/账号不可用。
            // 保留脏标记，下次启动或手动同步时再试，避免静默丢失补传机会。
            if !isAvailable { dirty.formUnion(uploaded) }
        }
    }

    private func update(record: CloudProgress, for key: String) {
        if let old = records[key], old.updatedAt >= record.updatedAt { return }
        records[key] = record
        dirty.insert(key)
        persist()
    }

    private func receiveCloudChange(_ notification: Notification) {
        if let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
           reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            AppLog.error("iCloud 观看进度已达到 KVS 容量上限，仍保存在本地")
            return
        }
        // 只把本次真正变化的条目交给上层合并，而不是每次推送都把全部记录过一遍。
        let changed = mergeFromCloud(keys: notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String])
        if !changed.isEmpty {
            onChange?(records.filter { changed.contains($0.key) })
        }
        flush()
    }

    /// - Parameter keys: 只检查这些 key；nil 表示全量（启动时）。
    /// - Returns: 被远端覆盖的 key。
    @discardableResult
    private func mergeFromCloud(keys: [String]? = nil) -> Set<String> {
        var changed: Set<String> = []
        let candidates = keys ?? Array(cloud.dictionaryRepresentation.keys)
        for key in candidates where key.hasPrefix("progress.v1.") {
            guard let data = cloud.data(forKey: key),
                  let remote = try? decoder.decode(CloudProgress.self, from: data) else { continue }
            if let local = records[key], local.updatedAt >= remote.updatedAt {
                if local.updatedAt > remote.updatedAt { dirty.insert(key) }
                continue
            }
            records[key] = remote
            dirty.remove(key)
            changed.insert(key)
        }
        if !changed.isEmpty { persist() }
        return changed
    }

    /// 合并同一轮内的多次写入（启动时逐条 update 会触发 N 次），编码与写盘放到后台。
    private func persist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.persistScheduled = false
            let snapshot = self.records
            let url = self.diskURL
            Self.ioQueue.async {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(snapshot) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }
}
