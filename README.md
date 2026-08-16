<div align="center">

[English](./README.en.md) | **简体中文**

</div>

<h1 align="center">MacBook Dock Brightness</h1>

<p align="center">
  <b>连接指定外接显示器时自动熄暗 MacBook 内屏，断开后恢复亮度与自动亮度</b><br>
  <i>A tiny, source-only macOS display policy for open-lid desk setups.</i>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-v0.1.0-blue" alt="Version">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey" alt="Platform">
  <img src="https://img.shields.io/badge/distribution-source--only-purple" alt="Source only">
</p>

## 它解决什么问题

你希望 MacBook 保持开盖，以便继续使用原装键盘、触控板、Touch ID、摄像头和扬声器，但桌面上只看外接大屏。

MacBook Dock Brightness 会在**你明确选择并确认的外接显示器**在线、活动且与内屏处于镜像模式时：

- 关闭 MacBook 内屏的自动亮度；
- 将内屏硬件亮度设为 `0%`；
- 在显示器断开、服务正常停止或卸载时，尝试将内屏恢复到配置亮度并重新开启自动亮度。

它不会按“任意外接屏”触发。安装时必须从只读列表中明确选择目标；请确认选择的不是 AirPlay 或虚拟显示器。长期匹配使用 vendor/model，也可选择加入序列号。

## 重要边界

这个工具把内屏背光降到零，但**不会真正断开内屏**。内屏仍存在于 macOS 显示拓扑中，因此：

- 使用前必须在“系统设置 → 显示器”中设置镜像；扩展模式下程序会拒绝熄暗内屏。
- 不应宣称它释放 framebuffer、降低 GPU 负载或提升性能。
- 它使用 Apple 未公开的 CoreBrightness/DisplayServices 接口。系统升级可能让接口失效；进入暗态前遇到不支持、歧义或验证失败的状态时，程序会拒绝调暗。若已经处于暗态后恢复接口失效，请使用下方亮度键或 `--restore` 路径。

目前完成实机验证的环境是 **M5 MacBook Air、macOS 27.0 beta（build 26A5406e）、LG 4K USB-C 显示器**。其他 Mac 和系统版本可以尝试从源码编译，但尚未验证或保证兼容。

## 安装

要求：

- MacBook 和一个已连接的物理外接显示器；
- 已将两个屏幕设置为镜像；
- Xcode Command Line Tools：`xcode-select --install`；
- 使用普通登录用户运行，不要使用 `sudo`。

```bash
git clone https://github.com/jiadizhunine/macbook-dock-brightness.git
cd macbook-dock-brightness
make check
./build/macbook-dock-brightness --list-displays
./scripts/install.sh --target-display-id 3 --undocked-brightness 0.32
```

安装器会在本机编译源码，而且不会自动猜测目标显示器。请把示例中的 `3` 换成列表里已经与内屏镜像的目标 ID。

启动后，安装器还会确认 LaunchAgent 持续运行且状态读回正常；新安装或升级若未通过健康检查，会先停止新服务、恢复内屏，再回滚到先前文件与服务状态。

`--target-display-id` 只用于安装时读取显示器身份，不会把易变的 CoreGraphics ID 当作长期标识。若同型号显示器不止一台且显示器报告非零 serial，可增加 `--match-serial`。

安装内容：

| 路径 | 用途 |
| --- | --- |
| `~/Library/Application Support/MacBookDockBrightness/` | 本机编译的程序、配置和恢复状态 |
| `~/Library/LaunchAgents/io.github.jiadizhunine.macbook-dock-brightness.plist` | 登录后自动运行 |
| `~/Library/Logs/MacBookDockBrightness*.log` | 低频事件与错误日志 |

## 使用和检查

列出显示器：

```bash
./build/macbook-dock-brightness --list-displays
```

查看当前目标、镜像关系、亮度和自动亮度：

```bash
"$HOME/Library/Application Support/MacBookDockBrightness/macbook-dock-brightness" --status
```

只预览下一步动作，不修改设置：

```bash
"$HOME/Library/Application Support/MacBookDockBrightness/macbook-dock-brightness" --dry-run
```

配置文件是：

```text
~/Library/Application Support/MacBookDockBrightness/config.json
```

默认策略为接入时 `0% + 自动亮度关闭`，断开时 `32% + 自动亮度开启`。状态已经验证成功且没有新显示器或唤醒事件时，watchdog 每两秒只枚举一次在线显示器，不会反复写入亮度。

## 卸载与紧急恢复

在仓库目录运行：

```bash
./scripts/uninstall.sh
```

卸载器会先停止后台服务并验证内屏恢复，再删除程序和配置。日志默认保留；需要同时删除日志时使用：

```bash
./scripts/uninstall.sh --purge-logs
```

如果内屏意外保持黑暗，可以直接按 MacBook 的亮度增加键，或依次运行：

```bash
MDB_SERVICE_TARGET="gui/$(id -u)/io.github.jiadizhunine.macbook-dock-brightness"
launchctl bootout "$MDB_SERVICE_TARGET" 2>/dev/null || true
if launchctl print "$MDB_SERVICE_TARGET" >/dev/null 2>&1; then
  echo "后台服务仍在运行；请勿删除恢复文件。"
else
  "$HOME/Library/Application Support/MacBookDockBrightness/macbook-dock-brightness" --restore
fi
```

不要为此关闭 Gatekeeper，也不要执行来历不明的 `xattr` 命令。

如果配置文件损坏或丢失，`--restore` 会使用安全回退值：内屏亮度 `32%`，并开启自动亮度。

## 交给 AI 安装

可以把下面这段话交给本地编码 Agent：

> 请先完整阅读 `README.md` 和 `AGENTS.md`，运行 `make check`，再只读执行 `./build/macbook-dock-brightness --list-displays`。把准备匹配的外接显示器、是否镜像以及恢复亮度展示给我确认；确认后运行安装脚本。不要使用 sudo、不要关闭 Gatekeeper，也不要安装预编译二进制。

## 实现方式

- Objective-C + ARC，依赖系统自带的 AppKit、CoreGraphics 和 Foundation。
- CoreGraphics 事件、AppKit 屏幕变化通知和唤醒通知负责主要触发。
- 两秒 watchdog 只在事件遗漏时补充检查，并带失败退避。
- 亮度与自动亮度写入后都会立即读回验证。
- 归零之前保存 managed recovery state；显示器断开、SIGTERM、SIGINT 和卸载都会走恢复路径。
- LaunchAgent 只在登录时启动，不设置 `KeepAlive`；若系统更新导致私有接口崩溃，进程不会循环重启。
- 完全在本机运行，无网络、无遥测，不需要管理员、辅助功能、屏幕录制或输入监控权限。

## 源码发布说明

GitHub Release 只包含源码，不附带编译好的可执行文件。每位用户在自己的 Mac 上审阅并编译，因此不需要下载未公证的第三方二进制，也不需要绕过 Gatekeeper。

CI 只能验证编译、静态分析、配置、脚本和无副作用的 CLI；真正的显示器热插拔、睡眠唤醒及私有 API 行为仍需要实体 MacBook 测试。

## 相关项目

- [OpenClamshell](https://github.com/strohsnow/OpenClamshell)：镜像并调暗内屏。
- [clamOpen](https://github.com/Attiv/clamOpen)：通过私有 CoreGraphics 接口软关闭内屏。
- [ExternalDisplayOnly](https://github.com/ilyasaftr/ExternalDisplayOnly)：自动软断开和恢复内屏。

本项目采用独立实现，专注于“指定显示器 + 自动亮度状态恢复 + 保留镜像拓扑”。

## 许可证

[MIT](./LICENSE)。本项目不是 Apple 或 LG 的官方产品，也未获得其认可。
