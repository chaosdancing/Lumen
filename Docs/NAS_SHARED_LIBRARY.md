# NAS 共享媒体库与观看状态

> 分支：`feature/nas-shared-library`  
> 目标：刮削结果、观看进度、收藏不再只存在单机；重新安装或换一台机器扫描同一个 NAS 目录即可复用。

## 1. 文件位置

每个可写媒体源（本地文件夹 / WebDAV）根目录下：

```
.lumen-cache/library-metadata.json   # 刮削结果（标题、年份、类型、简介、评分、演职员、海报路径...）
.lumen-cache/library-state.json      # 观看进度、收藏
```

`.lumen-cache` 里原有的不可覆盖缓存文件仍然保留；这两个文件是可覆盖的共享文件，使用 `WritableMediaSource.writeShared` 写入。

不写入密码 / TMDB Key / 书签，只有影片信息和观看状态。

## 2. 元数据

### 写入

- 扫描、手动更新元数据、重新刮削后，`MetadataStore.commit` 会调度一次共享元数据写入（2 秒合并窗口）。
- 一次写入会覆盖/合并整个源的 catalog；写入前先读取已有文件，保留其它条目，避免覆盖另一台机器已经刮好的内容。
- 未完成的刮削不会假定为完整；只有 `genres + overview + posterPath` 都存在时，条目才会被另一台机器直接采用。

### 读取

扫描完成后：

1. 读取 `library-metadata.json`；
2. `MetadataStore.importSharedCatalog` 把条目填进本机 `remoteCache`（按当前 source 的 fingerprint 重建 identity）；
3. `MetadataStore.load` 看到 TMDB 数据已存在，就不再发网络请求；
4. 如果条目缺少类型/简介/海报，则跳过导入，仍由 TMDB 补齐；
5. 分类/年代/评分等由缓存元数据直接派生。

共享 catalog 的 key 是源内相对路径，所以不同安装的 `sourceID` / `itemID` 不同也能对应。

## 3. 观看进度与收藏

`library-state.json` 结构：

```json
{
  "schema": 1,
  "updatedAt": "2026-10-31T...",
  "progress": {
    "movies/xxx.mkv": { "position": 123.4, "duration": 6000, "updatedAt": "..." }
  },
  "favorites": {
    "movies/xxx.mkv": { "favorite": true, "updatedAt": "..." }
  }
}
```

- 进度按 `updatedAt` 合并：共享记录比本机新才采用。
- 收藏按路径合并；剧集收藏会把该剧所有分集路径都写入共享文件，避免“代表分集”在不同安装里变化。
- 播放中约 15 秒合并写一次，关闭播放器/进入后台时立即 flush；元数据 2 秒合并窗口。
- 收藏目前是“并集”合并，**取消收藏不会跨设备删除**（还没有 tombstone 设计）；清空进度也不会删除另一台机器的共享记录。后续可补 tombstone / 每项 updatedAt。

## 4. 设置开关

设置 → 同步：

- **元数据写入媒体源**：关闭后不写/不读 `library-metadata.json`；
- **观看进度 / 收藏写入媒体源**：关闭后不写/不读 `library-state.json`；
- **立即同步**：关闭播放器或手动点击时同时 flush iCloud 和媒体源共享文件。

默认两个开关都开启。Emby/Jellyfin 以及只读 HTTP 源跳过；本地 / WebDAV 可写源支持。

## 5. 关键代码

| 文件 | 作用 |
|---|---|
| `Sources/Core/SharedLibrarySync.swift` | catalog/state 模型、合并、调度、写入 |
| `Sources/Core/Sources.swift` | `WritableMediaSource.writeShared`（本地原子替换 / WebDAV PUT） |
| `Sources/Core/Metadata.swift` | `importSharedCatalog`、TMDB 跳过、commit 调度 |
| `Sources/Core/Store.swift` | 扫描导入、进度/收藏合并、record/favorite 调度、flush |
| `Sources/UI/SettingsView.swift` | 同步开关与路径展示 |
| `Tests/Unit/SharedLibrarySyncTests.swift` | 编解码与本地可覆盖写入测试 |

## 6. 已知限制 / 下一步

1. 共享文件是 Lumen 自有 JSON，不是 Kodi/Emby 能直接识别的 NFO；如需跨软件共享，下一步增加可选的 NFO 导出（写回影片目录）。
2. 收藏取消、进度清除还没有 tombstone；当前只增不删。
3. 多设备同时写同一个 JSON 时是 last-writer-wins；已有“先读再合并”，但没有文件锁/ETag 冲突重试。
4. 剧集被多个目录重复扫描时，catalog 以每个分集路径为 key，体积会偏大；后续可折叠成 series + episode 两级。
5. 共享文件写入失败只记日志，不会阻塞播放；设置页暂未显示最近一次同步时间/错误。
