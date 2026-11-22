# X6遥控 · X6 Remote

用 X6 USB 遥控器控制 Mac。卡片式映射界面，中间点击遥控器按键，右侧配置单击、双击、长按、快捷键或应用动作。

这是基于 [SayAll / remote-mic-app](https://github.com/HD838A/remote-mic-app) 公开代码修改的独立社区版本，不是 SayAll 官方发行版。软件代码沿用 **GPL-3.0-only**，保留原作者和第三方归属。

## 支持范围

- 当前已验证：Apple 芯片 Mac，macOS 14 或以上。
- 当前接收器匹配：USB Vendor ID `0x1915`、Product ID `0x1025`。同名 X6 可能使用其他接收器，不保证全部兼容。
- Intel Mac 和 Windows 尚未在本项目验证；没有提供 Windows 安装包。
- 该入口不启动 SayAll 的常规蓝牙、自动更新和主应用流程。仓库保留用于构建和遵守许可证所需的公共基础代码，不表示原项目全部功能都已在 X6 界面开放。

## 安装与授权

在 [GitHub Releases](https://github.com/demok0913-ai/x6-remote/releases) 下载 `X6Remote-1.1.1-macOS-arm64.dmg`，打开后将 **X6遥控** 拖到 **Applications / 应用程序**。也可以下载 ZIP，解压后把 `X6遥控.app` 移入“应用程序”。无需编译，不需要安装 Xcode。避免从多个临时副本运行。

首个公开安装包标为预发布版：已在维护者的 Mac 上验证界面及左右键，尚未完成另一台 Mac 的全新安装实测。安装包使用本地 ad-hoc 签名，尚未获得 Apple 公证。

1. 接入 X6 USB 接收器。
2. 在 macOS“系统设置 → 隐私与安全性”中，为 **X6遥控** 开启“输入监控”和“辅助功能”。系统验证由电脑所有者本人完成。
3. 按系统提示退出并重新打开 App，点击“开启映射”。
4. 首次安装不会携带作者电脑的映射、应用路径或权限；请自行配置。

本地构建使用 ad-hoc 签名，没有 Apple Developer ID 签名或公证。首次打开可能出现系统安全提示；请核对源码和来源后遵循 macOS 的正常提示。不要关闭整个系统的安全保护。重新构建替换二进制后，macOS 可能要求重新授权；这不是永久免授权安装包。

## 设置映射

1. 点击中间遥控器上的按键，或从右侧配置位置列表选择按键。
2. 如果显示“未录入”，点“录入实体按键”，再按下并松开对应的遥控器实体键。
3. 选择单击、双击或长按，再选择基础按键、快捷键、应用或系统媒体功能。
4. “快捷键配置…”支持常用组合和标准键盘；“应用配置…”用于选择本机应用。
5. 核对右侧摘要，点击“保存并启用映射”。编辑时会暂停映射，保存或点“开启映射”后恢复。

切换桌面的示例：将左键的单击设为 `Control + Left`，右键的单击设为 `Control + Right`。这依赖 macOS 已启用对应的 Mission Control 键盘快捷键，并有可切换的桌面。

图上的按键覆盖目前不是整只遥控器的全部功能。没有独立点击区域的实体键，可以通过“新增实体按键”和配置位置列表录入；配置位置数量有限，不代表背面键盘的每个键都能单独映射。

## 从源码构建

需要 macOS、Apple Command Line Tools / Xcode（Swift 6.2 或更新版本）和 Python 3。首次构建需要联网下载公开的 Sparkle 依赖，不需要任何 SayAll 私有组件或 API Key。

```sh
git clone https://github.com/demok0913-ai/x6-remote.git
cd x6-remote
python3 scripts/build-app.py
```

产物在 `dist/X6遥控.app`。脚本只构建和打包，不安装、不启动 App，也不修改现有权限或映射。

```sh
# 可选：直接运行原项目测试。需要工具链提供 Swift Testing 模块。
SAYALL_PRIVATE_PLATFORM_MODE=public xcrun swift test --disable-keychain
```

当前界面和实体左右键已在维护者的一台 Apple 芯片 Mac 上验证。尚未完成另一台 Mac 的全新安装验证；不能把本机实测当作所有设备的兼容性保证。原项目测试在当前本机工具链中遇到 `no such module 'Testing'`，不声称完整测试套件已通过。

## 来源、修改与资源

- 基于 SayAll 公开源码快照，原始来源树标识：`85a9148ef751fb0ba962ceda9ea584c54f56331a`。这是继承的快照标识，不声称是上游当前主线。
- 本版本修改包括 X6 独立入口、中文命名与图标、卡片映射界面、快捷键/应用配置入口及保存流程修复。整理公开源码日期：2026-11-22。
- 保留原有 Bundle ID `com.hd838a.RemoteMic.X6Preview`，用于兼容已有本机配置；本项目不是原厂或上游官方产品。
- 软件许可证：[LICENSE.md](LICENSE.md)。原始声明：[COPYRIGHT.md](COPYRIGHT.md)；第三方信息：[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 没有收录上游专有 App Logo；本项目使用 AI 辅助生成的 X6 图标和遥控器示意素材。素材说明见 [ASSETS.md](ASSETS.md)。
- 仓库不包含作者本机映射、日志、偏好设置、凭据、证书或私有平台二进制。

反馈问题时请提供 macOS 版本、Mac 芯片类型、接收器 VID/PID、复现步骤和界面状态；不要上传密码或个人日志。
