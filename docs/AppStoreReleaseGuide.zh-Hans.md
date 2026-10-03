# Gen Player Multi-Platform (iOS, tvOS & macOS) App Store 发布指南

本指南旨在详细说明将 Gen Player (iOS, tvOS 与 macOS 独立原生 Target 共享包) 发布到 Apple App Store 的标准流程与针对本项目的特定要求。

---

## 0. 快速发布自动化

- 仓库已提供 `scripts/prepare_appstore_release.sh`，可用于自动递增版本号、递增构建号、生成精简版中英文 release notes、按版本落盘的详细 changelog，以及 tag 注释草稿，并可选执行构建校验、提交与推送。
- **iOS, tvOS & macOS 版本同步**：脚本会自动同步更新 iOS Target (`GenPlayer`)、tvOS Target (`GenPlayer_tvOS`) 与 macOS Target (`GenPlayer_macOS`) 的 `MARKETING_VERSION` (Version) 和 `CURRENT_PROJECT_VERSION` (Build)，以确保三者在 App Store Connect 中作为同一 Universal App 进行合并和管理。
- **多平台构建校验**：在准备发布版本时，若未指定 `--skip-build`，脚本会自动利用 `xcodebuild` 分别验证 iOS (`GenPlayer`)、tvOS (`GenPlayer_tvOS`) 与 macOS (`GenPlayer_macOS`) 三个 Scheme 的编译正确性，确保发布前无任何构建回归。
- 仓库已提供 GitHub Actions 工作流 **`Prepare App Store Release (iOS, tvOS & macOS)`**，适合把“同步多端版本号 -> 生成 release notes / changelog -> 提交回仓库 -> 打 tag”收敛到 GitHub 上执行。
- 默认行为适合“当前线上版本已上架，准备提交补丁版”场景：
  - 若当前版本为 `1.0`，脚本默认将其提升到 `1.0.1`
  - `Build` 默认在当前值基础上加 `1`
- 若只是测试发布 / TestFlight / 内部验证，可使用 `--build-only` 保持当前 `Version` 不变，仅递增 `Build`
- 常用命令：
  - 仅准备版本号与 release notes：`scripts/prepare_appstore_release.sh --base-ref <git-ref>`
  - 仅递增测试构建号：`scripts/prepare_appstore_release.sh --build-only --base-ref <git-ref>`
  - 准备并校验构建：`scripts/prepare_appstore_release.sh --base-ref <git-ref>`
  - 准备、提交并推送：`scripts/prepare_appstore_release.sh --base-ref <git-ref> --commit --push`
- 每次准备完成后会生成 3 类文件，便于后续提交 App Store：
  - `docs/releases/latest_app_store_release_notes.md`：最新一版、可直接复制到 App Store Connect 的中英文精简更新说明
  - `docs/releases/<release-slug>.md`：按版本保存的详细 changelog，包含基线、提交数、diff 摘要和 commit 列表
  - `docs/releases/<release-slug>.tag.md`：供 git tag 注释复用的摘要内容
- 推荐 of GitHub Actions 流程：
  - `build-only`：用于 TestFlight / 内部验证，只递增 `Build`
  - `app-store`：用于准备正式版本，若当前版本已上架则自动提升到下一个补丁版
  - 工作流会把改动提交回触发分支，并可按模式自动打 tag：
    - 正式版：`v<version>`
    - 测试构建：`build/v<version>-b<build>`
  - 新生成的 tag 会直接复用 `docs/releases/<release-slug>.tag.md` 作为注释内容，避免 tag 只有空泛的版本号
- `--base-ref` 建议传入“当前线上版本对应的最后一个 git 提交”，这样生成的 release notes 会更贴近真实线上版本以来的变动。
- 从第二次使用开始，脚本与工作流都会优先用“最新 tag”作为 release notes 基线；首次补上 tag 之后，后续就不必每次手填 `base_ref`。
- 若同一版本 / 构建号重复准备，`docs/releases/<release-slug>.md` 与 `docs/releases/<release-slug>.tag.md` 会按同名覆盖，方便重新生成变更说明；已有同名 git tag 默认跳过，不强制改写历史 tag。
- 该脚本不会直接替你点 App Store Connect 的 `Create a new version` / `Submit for Review`；它负责把仓库内的版本、说明和代码状态准备好，最后仍需在 App Store Connect 完成版本关联与提审。
- 经验规则：
  - 测试发布 / TestFlight：通常可以保持 `Version` 不变，只递增 `Build`
  - 正式 App Store 新版本：若当前版本已经上架，需新建更高的 `Version`，不能只递增 `Build`
- 使用 GitHub Actions 前建议确认：
  - 仓库 `Actions` 对 `contents: write` 开放，允许工作流提交版本号变更与 tag
  - 若 `main` 开了严格保护，需允许 GitHub Actions bypass，或改为在 release 分支上触发后通过 PR 合并

---

## 0.1 开源依赖发布检查（mpv / VLC）

当前公开源码仓库为 https://github.com/fugary/OpenGenPlayer 。原创应用代码采用 MIT；第三方代码和修改后的 LGPL 文件继续遵循各自许可证。

每次正式发布前执行：

1. 冻结实际 Archive 使用的源码与依赖版本，使用 `scripts/export_open_source.py` 同步脱敏后的源码到独立公开仓库检出；审核差异后提交，并按实际版本和构建号打不可变 tag。记录公开提交、私有提交、依赖校验值与 Archive 的对应关系，不能用持续变化的 main 代替版本留档。
2. 按最终 Archive 逐项核对 mpv、FFmpeg、VLC 及传递依赖的版权/许可；把适用许可证和版权声明随 App 打包。共享壳层 `Resources/Licenses` 已补主要 MIT/GPL/LGPL/字体文本，仍需补齐全部实际打包依赖的声明。
3. 为使用的预编译库提供对应源码、补丁、构建配置和脚本。核对 LGPL 所需重新构建/重链接及适用安装信息；现有 App 源码公开和 VLC 补丁不代表 MPVKit 全部预编译依赖的对应源码材料已经齐全。
4. 在 App Store Connect 核对加密出口合规答案与实际 GnuTLS/OpenSSL 等依赖；按实际用法填写，不能仅因 App 已开源就跳过。

App 的“开源许可”页面已增加项目源码入口，tvOS 沿用二维码访问方式。公开仓库当前快照未声明对应某个已上架版本。上述材料和最终分发条件核对完成前，不把“已开源”记为“发布合规已完成”。

## 1. 发布前准备 (Preparation)

### 1.1 开发者账号与凭证
- 确保拥有有效的 **Apple Developer Program** 账号。
- 在 [Apple Developer Portal](https://developer.apple.com/) 中创建以下项：
  - **App ID**: `com.fugary.player.GenPlayer` (iOS, tvOS 与 macOS 共享同一个 App ID，实现跨平台通用购买)。
  - **Distribution Certificate**: 用于 App Store 发布的分发证书。
  - **Provisioning Profile**: 关联 App ID 与分发证书的描述文件。

### 1.2 App Store Connect 基础信息
在 [App Store Connect](https://appstoreconnect.apple.com/) 中创建新 App 并填写以下元数据：
- **名称**: Gen Player (若被占用需微调)。
- **副标题**: 简洁的功能描述 (如：全能媒体中心与播放器)。
- **隐私政策 URL**: `https://genplayer.fugary.com/privacy.html`
- **支持 URL**: `https://genplayer.fugary.com/feedback.html`
- **描述**: 详述 App 功能、支持的协议 (SMB/WebDAV/Jellyfin/Emby 等) 及播放能力。
- **关键词**: 媒体库, 播放器, VLC, SMB, WebDAV, 离线管理。

---

## 2. 视觉素材 (Assets)

### 2.1 App 图标
- **iOS 图标**：必须提供 **1024x1024** px 的无圆角直角正方形 PNG 图标。图标中不要包含额外的圆角或设备外边框，只保留图标本身的设计元素（例如播放三角等）。
- **tvOS 图标**：在 Xcode 中通过 `GenPlayer_tvOS` 目标的 `App Icon & Top Shelf Image` 资源进行配置，需要包含符合 Apple TV 规范的多层立体效果图。禁止提交仅有 `Contents.json`、没有实际图层图片的空壳 brandassets，避免系统桌面出现缺失图标的问题。

### 2.2 预览截图 (Screenshots)
根据 Apple 要求提供以下规格的截图：
- **iPhone 6.5"**: (如 iPhone 11/12/13/14 Pro Max) 1284 x 2778 或 1242 x 2688。
- **iPhone 5.5"**: (如 iPhone 6s/7/8 Plus) 1242 x 2208。
- **Apple TV (tvOS)**: 3840 x 2160 或 1920 x 1080 截图，突出电视端大屏的海报墙浏览、播放控制及多端同步等特色功能。
> [!TIP]
> 截图应展示核心功能：媒体库概览、播放界面、服务器管理。

---

## 3. Xcode 配置与编译 (Build)

### 3.1 目标与版本一致性
- iOS、tvOS 与 macOS 属于同一个通用 App 购买包，在 App Store Connect 中关联同一个发布版本号。
- **必须保证 iOS (`GenPlayer`)、tvOS (`GenPlayer_tvOS`) 与 macOS (`GenPlayer_macOS`) 的版本号 (`MARKETING_VERSION`) 与构建号 (`CURRENT_PROJECT_VERSION`) 完全相同**，否则上传后苹果无法正确将其关联在同一个版本中。

### 3.2 归档 (Archive)

#### A. 编译 iOS App
1. 在 Xcode 运行目标选择 **`GenPlayer`** Scheme。
2. 运行设备选择 **Any iOS Device (arm64)**.
3. 菜单栏选择 `Product` -> `Archive`。
4. 等待编译完成，弹出 `Organizer` 窗口。

#### B. 编译 tvOS App
1. 在 Xcode 运行目标选择 **`GenPlayer_tvOS`** Scheme。
2. 运行设备选择 **Any tvOS Device (arm64)**.
3. 菜单栏选择 `Product` -> `Archive`。
4. 等待编译完成，弹出 `Organizer` 窗口。

---

## 4. 提交审核 (Submission)

### 4.1 分发到 App Store Connect
1. 在 `Organizer` 中，分别选中 iOS 和 tvOS 的最新 Archive。
2. 点击右侧的 `Distribute App`。
3. 选择 `App Store Connect` -> `Upload`。
4. 按照向导完成证书签名与上传（通常先传 iOS，再传 tvOS，或者顺序不限）。

### 4.2 TestFlight 测试 (强烈推荐)
- 上传成功后，在 App Store Connect 的 **TestFlight** 标签下：
  - 在 **iOS** 列表下，将已上传的 iOS 构建版分配给测试组。
  - 在 **tvOS** 列表下，将已上传的 tvOS 构建版分配给测试组。
- 在真机 iOS 设备及 Apple TV 设备上通过 `TestFlight` App 验证生产环境包的稳定性和同步机制。

### 4.3 提交审核 Review
1. 在 App Store Connect 的 **App Store** 标签下，关联已上传的构建版本：
   - 在 **iOS App** 版本块中选择刚才上传的 iOS 构建。
   - 在 **tvOS App** 版本块中选择刚才上传的 tvOS 构建。
2. 完善“审核备注”与本地化文案：
   - 从 `docs/releases/latest_app_store_release_notes.md` 中复制自动生成的中英文更新日志，并粘贴至各语言的 **“此版本的新增内容”** 中。
   - 提供演示用的媒体服务器信息（如 Jellyfin/Emby 账号，若使用本地测试环境可特别说明）。
   - 补充关于 VLC 核心的声明（遵循 LGPL 协议）。
3. 点击 **Submit for Review** (提交审核)。

---

## 5. 后续事项 (Post-Release)

- **更新日志**: 审核通过并发布后，将最终发布版本与日期记录到 `docs/tasks/dev-log/YYYY-MM.md`（月份索引：`docs/tasks/daily_dev_log.md`）。
- **版本管理**: 建议在 Git 中对发布版本打 Tag (如 `v1.0.0`)。
- **官网更新**: 若有架构变化，同步更新官网的功能说明。

---
> [!IMPORTANT]
> 遵循 `AGENTS.md` 规则，发布包必须经过 `xcodebuild` 验证，确保没有因回归导致的崩溃或严重的 UI 问题。
