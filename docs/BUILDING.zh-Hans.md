# 公开源码构建指南

## 1. 工具与依赖

使用完整 Xcode，并通过 `xcode-select` 选择该 Xcode 的开发目录。应用最低支持 iOS 15、macOS 12、tvOS 16；当前开发源码包含较新 SDK 的条件分支，建议使用开发该版本的相同 Xcode/SDK。平台最低版本不等同构建工具最低版本。

先运行：

```sh
python3 scripts/build_vlckit_rate_fix.py
```

该脚本按固定提交下载 VLCKit/VLC 源码、应用补丁并构建 iOS framework；macOS/tvOS 使用校验过的原始 3.7.3 发行包切片。构建目录和 `VLCKitPatched/Artifacts` 不提交。VLC 构建工具可能需要额外安装上游要求的 autoconf、automake、libtool、pkg-config、cmake、nasm 等工具；请按具体构建错误及上游说明配置。

MPVKit 1.0.0 和其他远程 Swift 包由 Xcode 解析；具体版本见 `GenPlayerCore/Package.resolved`。MPVKit 的普通 LGPL 产品与 GPL 产品不同，本项目引用普通 `MPVKit` 产品。不要自行换成 `MPVKit-GPL`。

## 2. 本地 OAuth/签名配置

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

填写自己的客户端信息，文件已被 Git 忽略：

- `GENPLAYER_GOOGLE_CLIENT_ID`：Google 原生应用注册的客户端 ID。
- `GENPLAYER_GOOGLE_CALLBACK_SCHEME`：该注册对应的反向客户端 ID 回调 scheme，不包含 `:/oauth2redirect` 后缀。
- `GENPLAYER_GOOGLE_DEVICE_CLIENT_ID`、`GENPLAYER_GOOGLE_DEVICE_CLIENT_SECRET`：电视/有限输入设备流程的独立注册信息；手机为电视扫码授权时同样使用这些值。tvOS 的 `GENPLAYER_GOOGLE_CLIENT_ID` 填该设备注册 ID。
- `GENPLAYER_ONEDRIVE_CLIENT_ID`：自己的 Microsoft 公共客户端应用 ID，注册允许原生及设备码流程，并配置 `genplayer://oauth/onedrive` 回调。
- `DEVELOPMENT_TEAM`：自己的 Apple 团队 ID。Bundle Identifier 与相应 OAuth 注册/签名配置需要匹配；分发自己的修改版本时使用自己的标识。

这些参数写入构建产物的 Info.plist。原生客户端无法保守客户端机密；配置隔离用于避免借用官方注册，不是把客户端变成机密服务端。任何真正需要保密的服务端密钥不得嵌入 App。

命令行纯构建例子：

```sh
xcodebuild -project GenPlayer.xcodeproj -scheme GenPlayer_macOS \
  -configuration Debug -destination 'platform=macOS' \
  -xcconfig Config/Local.xcconfig \
  -derivedDataPath /tmp/opengenplayer-macos-build CODE_SIGNING_ALLOWED=NO build
```

其他 scheme 为 `GenPlayer`（iOS）和 `GenPlayer_tvOS`。模拟器纯构建使用 `generic/platform=iOS Simulator` 或 `generic/platform=tvOS Simulator`，不需要启动模拟器。

Xcode GUI 构建时，在所需 target 的 Build Settings 中填写同名用户定义设置和自己的 Signing Team，或配置本地 xcconfig；不要提交个人配置。未经签名的纯构建不能代替设备安装和 App Store 归档验证。

## 3. 发行版本与库修改

mpv 原生渲染和 ASS 修改位于 `GenPlayerCore/Sources/GenPlayerMPVBridge`，来源和 ABI 约束见该目录 README。VLC 修改位于 `VLCKitPatched/patches`，固定源码版本和构建脚本已随仓库提供。

正式发行前固定全部依赖版本，提供与实际二进制对应的库源码（包括 MPVKit 上游构建补丁和传递依赖）、构建材料、许可声明并打对应标签。公开应用源码不是对预编译依赖对应源码、适用安装信息或商店条款问题的自动豁免。本次同步仅准备公开开发分支。
