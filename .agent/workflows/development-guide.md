---
description: GenPlayer iOS 项目开发规范
---

# GenPlayer 开发规范

## 平台兼容性要求 ⚠️ 重要

| 平台 | 最低版本 |
|------|----------|
| iOS/iPadOS | **15.0** |
| tvOS | **16.0** |

## 禁止使用的 API (iOS 15+ Only)

以下 API 仅在 iOS 15+ 可用，**禁止直接使用**：

### SwiftUI Alert
```swift
// ❌ 禁止 - iOS 15+
.alert("Title", isPresented: $show) {
    Button("OK", role: .cancel) { }
}

// ✅ 正确 - iOS 13+
.alert(isPresented: $show) {
    Alert(title: Text("Title"), primaryButton: .default(Text("OK")), secondaryButton: .cancel())
}
```

### Button with Role
```swift
// ❌ 禁止 - iOS 15+
Button("Delete", role: .destructive) { }

// ✅ 正确 - iOS 13+
Button(action: { }) {
    Text("Delete").foregroundColor(.red)
}
```

### Colors
```swift
// ❌ 禁止 - iOS 15+
Color.indigo
Color.mint
Color.cyan
Color.teal
Color.brown

// ✅ 正确 - iOS 13+
Color(UIColor.systemIndigo)
Color(UIColor.systemMint)
Color(UIColor.systemCyan)
Color(UIColor.systemTeal)
Color(UIColor.systemBrown)
```

### 其他 iOS 15+ API
- `@FocusState` - 使用其他方式管理焦点
- `.searchable()` - 使用 UISearchController 或自定义搜索
- `.refreshable` - 使用 UIRefreshControl
- `AsyncImage` - 使用 Kingfisher 或自定义加载
- `task { }` modifier - 使用 `onAppear` + Task {}

## 依赖项

- MobileVLCKit (VLCKitSPM)
- SnapKit (Auto Layout)
- Kingfisher (Image Caching)

## 开发工具

- Xcode 15.0+
- Swift 5.0+
- SwiftUI + UIKit 混合

## 防回归工作方式（无自动化测试前提）

### 1. 默认最小改动

- 优先做与用户需求直接相关的最小补丁。
- 不要顺手重构、不做无关命名整理、不批量改共享逻辑。
- 若必须修改共享基础代码，先评估会影响哪些旧页面/旧行为。
- **跨平台隔离原则**：改动默认不要影响其他平台，必须保证 iOS、tvOS 以及 macOS 各端表现独立。除非明确要求实现多端支持或一致性对齐，否则严禁为了某一平台的需求而强行修改共享组件，导致其他平台出现回归。

### 2. 高风险区域

以下区域默认按高风险处理：

- 导航与页面呈现
- 播放器、PiP、seek、字幕/音轨
- 下载中心、缓存/离线播放
- 语言、本地化、设置持久化
- 服务器管理、历史、收藏及其同步刷新
- 共享组件、共享服务、全局状态源

### 3. 动手前先保留旧行为

- 修改高风险区域前，先确认“本次要保留哪些旧行为”。
- 如果只是在修一个局部 bug，不应顺带改变相邻页面的既有交互。
- 若确实需要改变既有行为，必须能说明这是用户明确要求，而不是实现副作用。

### 4. 交付前最低验证

- 代码改动至少完成一次项目构建检查；纯文档改动只检查文档内容与差异，不要求构建。
- 没有自动化测试时，按改动范围安排 `docs/tasks/CoreManualRegressionChecklist.zh-Hans.md` 中对应模块的手工回归；日常改动通常覆盖 2-4 条关键链路，发布前覆盖整份清单。
- **用户审批优先（详见 `AGENTS.md` 3.8）**：agent 操作模拟器、录屏、主动截图或通过 GUI 自动化操作桌面 App / 真机前，必须取得用户明确批准。会启动 / 操作模拟器或 App 的测试、脚本及独立验证样例同样受限；普通开发 / 测试请求和回归清单不能作为默认授权。
- 先完成可独立执行的代码修改、静态检查及纯构建，再说明待验证问题、设备 / 页面、最少步骤、是否截图 / 录屏及预计录屏时长，申请批准。仅在已批准范围执行，不重复询问已有明确授权，不自行扩大验证范围；批准模拟器操作不自动批准录屏，未回复不等于批准。
- 未获批准时继续完成不依赖 GUI 的工作，交付时注明未验证项、审批原因和剩余风险，不为凑齐回归清单自行操作。使用模拟器 SDK 的纯构建和不启动 / 操作模拟器或 App 的测试不受本条额外审批限制。

### 5. 结果汇报要求

- 完成后明确说明：
  - 改了什么
  - 已验证什么
  - 哪些高风险项没有验证
  - 仍然存在什么剩余风险
- 不要用“应该没问题”“理论上正常”替代验证结果。

### 6. 开发日志记录与读取

- 遵守 `AGENTS.md` 第 7 节：在任务收尾时，将最终结果写入 `docs/tasks/dev-log/YYYY-MM.md`；`docs/tasks/daily_dev_log.md` 仅作为月份索引。新月份首次写入时更新索引。
- 每项任务默认一条、3-5 个简短要点，只包含最终交付结果、最终验证结论及必要未解决问题 / 风险；同日继续修订应更新原条目，不追加中间过程。
- 不记录试验步骤、反复修改、逐次构建 / 工具操作、临时路径或大段输出；有长期价值的原因 / 决策可简述，未验证项不得宣称通过。
- 常规任务不默认读取日志；确需追溯时限定月份与关键词，用 `rg -n` 定位后局部读取。追加记录只需查看当月对应日期 / 任务，不扫描或输出全部归档。
- 文档以 UTF-8 保存；拆分 / 迁移时检查正文替换字符（U+FFFD）和中文可读性。编码损坏须核对 Git 中的正常原文后恢复，不能以复制一致代替可读性检查，也不能静默忽略 / 替换解码错误后覆盖文件。
