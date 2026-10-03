# GenPlayer 下载中心与离线关联播放设计（Jellyfin/Emby/SMB/WebDAV）

## 1. 目标与范围

### 1.1 核心目标
- 提供统一的 **下载中心**：可查看任务历史、实时进度、速度、剩余时间、失败原因。
- 提供完整的 **任务控制能力**：暂停、恢复、取消、重试、删除本地文件、清理历史。
- 在浏览页与媒体库页实现 **已下载可视化反馈**：列表/海报卡显示离线图标与状态。
- 建立“服务器媒体项 ↔ 本地文件”强关联，实现：
  - 进入媒体详情可直接识别已离线。
  - 点击播放优先本地文件，不走远程流。
  - 播放进度与已观看状态在本地与服务器双向同步。
- 下载目录可按服务器维度组织，便于管理、迁移和清理。

### 1.2 非目标（第一阶段不做）
- 跨设备下载任务实时同步（可在二期做 iCloud Sync）。
- DRM 内容离线（受版权与平台限制）。
- BT/P2P 下载器能力。

### 1.3 2026-03 批量下载一期落地边界
- 覆盖范围：`Jellyfin / Emby / Plex` 的电影、单集、整季下载，以及远程文件页的多选普通文件批量下载。
- 明确不做：整剧下载、仅下载未观看、文件夹递归下载、入队后自动跳转下载中心。
- 入队后留在当前页面，通过轻提示反馈“已加入队列 / 已在下载队列中”。
- 下载中心继续维持 `进行中 / 已完成 / 失败` 三段结构，但展示对象从单任务提升为 job 分组卡片。
- `进行中` 段实际承载 `queued / downloading / paused` 三种未完成状态，不单独新增第四个“已暂停” tab，避免下载中心信息架构继续膨胀。
- 行内主操作统一调整为 `暂停 / 恢复`；真正破坏性的 `取消下载` 下沉到 `more` 菜单，与 `删除文件 / 删除记录` 分离。
- 断点续传能力按协议分层：
  - `Jellyfin / Emby / Plex / WebDAV` 优先接入 HTTP 级续传，暂停后尽量继续已有字节。
  - `SMB / FTP / SFTP / NFS` 一期先提供“暂停保留任务、恢复时重启下载”的 restart-only 语义，不在 UI 里冒充真续传。
- 用户界面不直接暴露协议差异，只表达 `可恢复继续` 与 `恢复时将重新开始` 两种文案。
- App 重启或异常中断后，原 `queued / downloading` 任务要保留记录并恢复为 `paused`，用户仍可手动继续，而不是静默消失。

---

## 2. 参考 App 设计要点（可借鉴）

> 结合 YouTube/Netflix/Plex/Infuse/各云盘类 App 的通用模式，抽取适合 GenPlayer 的交互规范。

1. **下载中心分层**：
   - “进行中”与“已完成/失败”分组。
   - 顶部展示总进度、总下载速度、队列状态。
2. **轻量状态徽标**：
   - 列表项右上角用小图标（↓、✅、⏳、⚠️）表示离线状态，不打断浏览。
3. **播放优先级明确**：
   - 可离线即离线，网络差时自动回退到本地。
4. **可恢复任务**：
   - 支持断点续传（HTTP Range / 服务端可用时）。
5. **“删除文件”与“取消关联”分离**：
   - 用户可选择仅删记录或连本地文件一起删除。
6. **离线入口统一**：
   - 在“我的/下载”集中管理，同时在原始库页面可见状态。

---

## 3. 信息架构与界面设计

## 3.1 新增入口建议
- 主 Tab 新增 `下载`（Download Center）。
- 在 Jellyfin/Emby 首页增加 `本服务器下载` 模块入口。
- 在媒体详情页显示“已下载”标识与“播放离线版本”按钮（如存在多个清晰度可选）。

## 3.2 下载中心页面结构

### A. 顶部汇总区
- 当前任务数（进行中/等待中）
- 总速度（如 12.8 MB/s）
- 预计剩余时间
- 全局操作：全部暂停 / 全部恢复 / 全部取消

### B. 分段列表（Segment）
1. 进行中
2. 已完成
3. 失败

> 说明：`进行中` 里同时容纳 `queued / downloading / paused`，每个 job 通过行内状态和操作按钮区分“正在下载”“已暂停”“等待开始”。
> 各日期分组右侧的数量 badge 在三段里都保持菜单语义一致：
> - `进行中`：提供该日期分组下的批量 `暂停 / 恢复 / 取消`。
> - `已完成 / 失败`：继续提供该日期分组下的 `删除文件 / 删除记录`。
> 详情页与剧集行里的下载动作图标、详情顶部离线状态徽标统一使用 `arrow.down.circle` 家族：
> - 未下载：描边下载图标。
> - 排队 / 下载中 / 已暂停：蓝色填充下载图标。
> - 已下载：绿色填充下载图标，不切换为对勾。
> 只要页面右上角存在下载中心入口，就统一显示当前进行中任务数量 badge，避免剧集 / 电影详情行为分叉。

### C. 行项目字段
- 封面/缩略图
- 标题（电影名/剧集名/文件名）
- 来源服务器（Jellyfin-家庭NAS / SMB-办公室）
- 进度条（百分比 + 已下载/总大小）
- 实时速度、剩余时间
- 操作按钮：暂停/恢复、取消、删除、重试

## 3.3 浏览页中的“已下载”表达
- 网格卡片：右上角“离线”图标（可用云朵下箭头+勾）。
- 列表行：标题后显示 `已下载` 文本标签。
- 详情页：
  - `播放` 按钮文案动态切换为 `播放（离线）`。
  - 展示本地文件信息（清晰度、大小、下载日期）。

---

## 4. 本地存储组织（Downloads 目录）

推荐结构：

```text
Documents/Downloads/
  <ServerType>/
    <ReadableServerName>/
      Movies/
      TV Shows/
        <SeriesName>/
          Season 01/
      Files/
        <RemoteParentFolders>/
      Others/
  unlinked/
```

## 4.1 服务器目录规则
- 用户可见目录优先保持可读：
  - `<ServerType>/<ReadableServerName>/`
  - 若未来需要区分同名服务器，可在可读名后追加短指纹，而不是直接暴露纯 hash。
- **媒体服务器（Jellyfin / Emby / Plex）**：
  - 电影默认进入 `Movies/`
  - 剧集 / 整季下载进入 `TV Shows/<SeriesName>/Season xx/`
  - 若季号暂时不可可靠解析，至少也要落到 `TV Shows/<SeriesName>/`，避免与电影平铺混放。
- **文件型服务（SMB / WebDAV / FTP / SFTP / NFS）**：
  - 进入 `Files/`
  - 并尽量镜像远端父目录层级，方便用户在本地 Files 中回忆来源位置。
- 同一服务器目录下，禁止长期把电影、剧集、普通文件全部平铺在一层根目录。

### 删除文件后的空目录清理（2026-09-11）
- iOS、macOS、tvOS 下载中心在单项、批量、按日期或全部删除下载文件后，沿该文件的父目录逐层清理空目录，保留 `Downloads` 根目录。
- 目录中仍有其他文件（包含隐藏文件）时立即停止；不跟随符号链接，不清理下载根目录外的目录，不递归扫描其他目录。
- “仅删除记录”保留本地文件及目录；下载状态、离线关联与原有删除确认保持既有语义。

## 4.2 命名规范
- 文件名：`<displayTitle>__<mediaItemId>__<qualityTag>.<ext>`
- 若存在重名，追加短 UUID。

## 4.3 元数据 sidecar（可选）
每个目录保留 `meta.json` 记录：
- server 基本信息（只留必要字段）
- 目录版本号（用于迁移）
- 最近扫描时间

## 4.4 远程预览自动缓存（新增约束）

自动缓存与正式下载必须分层，推荐结构：

```text
Library/Caches/GenPlayer/remote-file-cache/
  <serverFingerprint>/
    <remotePathHash>__<sanitizedDisplayName>.<ext>
```

- 该目录仅服务于“远程预览 / 在其他 App 中打开 / 轻量二次打开提速”。
- 自动缓存默认不进入下载中心，不展示“已下载”语义，也不承诺长期持久化。
- `serverFingerprint` 允许为稳定 hash / UUID 风格标识，因为此目录不面向用户直接浏览。
- 正式下载目录仍保留用户可读性；若需要稳定区分同名服务器，建议使用：
  - `<sanitizedServerName>__<shortFingerprint>/`
  - 而不是把纯 `serverFingerprint` 直接暴露给用户。
- 物理目录名不是唯一真相；唯一关联真相仍应落在 `LocalAsset / MediaLink` 或等价持久层。
- 已追踪的正式下载若从旧的平铺目录升级到新分层目录，应用启动时应做轻量迁移并回写追踪路径，避免“已下载”状态与真实文件位置脱节。

---

## 5. 数据模型设计（核心）

建议新增 4 张本地表（SwiftData/CoreData/SQLite 均可）：

## 5.1 DownloadTask
- `id` (UUID)
- `serverId`（本地 ServerConfig.id）
- `serverFingerprint`
- `sourceType`（jellyfin/emby/smb/webdav/localImport）
- `remoteItemId`（Jellyfin/Emby ItemId；SMB/WebDAV 可为空）
- `remotePathOrUrl`
- `title`
- `seasonNumber`/`episodeNumber`（剧集）
- `qualityTag`
- `status`（queued/downloading/paused/completed/failed/canceled）
- `progress`（0~1）
- `bytesDownloaded`
- `bytesTotal`
- `speedBytesPerSec`
- `etaSec`
- `resumeCapability`（resumable / restartOnly / unknown）
- `backgroundCapability`（backgroundTransfer / foregroundOnly / unknown）
- `resumeData`（HTTP 续传断点信息）
- `stagingFilePath`（可选，协议侧需持久化部分文件时使用）
- `errorCode` / `errorMessage`
- `createdAt` / `updatedAt` / `completedAt`

## 5.2 LocalAsset
- `id`
- `localFileURL`
- `fileSize`
- `checksum`（可选）
- `mediaType`（movie/episode/music/video/file）
- `duration`
- `resolution`
- `audioCodec`
- `videoCodec`
- `isAvailable`（文件仍存在）
- `lastValidatedAt`

## 5.3 MediaLink（关键关联表）
- `id`
- `serverId`
- `sourceType`
- `remoteItemId`
- `remoteLibraryId`（可选）
- `remotePathHash`（SMB/WebDAV 兜底）
- `localAssetId`
- `downloadTaskId`
- `linkState`（active/orphan/deleted）
- `playbackPreference`（preferLocal/preferRemote/auto）

> 作用：把“服务器媒体实体”和“本地文件实体”解耦，便于删除、重建、修复链接。

## 5.4 PlaybackSyncState
- `id`
- `mediaLinkId`
- `lastPositionSec`
- `durationSec`
- `watched`
- `lastLocalUpdateAt`
- `lastRemoteSyncAt`
- `remoteSyncVersion`
- `syncConflictPolicy`（localWins/remoteWins/latestWins）

## 5.5 当前实现落地（task 冗余 job 元数据）
- 当前版本不单独引入第二份 job 持久化文件，而是在 `DownloadTaskItem` 上补齐：
  - `jobId`, `jobKind(singleMedia/seasonPack/fileBatch)`, `sourceType`
  - `remoteItemId`, `collectionId`, `seriesId`, `seasonId`
  - `displayTitle`, `groupTitle`, `groupIndex`
  - `resumeCapability`, `backgroundCapability`
  - `resumeData`, `backgroundSessionTaskIdentifier`, `stagingFilePath`
- `DownloadCenterService` 在运行时按 `jobId` 派生 `DownloadJobGroup`，统一提供：
  - job 聚合进度与状态
  - 单媒体 / 整季 / 文件批量下载的离线状态判断
  - 下载中心分组展示
- 未完成任务恢复策略：
  - 手动暂停后的任务保持 `paused`，保留恢复入口。
  - App 意外退出后重新启动时，原 `queued / downloading` 任务统一恢复为 `paused`，并补一条“下载已中断，可继续/将重新开始”的提示文案。
- HTTP 下载恢复策略：
  - 若存在 `resumeData`，优先尝试续传。
  - 若续传数据失效或服务端不接受 `Range`，自动回退到“从头重新下载”，但任务记录继续保留。
- 旧版 `download_tasks.json` 迁移策略：
  - 缺失新字段时默认 `jobId = id`、`jobKind = singleMedia`、`displayTitle = fileName`
  - `sourceType` 由 `ServerConfig.type` 推断
  - `resumeCapability` 缺失时按 `ServerConfig.type` 推断：HTTP 系走 `resumable`，其余先落 `restartOnly`
  - 新任务优先使用 `remoteItemId` 做显式匹配，旧任务继续保留 `remotePath` 兜底
- 回滚策略：
  - 新字段解析失败时不阻断旧记录加载
  - 本地文件被外部删除时沿用 reconcile 降级逻辑，详情页离线态同步回退

---

## 6. 下载状态机

```text
queued -> downloading -> completed
   |         |  ^
   |         v  |
   |       paused
   |         |
   |         v
   +------> failed -> retry -> queued
   \------> canceled
```

### 状态转换规则
- `downloading -> paused`：用户手动暂停或网络切换策略触发。
- `queued -> paused`：用户在任务真正开始前手动暂停。
- `paused -> queued`：用户点击恢复；若协议支持续传则带断点恢复，否则按重启下载处理。
- `downloading -> failed`：鉴权失败、磁盘不足、网络中断超过重试阈值。
- `downloading / queued -> paused`：App 异常退出后，下次启动统一恢复为可继续的 `paused` 语义，不直接丢失任务。
- `failed -> queued`：用户点击重试。
- `completed` 后创建/更新 `LocalAsset + MediaLink`。
- `canceled` 默认保留历史记录（可清空）。

---

## 7. 关键业务流程

## 7.1 从 Jellyfin/Emby 发起下载
1. 用户在海报卡或详情页点击下载。
2. 通过 API 获取可下载流（选择码率/分辨率）。
3. 创建 `DownloadTask(queued)`。
4. 调度器按并发策略执行。
5. 下载完成后写入目标目录，落库 `LocalAsset`。
6. 建立 `MediaLink(serverId + remoteItemId -> localAsset)`。
7. UI 刷新：详情页显示“已下载”，列表显示离线图标。

## 7.2 从 SMB/WebDAV 下载
- 缺少统一 ItemId 时，使用 `remotePathHash` + `serverFingerprint` 建立关联。
- 若后续识别出与 Jellyfin/Emby 媒体同一文件，可合并链接（可选高级能力）。

### 7.2.1 远程文件批量下载（本期）
1. 用户在 `RemoteFileListView` 进入选择模式。
2. 顶部显示已选数量，并提供 `Done`、`Select All / Clear`。
3. 底部动作栏提供 `Download / Move / Delete` 三个入口。
4. 仅当选择集中全部为普通文件时允许 `Download`；若包含文件夹，则下载按钮禁用并提示原因。
5. 批量入队后生成单个 `fileBatch` job，下载中心以一张可展开卡片展示子任务。

### 7.2.2 剧集单集 / 整季下载（本期）
1. 电影与单集保留单项下载入口。
2. Series / Season 详情在当前选中季附近提供 `Download Season`，作用范围始终是当前季。
3. 每个 Episode 行尾提供独立下载按钮；主行点击仍保留播放或进入详情。
4. 整季下载会拆分为 `1 个 seasonPack job + N 个 episode task`；重复点击时只补缺失任务，不重复入队已存在的集。

## 7.3 播放时自动命中离线文件
1. 播放入口拿到 `serverId + remoteItemId/remotePath`。
2. 查询 `MediaLink.active`。
3. 若有可用 `LocalAsset.isAvailable=true`：
   - 直接传本地 URL 给播放器。
   - 播放按钮显示 `离线播放`。
4. 若本地文件丢失：
   - 将 link 标记 `orphan`，回退远程流。

## 7.4 删除文件时解除关联
- 用户在下载中心点击删除：
  1. 删除磁盘文件。
  2. `LocalAsset.isAvailable=false`。
  3. `MediaLink.linkState=deleted` 或硬删除。
  4. 刷新 Jellyfin/Emby/浏览页状态图标。

## 7.5 播放进度同步
- 本地播放每 N 秒（如 15s）更新 `PlaybackSyncState.lastPositionSec`。
- 网络可用且来源为 Jellyfin/Emby 时，批量上报远端进度 API。
- 冲突策略：默认 `latestWins`。
- 用户手动选择“以本地为准/以服务器为准”可覆盖。

---

## 8. 调度与性能策略

## 8.1 下载调度器
- 前台并发：2~3
- 后台并发：1
- 按任务优先级（手动置顶 > 最近播放 > 普通）
- 网络策略：
  - 仅 Wi-Fi 下载（iOS 设置项已接入；策略触发时将 queued/downloading 收敛为 paused，不删除断点或进度）
  - 低电量自动暂停（iOS 设置项已接入；恢复需要用户在条件解除后手动继续，避免后台意外耗电/耗流量）
  - 漫游禁止（可选）

## 8.2 速度与 ETA 计算
- 采用滑动窗口（近 5~10 秒）平均值，避免瞬时抖动。
- 实时速度必须基于“最近窗口内新增的字节数 / 最近窗口耗时”计算，不得直接用任务累计 `bytesDownloaded` 除以整段会话耗时回推。
- 暂停后恢复时，测速采样基线必须重置到“恢复瞬间的已下载字节数”，避免把暂停前累计字节误算进首帧速度并出现异常尖峰。
- 展示单位自动切换 KB/s、MB/s。
- ETA = `(bytesTotal - bytesDownloaded) / smoothedSpeed`。

## 8.3 完整性校验
- 完成后校验大小（必要）+ hash（可选，较耗时）。
- 校验失败标记 failed 并提示“文件损坏，建议重试”。

### 2026-09-13 三端下载校验与 Mac 正式下载入口

- HTTP 前台与后台下载在落盘前检查响应状态及可用的文件长度；错误响应不能进入 completed 或离线命中。续传 206 按 Content-Range 的完整资源长度校验已组装文件，不把剩余响应长度当作整文件长度；无可靠长度或透明解压的响应不猜测大小。
- SMB/FTP/SFTP/NFS 等文件传输在已知源大小时校验临时文件；失败删除本次临时产物，保留原有下载文件。完成字节数使用实际落盘大小。暂停/取消意图优先于晚到的完成回调。
- Mac 文件型服务器网格/列表右键菜单提供单文件“下载”，调用正式下载中心；显示已下载、排队、下载中、暂停状态并防止重复入队，失败/取消允许重试。保持预览下载与正式下载独立，暂不新增文件夹递归下载或多选批量功能。
- 此次不迁移下载记录格式，不扫描或删除历史已完成文件；发现旧损坏文件时由用户删除后重新下载。真实服务器、续传与 Mac 菜单回归需按 AGENTS.md 3.8 获批执行。

## 8.4 后台下载设计（已落地第一阶段）
- 当前状态：
  - `Jellyfin / Emby / Plex / WebDAV / 直链 HTTP` 已切到系统级 `Background URLSession`。任务创建后由系统接管传输，App 在前台、回前台或被系统后台唤醒时通过 session delegate 回流进度、完成、失败与恢复信息。
  - `SMB / FTP / SFTP / NFS` 仍保持前台下载 + `beginBackgroundTask` 宽限时间的旧语义；宽限耗尽后统一收敛为 `paused/interrupted`，不伪装成可持续后台下载。
- 协议分层：
  - `Jellyfin / Emby / Plex / WebDAV / 直链 HTTP`：归类为 `backgroundTransfer`，任务记录会持久化 `backgroundCapability` 与 `backgroundSessionTaskIdentifier`，用于冷启动后重连系统级后台 session。
  - `SMB / FTP / SFTP / NFS`：归类为 `foregroundOnly`，切到后台时不承诺持续传输；最佳努力方向仍是保存断点/部分文件并统一转成 `paused`，待用户回前台后继续。
- 数据模型与状态语义：
  - 任务层需显式区分 `backgroundTransfer` 与 `foregroundOnly`，不能把所有任务都渲染成同一种“下载中”。
  - 对 `foregroundOnly` 任务，后台中断后必须统一落到可解释的 `paused/interrupted` 语义，并复用现有“可继续 / 将重新开始”的恢复文案。
  - 对 `backgroundTransfer` 任务，App 冷启动时需先向系统 session 重连；只有确认底层 session 中不存在对应任务后，才允许把旧的 `queued / downloading` 记录收敛成 `paused/interrupted`。
- UI 约束：
  - 下载中心、详情页、轻提示都要明确表达“支持后台继续”或“切到后台后会暂停”，不能给用户错误预期。
  - 若同一个 job 中混有不同协议子任务，应以**最弱能力**对外展示，避免整组显示为“支持后台”但部分子任务实际会停。
- 本轮已完成的底层收口：
  - 补齐 `AppDelegate.handleEventsForBackgroundURLSession` 与后台 session completion handler 接线。
  - 下载中心在启动时会重连系统级后台任务，把仍在系统侧运行的 HTTP 系任务恢复为 `downloading`，而不是误判成 `paused`。
  - 下载完成后先把系统临时文件转存到应用可控 staging，再统一落到 `Documents/Downloads/...` 目标目录，降低系统临时文件失效导致的收尾失败风险。
- 仍待后续补齐的外围体验：
  - 详情页的显式“支持后台继续 / 切后台会暂停”文案与图标提示。
  - 下载完成后的关联修复与缩略图刷新进一步收口到统一可恢复流程。
- 已补齐的 iOS 外围体验：
  - 下载中心任务组展示后台能力与续传能力，混合任务按最弱能力对外提示。
  - 下载完成通知接入系统通知权限；仅在 GenPlayer 非前台活跃时投递，避免前台重复打扰。

---

## 9. Jellyfin/Emby 专项设计

## 9.1 “本服务器下载”列表
在服务器首页新增区块：
- 最近下载
- 按类型分组：电影 / 剧集 / 音乐
- 支持“查看全部”进入过滤后的下载中心（serverId 维度）

## 9.2 与电影/剧集实体关联
关联键建议：
- 主键：`serverId + remoteItemId`
- 副键：`seriesId + seasonId + episodeId`（用于剧集场景二次确认）

## 9.3 详情页动作
- 未下载：`下载`
- 下载中：`查看下载进度`
- 已下载：`播放（离线）`、`删除离线文件`

---

## 10. 错误处理与用户提示

常见错误码映射：
- 401/403：登录过期，提示重新登录。
- 404：资源不存在（服务器移除）。
- ENOSPC：磁盘空间不足。
- 网络超时：自动重试（指数退避，上限 3~5 次）。

提示文案要点：
- 明确“失败原因 + 建议动作”（重试/登录/释放空间）。
- 避免只显示“未知错误”。

---

## 11. 迁移与兼容（从现有 Downloads 平铺结构升级）

1. 首次启动扫描旧 `Documents/Downloads/*`。
2. 识别可关联来源（若有历史记录则回填 serverId）。
3. 无法识别的文件迁移到 `unlinked/` 并保留可播放能力。
4. 建立最小 `LocalAsset` 记录，等待用户后续手动关联（可选）。
5. 对已被下载中心追踪的 `completed` 文件，优先按新目录规则自动搬迁并同步更新 `localFilePath`；无法搬迁时保留原路径，不阻断播放与状态恢复。

---

## 12. 分阶段落地计划

## Phase A（1~2 个迭代）
- 下载中心 UI（进行中/已完成/失败）
- 单任务下载、暂停、取消、删除
- 目录改为按 serverFingerprint 组织
- 基础 `MediaLink` 建立与离线图标展示
- 播放优先本地

## Phase B（2~3 个迭代）
- 断点续传、重试策略、批量任务
- Jellyfin/Emby “本服务器下载”模块
- 播放进度本地+远端双向同步
- 下载质量选择（原画/1080p/720p）

## Phase C（后续增强）
- 智能清理（看完 N 天自动清理）
- 跨设备同步（iCloud）
- 同名文件智能合并与去重

---

## 13. 验收标准（Definition of Done）

- 用户能在下载中心看到：进度、速度、剩余时间、状态。
- 用户能对任务执行：暂停/恢复/取消/重试/删除。
- Jellyfin/Emby 浏览页与详情页可正确显示已下载标识。
- 点击播放已下载媒体时，默认走本地文件。
- 删除本地文件后，UI 标识与关联关系同步清除。
- 播放进度能回写到服务器（网络可用时）。

---

## 14. 可直接映射到当前工程的实现建议

- 新建服务层：
  - `DownloadCenterService`（任务管理+状态广播）
  - `DownloadScheduler`（并发与网络策略）
  - `MediaLinkService`（关联查询/修复）
  - `PlaybackSyncService`（进度同步）
- 新建页面：
  - `DownloadCenterView`
  - `ServerDownloadsView(serverId)`
- 在现有 Jellyfin/Emby 卡片组件增加 `isDownloaded` 透传字段。
- 在 `PlayerView` 的播放入口前加入 `resolvePlayableURL()`：优先本地，再远程。

> 这样可以做到“下载功能、管理、与播放深度关联”三者一体，且支持后续持续演进。

---

## 15. 开发前专题方案：Jellyfin/Emby 与文件类服务下载能力统一设计

本章节用于回答“Jellyfin/Emby 是否应支持下载、如何存储、如何与服务关联、如何展示、是否直接暴露文件系统、是否支持文件夹下载”等关键问题，并给出可直接落地到 GenPlayer 的统一方案。

### 15.1 结论先行（TL;DR）

1. **必须支持 Jellyfin/Emby 下载**，且与 SMB/WebDAV 一起纳入同一下载中心，不做两套独立系统。
2. **采用“虚拟资源管理 + 受控文件访问”双层模型**：
   - 对用户展示“离线资产”（虚拟项），而不是裸 `Documents/Downloads` 文件树。
   - 仍允许高级用户在“文件”页访问下载目录，但默认通过下载中心执行删除/重命名等破坏操作。
3. **关联的唯一真相在数据库，不在文件名**：`MediaLink` 才是“远端媒体 ↔ 本地文件”事实来源。
4. **电影、单集、整季、文件夹下载统一抽象为 DownloadJob + DownloadTask DAG**（任务图），前台仅展示一个“下载单元”。
5. **删除策略分离**：
   - 删除任务记录（保留文件）
   - 删除离线文件（解除关联）
   - 同时删除（最危险，需二次确认）

### 15.2 为什么不能只靠“直接访问文件”

仅依赖真实文件系统会导致几个一致性问题：

- 用户在 Files App 或本地“Downloads”直接删文件，任务状态仍显示 `completed`。
- Jellyfin/Emby 的 `remoteItemId` 与 SMB/WebDAV 的 `remotePath` 难以靠目录结构可靠映射。
- 剧集多集下载时，重命名/去重后无法稳定回写到季/集实体。

因此推荐：

- **逻辑层使用虚拟资产（LocalAsset + MediaLink）作为主视图**；
- **物理层保留真实文件**供播放器与系统文件共享使用；
- 启动/前后台切换时做轻量 reconcile（存在性 + 大小），修正 `isAvailable` 与 `linkState`。

### 15.3 统一域模型（支持 Jellyfin/Emby + SMB/WebDAV）

在现有 4 张表基础上建议补一个“下载单元”层：

- `DownloadJob`（面向用户）
  - 例：下载《绝命毒师 S01》、下载电影《Dune》、下载文件夹 `/Anime/OnePiece/`。
  - 包含：`jobType(movie/episodePack/folder/custom)`、`displayTitle`、`itemCount`、`aggregateProgress`。
- `DownloadTask`（面向执行器）
  - Job 下拆分的具体文件任务（每个可断点续传、失败重试）。

这样可以支持：

- Jellyfin/Emby：电影 1 Job -> 1~N Task；整季 1 Job -> 多集多 Task。
- SMB/WebDAV：文件夹 1 Job -> 递归枚举后多 Task。

### 15.4 服务关联策略（按来源类型）

1. **Jellyfin/Emby（媒体 ID 稳定）**
   - 主关联键：`serverId + remoteItemId`
   - 剧集增强键：`seriesId + seasonId + episodeId`
   - 若转码版本多，补 `mediaSourceId` 区分离线版本。

2. **SMB/WebDAV（路径语义为主）**
   - 主关联键：`serverFingerprint + remotePathHash`
   - 可选记录 `etag/lastModified/contentLength` 做弱校验。

3. **跨来源统一播放解析**
   - 输入统一为 `PlaybackTarget(serverId, sourceType, remoteItemId?, remotePath?)`
   - 先查 `MediaLink.active` 命中本地，再回退远程。

### 15.5 展示层设计（下载中心 / 媒体库 / 详情页）

#### A. 下载中心（唯一管理入口）
- 以 `DownloadJob` 展示，支持展开查看子任务。
- 顶部按服务器过滤（全部 / Jellyfin / Emby / SMB / WebDAV）。
- 默认只展示逻辑状态，不暴露底层临时文件。

#### B. 媒体库与详情页
- 卡片徽标：`未下载 / 下载中 / 部分已下载 / 已下载`。
- 剧集页支持“整季下载”“仅下载未观看”。
- 详情页显示离线版本信息（大小、清晰度、下载时间）。

#### C. 文件管理页
- 可查看下载目录（高级入口），但所有删除动作触发“关联修复流程”：
  - 删除后立即标记 `LocalAsset.isAvailable=false`
  - 并将 `MediaLink` 置为 `orphan/deleted`

### 15.5.1 自动缓存 vs 正式下载（新增）

- **自动缓存**
  - 目的：避免远程文件每次预览都重新下载。
  - 适用：图片、文档、QuickLook、`Open in Another App` 等轻量打开场景。
  - 存储：`Library/Caches/...`
  - 展示：可以显示“已缓存”或仅在详情/菜单内可见，但不应冒充“已下载”。
  - 清理：允许被系统或应用按容量/LRU策略清理。
- **正式下载**
  - 目的：形成可管理的离线资产，参与下载中心、离线播放和状态徽标。
  - 存储：`Documents/Downloads/...`
  - 展示：继续使用 `queued / downloading / paused / completed` 下载语义。
  - 清理：必须经过下载中心或统一关联修复流程。
- **统一命中顺序**
  - 播放/打开时优先级：`正式下载 > 自动缓存 > 远程`
  - 若自动缓存丢失，不影响用户的正式下载状态；若正式下载丢失，仍按 `orphan/missing` 语义处理。

### 15.6 文件夹下载（是否支持）

建议支持，但分阶段：

- **Phase 1**：SMB/WebDAV 支持“下载当前文件夹（不含子目录）”。
- **Phase 2**：支持递归子目录 + 过滤规则（仅视频、大小上限、跳过已存在）。
- **Phase 3**：支持“订阅式目录离线同步”（增量更新）。

对 Jellyfin/Emby 不暴露“文件夹下载”概念，而是媒体语义（电影/季/剧集批量下载），避免用户理解负担。

### 15.7 直接文件访问 vs 虚拟管理：推荐折中方案

- **默认体验：虚拟管理优先**
  - 用户在下载中心管理离线资产（最一致）。
- **高级能力：允许文件可见**
  - 满足 iOS 文件共享与用户导出需求。
- **一致性保障机制**
  - `FileWatcher/Reconciler` 在关键时机扫描变更并修正任务状态。
  - 当检测到外部删除时，在下载中心显示“文件已丢失，可重新下载”。

### 15.8 状态不一致治理（你提到的 Downloads 目录可删文件问题）

必须落地的 4 个保护机制：

1. `LocalAsset.isAvailable` 不是常量，需周期校验。
2. `completed` 任务允许降级成 `orphaned`（文件丢失）。
3. 所有播放前调用 `resolvePlayableURL()` 做最终存在性校验。
4. 删除动作统一走 `DeletionIntent`：
   - `.taskOnly`
   - `.fileOnly`
   - `.taskAndFile`

### 15.9 参考同类 App 的可借鉴与不建议点

- **Infuse / Plex 风格（建议借鉴）**
  - 离线状态弱侵入展示，播放入口自动决策本地/远程。
  - 任务中心聚合而非把用户扔到文件系统。
- **云盘类 App 风格（部分借鉴）**
  - 支持文件夹下载与离线 Pin，但媒体语义弱。
- **不建议直接照搬**
  - 仅“文件下载列表”而无媒体关联，会导致详情页无法感知已离线。

### 15.10 建议实施顺序（开发前方案）

1. 定稿模型：补 `DownloadJob` 与 `orphaned` 语义。
2. 实现 `MediaLinkService.resolvePlayableURL()`，先打通“本地优先播放”。
3. 统一下载入口（Jellyfin/Emby/SMB/WebDAV）都创建 Job。
4. 上线下载中心聚合页与详情页离线态。
5. 增加外部删除 reconcile，收敛状态不一致。
6. 最后再做文件夹递归下载与智能清理。

> 该方案兼顾“媒体体验一致性”和“文件系统可控开放性”，可在不牺牲高级用户自由度的前提下，最大化降低状态漂移风险。

### 15.11 外部删除 Downloads 文件后的影响矩阵（重点）

你关心的核心是：**用户绕过下载中心，直接在 Files/本地文件页删除了 `Downloads` 里的文件，会如何影响 Jellyfin/Emby、文件类服务以及下载页面展示**。这里定义统一行为。

#### A. 数据层状态迁移（单一真相）

当 Reconciler 发现 `localFileURL` 不存在时，按以下顺序处理：

1. `LocalAsset.isAvailable = false`
2. `MediaLink.linkState = orphan`（保留关联线索，便于“重新下载”）
3. 若对应 `DownloadTask.status == completed`，降级为 `completed_but_missing`（或在现有枚举中映射为 `failed` + `errorCode=file_missing`）
4. 记录 `lastMissingDetectedAt`

> 关键点：**不要直接硬删除 MediaLink**，否则无法在详情页给出“文件已丢失，重新下载”的可恢复体验。

#### B. 对 Jellyfin/Emby 展示的影响

- 媒体库卡片：
  - 原“已下载”徽标 -> `文件已丢失`（warning 态）或退回“未下载”。
- 详情页按钮：
  - `播放（离线）` -> `播放`（流媒体）
  - 新增次级提示：`离线文件已被删除，可重新下载`
- 播放入口：
  - `resolvePlayableURL()` 本地命中失败后自动回退远端，不阻塞播放。

#### C. 对 SMB/WebDAV 文件类服务展示的影响

- 若条目来自 `remotePathHash` 关联：
  - “已下载”标签移除；
  - 保留“曾下载”历史（可选灰态），便于用户理解为何状态变化。
- 在文件详情页显示：
  - `本地缓存：不存在` + `重新下载`按钮。

#### D. 对下载中心页面展示的影响

下载中心建议新增一个分组或过滤：`文件丢失`（Missing）。

- 该分组展示来源（Jellyfin/Emby/SMB/WebDAV）、原标题、原完成时间。
- 支持快捷操作：
  1. `重新下载`（复用原参数创建新 task/job）
  2. `清理记录`（删除 task + orphan link）
- 全局统计中不计入“已完成可离线数”，避免误导。

#### E. 触发时机与一致性 SLA

最小化成本下建议 4 个触发点执行 reconcile：

1. App 冷启动后（后台线程分批扫描）
2. 进入下载中心时
3. 进入媒体详情页前（仅校验当前条目）
4. 播放前 `resolvePlayableURL()`（最终兜底）

这样可以在不做全量实时监听的情况下，把状态漂移窗口收敛到“下一次进入相关页面/播放前”。

#### F. 用户可感知文案建议

- Toast：`离线文件已不存在，已自动切换为在线播放`
- 下载中心空态提示：`部分已完成任务的本地文件被移除，可在“文件丢失”中重新下载`

#### G. 为什么这套策略适用于你提的三类场景

- **Jellyfin/Emby**：有 `remoteItemId`，可稳定回到详情并一键重下。
- **文件类服务**：即便没有媒体库实体，也可凭 `remotePathHash` 重建任务。
- **下载中心**：通过 `completed_but_missing/orphan` 显式化异常，不会出现“明明显示已下载却无法离线播放”的割裂体验。
