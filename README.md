# WindowSnap V1

WindowSnap 是一款原生 macOS 菜单栏窗口管理工具，面向超宽屏和多窗口工作流。V1 的重点是通过菜单栏可视化面板或按住 `Option` 拖动，把窗口放入 5、6、7、8 列中的指定位置。

当前正式版本：`1.1.0`

## 主要功能

- 4～8 列超宽屏纵向布局，默认 6 列
- 菜单栏显示当前列数，并提供可视化位置选择
- 按住 `Option` 拖动窗口时显示精确分区浮层
- 单次操作内部自动重试，兼容 ChatGPT、豆包工作和 Chromium/Electron 应用的异步缩放
- 检测应用真实最小宽度，并推荐可用的最大列数
- 检测已排列窗口离开当前桌面空间
- 半屏、四角、三分屏、最大化、居中和恢复
- 多显示器移动
- 可自定义的全局快捷键
- 可选登录时启动

## 使用条件

- macOS 13 或更高版本
- 必须授予 WindowSnap“设备控制与数据访问”权限；较早版本的 macOS 中显示为“辅助功能”权限
- 使用 `Option` 拖动前，建议在“系统设置 → 桌面与程序坞 → 窗口”中关闭 macOS 自带的“按住 ⌥ 键拖移窗口以进行拼贴”
- 使用 4～8 列排列时，相关窗口应位于同一个 macOS 桌面空间
- 某些应用有不可突破的最小窗口宽度；WindowSnap 会重试并在确认失败后提示

## 安装

1. 从 GitHub Releases 下载最新版 `WindowSnap-1.1.0.zip`。
2. 解压后将 `WindowSnap.app` 移到“应用程序”。
3. 首次打开时，根据提示授予设备控制权限。
4. 如果权限已经开启但应用仍无法移动窗口，请关闭该开关、重新开启，然后重启 WindowSnap。

本项目的本地安装包使用临时签名，未经过 Apple 公证。macOS 阻止首次启动时，可在 Finder 中按住 Control 点击应用并选择“打开”。面向其他用户正式分发时，应使用 Developer ID 签名并完成 Apple 公证。

## 基本使用

### 菜单栏面板

1. 先点击需要移动的窗口。
2. 点击菜单栏中的 WindowSnap 图标。
3. 选择 5、6、7 或 8 列。
4. 点击编号，将窗口放入对应列。

### Option 拖动

1. 按住 `Option`。
2. 从窗口顶部标题栏开始拖动。
3. 将指针移入目标列。
4. 松开鼠标，WindowSnap 会在同一次操作中持续调整窗口，直到到达目标位置或确认该应用拒绝目标宽度。

完整操作说明见 [docs/USAGE.md](docs/USAGE.md)，常见问题见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

## 默认快捷键

所有默认快捷键以 `⌃⌥` 开头：

- 方向键：左右、上下半屏
- `U / I / J / K`：四角
- `1 / 2 / 3`：三分屏
- `M`：最大化
- `C`：居中
- `R`：恢复原尺寸
- `N / P`：下一台或上一台显示器

4～8 列布局使用菜单栏面板或 `Option` 拖动，不占用大量全局快捷键。

## 从源码构建

需要 Swift 6、Xcode Command Line Tools 和 macOS 13 SDK 或更高版本。

```bash
./run-tests.sh
./build-app.sh
open dist/WindowSnap.app
```

如已有 Developer ID 证书：

```bash
WINDOWSNAP_SIGNING_IDENTITY="Developer ID Application: ..." ./build-app.sh
```

未指定证书时，构建脚本使用临时签名。详细开发说明见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## 项目结构

```text
Sources/WindowSnap/       应用源码
Resources/Info.plist      应用元数据与版本号
Tests/                    布局及重试策略测试
docs/                     使用、架构和故障排查文档
build-app.sh              Release 构建与打包
run-tests.sh              本地测试入口
```

## 隐私

WindowSnap 不包含网络请求、遥测或用户数据上传。设备控制权限仅用于读取当前窗口边界以及移动、缩放窗口。

## 已知限制

- macOS 没有公开接口允许普通应用可靠地把窗口从其他桌面空间强行搬到当前空间；WindowSnap 只能检测并提示。
- 全屏窗口、系统模态窗口和禁止调整大小的窗口可能无法排列。
- 不同应用的最小宽度不同，7～8 列不一定适用于所有窗口。

## 版本

V1 对应 `1.x` 系列。版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

本仓库暂未附加开源许可证。代码公开可见不代表自动授予复制、修改或再分发权利。
