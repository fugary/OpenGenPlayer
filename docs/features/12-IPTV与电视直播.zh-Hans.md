# 模块 12：IPTV 与电视直播（M3U / M3U8 订阅与电子节目单 EPG）

## iOS 顶部原生搜索（2026-09-10 确认保留独立搜索）

- **最新确认**：用户选择“保留当前原生动画和独立搜索”。搜索继续使用独立原生圆形按钮，不再要求与视图切换、排序共用背景，也不为此更换展开动画。`pinnedTrailingGroup` 只调整顺序。

- 保持原“搜索 → 视图切换 → 排序”按钮顺序，系统搜索控制器常驻，原有操作按钮通过 `pinnedTrailingGroup` 排在搜索之后，点击 / 关闭保留同一控件连续形变；iOS 26 使用 `integratedButton` 并关闭底部工具栏集成，保持用户确认的顶部原生展开效果；iOS 15–25 使用原生导航搜索栏。
- 不添加灰色底板或整屏蒙层，不手动隐藏 / 禁用整个工具栏；激活时原生搜索栏的临时布局由系统处理。保留分组、排序及网格 / 列表的既有处理逻辑。旧系统使用随主题变化的原生不透明导航栏背景，首次打开自动聚焦，关闭恢复原配置；iOS 26 呈现不变。
- 未输入时浏览当前分组，输入后原地显示匹配频道。保持频道名 / 分组名匹配、防抖、排序缓存和独立分页；结果复用播放、收藏与 EPG 操作，清空 / 关闭恢复浏览现场。
- 已撤回底部搜索尝试；框外关闭按钮调整停止，保留上一版原生呈现。独立搜索背景已获用户接受，不能据此宣称三个按钮已合并。

## 1. 当前功能概览

- **定位**：纯净、高性能、跨平台（iOS / iPadOS / tvOS / macOS）的网络电视直播、频道管理与电子节目单 (EPG) 工具。
- **协议与格式支持**：
  - M3U / M3U8 播放列表（支持在线 HTTP/HTTPS 订阅 URL 及本地文件导入）。
  - 流式解析 `#EXTINF` 标签元数据（`group-title`, `tvg-logo`, `tvg-id`, `tvg-name`）及 `#EXTM3U x-tvg-url="..."` 自动 EPG 地址关联。
  - XMLTV 格式 EPG 电子节目单：支持 `.xml` 与 `.gz` / `.xml.gz` 格式（内存安全流式解压与 SAX 流式解析）。
  - 直播流格式：HLS (`.m3u8`)、HTTP-TS / MPEG-TS、HTTP-FLV、RTMP、RTSP 等。
- **电子节目单 (EPG) 能力**：
  - **多源 EPG 解析**：支持 M3U 头部 `x-tvg-url` / `url-tvg` 自动提取，并支持在服务器配置中手动自定义独立 EPG URL 覆盖。
  - **流式 SAX 解析与超快时间转换**：针对数十兆 XMLTV 结构设计低内存占用流式解析器，结合无 DateFormatter 开销的 `XMLTVDateParser` 实现毫秒级解析。
  - **智能模糊频道匹配**：多层级匹配策略（`tvg-id` 精准匹配 -> 归一化去标去缀去分辨率匹配 -> 频道名别名匹配），智能剥离 `[4K]`、`[HEVC]`、`CCTV-` 等标记。
  - **本地磁盘缓存**：12 小时 TTL 缓存，支持无网离线回退与手动“刷新 EPG”。
  - **全平台节目表浏览 (Program Guide)**：支持按日期切换（昨天 / 今天 / 明天 / 星期）、当前直播角标与进度条、即时换台播放。
  - **频道画面预览与台标回退体系**：
  - **动态视频画面快照 (`IPTVArtworkService`)**：在播放直播流 2.5 秒后或停止时自动调用 VLC 快照能力截取实时帧，存入本地磁盘缓存，在频道卡片和网格中展示真实视频预览。
  - **EPG XMLTV 台标回退**：若 M3U 缺少 `tvg-logo`，自动从 EPG XML 中的 `<channel><icon src="..."/>` 解析台标。
  - **优雅多级回退**：`本地真实视频快照 -> M3U Logo -> EPG Icon -> 极光霓彩微渐变暗黑台标占位卡`，彻底告别单调灰框。
- **播放器内节目单与交互集成**：
  - **macOS 播放器侧边栏**：播放器右上角工具栏提供「节目单」按钮（`RightSidebarTab.epg`），展开为半透明磨砂抽屉栏 `MacPlayerEPGSidebar`，支持日期切换、正在播放 LIVE 标识、时间进度条；播放列表行实时展示正在播放节目名称。
  - **iOS 播放器顶部入口**：播放器顶栏提供节目单快捷图标，直接呼出 `IPTVProgramGuideSheet`，无需离开播放器即可查阅节目单与切台。
  - **实时节目 OSD 与卡片展示**：频道网格/列表卡片及视频播放器控制层底部展示当前正在播出的节目名称、时间段与实时播放进度。
- **核心交互**：
  - 频道分组浏览与快速过滤（如“全部”、“我的收藏”、“央视频道”、“卫视频道”等）。
  - 频道多维度排序（默认源顺序、频道名称 A-Z / Z-A、分组名称、收藏优先）与升序/降序支持及偏好持久化。
  - 频道搜索、星标收藏、台标异步加载。
  - 直播播放适配：自适应直播状态、OSD 状态栏、画中画 (PiP)。
  - tvOS 遥控器焦点与全宽响应支持。
- **安全与合规原则**：
  - 客户端不内置、不硬编码任何固定电视频道源，由用户自主输入或导入。

## 2. 关键实现位置

- **数据模型**：
  - IPTV 模型：`GenPlayerCore/Sources/GenPlayerCore/IPTVModel.swift`（`IPTVChannel`, `IPTVGroup`, `IPTVPlaylist`, `IPTVSortField`, `IPTVSortOrder`）。
  - EPG 模型：`GenPlayerCore/Sources/GenPlayerCore/EPGModel.swift`（`EPGProgramme`, `EPGChannelInfo`, `EPGTable`, `EPGDateFormatter`）。
- **解析引擎**：
  - M3U 解析：`GenPlayerCore/Sources/GenPlayerCore/M3UParser.swift`。
  - Gzip 解压：`GenPlayerCore/Sources/GenPlayerCore/GzipDecompressor.swift`。
  - XMLTV SAX 解析与日期解析：`GenPlayerCore/Sources/GenPlayerCore/XMLTVParser.swift`。
- **服务层**：
  - `GenPlayerCore/Sources/GenPlayerCore/IPTVService.swift`。
  - `GenPlayerCore/Sources/GenPlayerCore/EPGService.swift`。
  - `GenPlayerCore/Sources/GenPlayerCore/IPTVArtworkService.swift`（视频快照管理）。
- **页面入口与节目表组件**：
  - iOS: `IPTVPlaylistView.swift`, `IPTVProgramGuideSheet.swift`, `PlayerBottomBar.swift`, `PlayerTopBar.swift`, `PlayerView.swift`。
  - tvOS: `TVIPTVPlaylistView.swift`, `TVIPTVProgramGuideSheet.swift`, `TVPlaybackPresentationView.swift`。
  - macOS: `MacIPTVPlaylistView.swift`, `MacIPTVProgramGuideSheet.swift`, `MacPlayerSheet.swift`, `MacPlayerRightSidebar.swift`。
  - 服务器编辑：`ServerListView.swift` (iOS), `TVServerEditorView.swift` (tvOS), `MacMediaServerViews.swift` (macOS)。
- **单元测试**：`GenPlayerTests/EPGParserTests.swift`。

## 3. 开发实现步骤

1. **扩展服务类型与 EPG 配置**：在 `ServerConfig.ServerType` 中扩展 `case iptv`，支持 `customEPGURL` 配置。
2. **构建 M3U 与 XMLTV 解析器**：实现流式 M3U 与 XMLTV SAX 解析器，支持 `.gz` 压缩流。
3. **实现服务管理与持久化**：管理远程 M3U 与 EPG 磁盘缓存、12 小时更新策略，支持无网回退。
4. **搭建频道列表与节目单 UI**：
   - iOS: 频道卡片实时节目与进度条、节目表弹窗（`IPTVProgramGuideSheet`）、播放器底部实时节目指示器。
   - tvOS: 焦点友好的全宽行式网格、`TVIPTVProgramGuideSheet` 节目表浏览、OSD 实时节目指示。
   - macOS: 自适应折叠标签、网格/列表切换、`MacIPTVProgramGuideSheet` 节目单弹窗。
5. **多语言与跨平台验证**：覆盖 8 国语言本地化，并在 iOS、tvOS 完成构建与单元测试验证。
