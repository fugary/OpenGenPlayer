# PiP 渲染与交互修复（2026-04-02）

## 背景
本次调整聚焦视频 PiP 的 5 个问题：

1. PiP 画面比例异常（拉伸）。
2. PiP 前进/后退秒数与主播放器配置不一致。
3. PiP 还原按钮偶发无法恢复全屏。
4. PiP 进度交互可用性不足（在可 seek 资源上交互受限）。
5. PiP 画面卡顿。

## 实现要点

- 提升 sample-buffer PiP 渲染目标帧率至 15fps，并缩短 VLC snapshot 节流窗口，改善低帧率体感。
- VLC snapshot 请求改为单边尺寸 + 另一边传 0，依赖 VLC 保持原始纵横比，减少拉伸。
- timeline 交互能力判定改为基于 `state.duration` 有效值，而不是仅依赖 VLC 的 `isSeekable` 即时状态。
- PiP skip 操作统一映射到 `AppSettings.shared.doubleTapSeekDuration`，与主播放器双击快进/快退配置一致。
- PiP 恢复时，对无扩展名 URL 的媒体类型增加推断兜底，降低 restore 失败概率。

## 兼容性

- 所有变更保持 iOS 15+ PiP 分支内执行。
- iOS 14 仍走既有非系统 PiP 降级路径，不改变原有行为。
