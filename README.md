# OpenGenPlayer

GenPlayer 的公开源码，支持 iOS/iPadOS、macOS 和 tvOS。本地及远程媒体浏览、播放、字幕、历史/收藏与下载功能使用 Swift、SwiftUI/UIKit/AppKit、libmpv 和 VLC。

## 获取与构建

```sh
git clone https://github.com/fugary/OpenGenPlayer.git
cd OpenGenPlayer
python3 scripts/build_vlckit_rate_fix.py
open GenPlayer.xcodeproj
```

需要 macOS、完整 Xcode 和命令行工具；平台下限为 iOS 15、macOS 12、tvOS 16。VLC 源码构建还需要上游构建工具，详见 [构建指南](docs/BUILDING.zh-Hans.md) 和 [VLC 构建说明](VLCKitPatched/README.md)。首次源码构建和依赖下载耗时较长。

使用自己的 Apple 签名团队和 OAuth 注册信息。未配置 Google/OneDrive OAuth 时，这两项登录不可用；本地播放和其他服务器不依赖这些注册信息。

## 源码范围

本仓库包含应用源码、共享库、测试、mpv/VLC 修改及构建脚本。私人 Git 历史、用户数据、签名私钥、生产 OAuth 配置、内部开发日志和真实服务器截图不公开。

`SOURCE_SNAPSHOT.json` 记录本次源码快照及公开构建所需的配置调整。该分支是源码同步准备版本，未声明对应某个已经上架的二进制。正式发布时需要为对应源码打版本标签。

## 许可与第三方组件

GenPlayer 自身的原创代码采用 MIT 许可，见 [LICENSE](LICENSE)。第三方源码和库保留各自许可，不因根目录许可证而改变。详情见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。本仓库公开不代表已完成最终 App Store 发行包的全部许可与签名/安装条件核对。

GenPlayer 名称、商标、第三方服务标识和素材权利独立于代码许可。使用自己的 OAuth/签名配置，不应使修改版本冒充官方发行。
