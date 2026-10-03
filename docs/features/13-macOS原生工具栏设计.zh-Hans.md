# macOS 现有顶栏的原生按钮与材质设计

日期：2026-09-12。状态：本地浏览页已接入；用户确认 circular bezel 的 hover 外观，并要求同类 macOS 按钮统一使用该方案，其他交互仍按范围待回归。

## 1. 目标与边界

保留当前按钮功能、位置、顺序、分组和页面布局，替换材质及系统交互反馈。用户认为现有分组和 hover 已经接近参考，重点是显示质感与反馈；本提案以这一约束为准。

- 保持左侧返回/Home、中间标题及路径、右侧搜索/视图/排序/刷新的现有分组。末尾目录操作按页面上下文显示：首页为添加目录，子目录为新建文件夹。
- 搜索在原入口横向展开为原生输入框，替换原搜索 popover；保留视图切换、排序与文件操作，添加本地文件夹只在首页显示。不移动搜索，不新增前进按钮。
- 保留现有 header 容器、顶部留白、内容起始位置和侧栏布局。
- 仅修改 macOS 控件呈现；播放器以及 iOS/tvOS 不在范围内。

## 2. 可用的原生能力

可以在当前页面顶栏内使用系统按钮与玻璃材质，不必迁入窗口 NSToolbar。

Apple 提供 [SwiftUI GlassButtonStyle](https://developer.apple.com/documentation/swiftui/glassbuttonstyle)（Button 的 .buttonStyle(.glass)）以及 [AppKit NSButton.BezelStyle.glass](https://developer.apple.com/documentation/appkit/nsbutton/bezelstyle-swift.enum/glass)。本机 Xcode SDK 已确认相关符号存在，AppKit glass 按钮最低要求 macOS 26。

[WWDC25 AppKit 设计说明](https://developer.apple.com/videos/play/wwdc2025/310/)同时介绍 NSGlassEffectView 与 NSGlassEffectContainerView，可为自定义布局中的内容提供系统玻璃及组合效果。

原生材质和原生按钮可以直接使用，但页面内的玻璃按钮不等于窗口工具栏项目：工具栏还有按上下文自动分组、布局和背景适应行为。不能在实现前承诺与备忘录像素级一致，也不能把普通毛玻璃称为 Liquid Glass。最终效果会受到背景内容、系统版本和辅助功能设置影响。

## 3. 当前实现

此前已核对源码：

- MacLocalToolbarModifier 与 MacServerToolbarModifier 使用页面 overlay 和 Capsule().fill(.ultraThinMaterial)。
- MacHeaderButtonStyle 自绘 36 × 36 点击区、圆形 hover 高亮、按压缩放和动画。
- 部分排序/视图入口使用自定义 popover；本次不扩展到菜单内容重做。
- 页面由 MacDetailCacheController 缓存。采用原位替换后继续由原页面持有动作及状态，无需引入窗口级工具栏所有者。

## 4. 控件方案

| 层次 | 设计 |
| --- | --- |
| 外层布局 | 保留现有 HStack、左右锚点、间距、标题与分组占位 |
| 组背景 | 将现有 ultraThinMaterial 胶囊替换为系统玻璃容器，沿用原组轮廓与位置 |
| 可交互按钮 | macOS 同类图标按钮桥接 AppKit NSButton，使用 circular bezel 与系统 hover/按压反馈；既有按钮组单独承载玻璃 |
| 状态与反馈 | 保留相同动作闭包、disabled、help 和可访问名称；系统处理按钮反馈，移除与之重复的自绘 hover/缩放 |
| 旧系统 | 保留兼容路径及现有功能/位置；macOS 26 专属 API 使用可用性分支 |

采用“系统玻璃组背景 + 原生控件”：两个原有组分别使用 glassEffect(.regular, in: Capsule())，组内 NSButton 使用 circular bezel、borderShape = .circle 和 showsBorderOnlyWhileMouseInside。圆形按钮反馈由 AppKit 绘制，不叠加自定义 hover 背景或按压缩放，也不让整个按钮组响应整体按压。选用系统 circular bezel 后，用户截图与反馈确认 hover 外观可以；保留这一实现，不再调整按钮样式。该确认不代表完整验证按压、键盘及所有系统设置下的表现，也不等同于 NSToolbar 分组。

保留按钮中心位置及外层布局占位；系统内在尺寸、内容边距和反馈绘制需要在原占位内适配，避免硬裁切光效或强制缩放原生控件。若原生布局无法在原尺寸中完整显示，应明确记录具体差异，不能自行重排入口。

## 5. 实施及验收

统一通过 macOS 专用的 MacToolbarButton 与 MacToolbarGlass 包装，覆盖本地/远程文件浏览、网络页、Jellyfin/Emby/Plex 媒体库、IPTV、历史/收藏顶栏及下载卡片的图标操作。按钮保留各处原有尺寸、图标字号、间距、动作与 popover 所有者；下载图标继续使用 28pt 占位，其余顶栏通常为 36pt。enabled、tooltip、可访问名称与最新动作闭包同步到 NSButton，破坏性操作保留红色语义及原确认流程。

macOS 26 以下继续使用兼容样式。播放器、轮播导航、媒体卡片主体、菜单内容与文本操作不属于本轮同类图标按钮迁移；iOS/tvOS 不变。

必须保留：目录进入/返回/Home、搜索范围与关闭行为、排序和视图状态、刷新禁用条件、目录授权与新建的既有处理逻辑、页面切换后的缓存现场。

“添加本地文件夹”仅在本地首页显示，所选目录进入首页的授权目录列表，不移动或复制文件；子目录仅显示“新建文件夹”，在当前浏览目录中创建子目录。两者共用右侧组末尾位置，避免把全局授权误解为添加到当前目录。

实施后的人工抽样范围：

1. 对照原布局核对按钮位置、顺序、组宽及标题/面包屑/内容起始位置。
2. 检查浅深主题下玻璃、hover、按下/松开、禁用与键盘焦点，确认无双重背景和重复动画。
3. 检查搜索、排序、视图切换、刷新以及两种目录操作均维持原功能。
4. 检查窗口缩放、全屏、切换缓存页面与降低透明度，确认无裁切或状态丢失。

除用户已确认的 hover 外观外，其余运行交互仍待按范围验证。Agent 操作 App、截图或录屏须按 AGENTS.md 3.8 获批；纯构建结果记录在同日开发日志中。

## 6. 搜索原位展开（2026-09-12）

本地及服务器浏览顶栏共用 macOS 专用展开搜索组件。保留右侧按钮顺序与组的右锚点，搜索从 36pt 图标占位向左展开为 240pt 原生 NSSearchField；输入框的绘制、编辑、输入法和清除按钮由 AppKit 负责，宽度与淡入淡出由页面动画控制，不宣称为 iOS 或 NSSearchToolbarItem 的系统展开动画。开启减少动态效果时直接切换。

展开后自动聚焦，标题及副标题始终保留。根据左右按钮组的实际边界安排标题：空间足够时维持页面居中，空间不足时限制标题宽度并调整至按钮之间，长文字沿用截断，不再因打开搜索而隐藏标题。Esc、点击当前窗口输入框外或结束编辑时收起，保留关键词及结果；系统清除按钮只清空关键词。页面离开撤销聚焦请求并收起，已有查询绑定、范围、排序、结果导航与页面缓存继续沿用。保持 header 高度及内容起始位置，仅影响 macOS。

手工抽样检查本地搜索的展开/收起与中文输入，媒体库输入后结果/详情返回，IPTV 搜索及排序，以及窄窗口、缓存页切换和减少动态效果；执行 GUI 检查仍须按 3.8 获批。

## 7. 旧版 macOS 兼容边界

项目及 GenPlayerShell 的最低部署版本保持 macOS 12，兼容 Intel x86_64 与 Apple Silicon arm64 的编译目标。本轮不提高系统要求。

- macOS 26：MacNativeToolbarButton 使用 AppKit circular bezel、borderShape；按钮组使用系统 glassEffect，两者都受版本判断保护。
- macOS 12–15：继续使用既有 SwiftUI Button 兼容样式与 ultraThinMaterial，不调用 macOS 26 API，外观按旧系统能力回退。
- 搜索使用 NSSearchField，标题布局使用 Anchor/PreferenceKey/GeometryReader；不依赖 macOS 26 搜索工具栏，也不引入 macOS 13 才可用的 Layout API。

最低部署版本编译及 API 可用性检查只证明编译层面的兼容性；旧系统上的焦点、输入法、popover、hover/禁用、动画性能与外观仍须在实际系统抽样验证，不能把新 SDK 的构建视为已在旧 macOS 运行通过。
