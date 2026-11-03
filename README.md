# GamePulse 游戏脉冲

GamePulse 是一款 macOS 菜单栏与 Windows 系统托盘游戏状态组件。它以手机桌面组件风格，将多款二次元游戏的体力恢复进度和每日任务集中在一个面板中。

## 支持的游戏

| 游戏 | 体力 | 每日进度 | 数据来源 |
|---|---|---|---|
| 原神 | 原粹树脂 | 每日委托 | 米游社 |
| 崩坏：星穹铁道 | 开拓力 | 每日训练 | 米游社 |
| 绝区零 | 电量 | 活跃度 | 米游社 |
| 明日方舟 | 理智 | 日常任务 | 森空岛 |
| 鸣潮 | 结晶波片 | 每日活跃、签到 | 库街区 |

当前仅面向以上游戏的中国大陆官服。碧蓝航线数据采集已经从项目目标中移除。

## 主要功能

- 手机中号桌面组件式渐变卡片
- 实时体力、预计回满时间和每日任务进度
- 原神与崩铁共用一个米游社账号，绝区零可使用另一个账号
- 米游社双二维码完整授权
- 森空岛 App 扫码授权
- 库街区手机号与短信验证码登录
- 5、10、15 或 30 分钟自动刷新
- 登录失效提示与重新授权入口
- 可选的自建数据桥

未授权的游戏会显示演示数据，已授权但请求失败的游戏会显示具体错误，不会用演示数据冒充实时数据。

## 下载与安装

请在仓库右侧的 **Releases** 页面下载对应平台成品：

- macOS：`GamePulse-macOS-universal-v1.0.0.zip`
- Windows：`GamePulse-Windows-x64.zip`

macOS 版支持 macOS 14 及更高版本，同时包含 Apple 芯片与 Intel 版本。详细步骤见 [macOS 使用说明](docs/macOS-使用说明.md)。

Windows 版支持 Windows 10 19041 及更高版本，完整解压后运行 `GamePulse.exe`。

## macOS 快速使用

1. 解压并将 `GamePulse.app` 拖入“应用程序”。
2. 首次启动时按住 Control 点击应用，选择“打开”。
3. 点击菜单栏的仪表图标，再点击右上角齿轮。
4. 按提示登录米游社、森空岛和库街区账号。
5. 点击“保存并刷新”。

当前公开包使用临时本地签名，未经过 Apple 公证。请只从本项目 Releases 下载。

## 从源码构建 macOS 版

需要 macOS 14 或更高版本以及 Xcode/Command Line Tools：

```bash
./scripts/package_app.sh
open ./dist/GamePulse.app
```

生成 GitHub Release 压缩包及 SHA-256 校验文件：

```bash
./scripts/package_macos_release.sh
```

也可以在 Xcode 中打开 `Package.swift` 并运行 `GamePulse`。

## 从源码构建 Windows 版

需要 .NET 8 SDK：

```powershell
powershell -ExecutionPolicy Bypass -File .\Windows\package-windows.ps1
```

## 可选数据桥

正常情况下无需配置数据桥，应用会直接访问各游戏官方社区。高级用户可以在设置中填写数据桥地址和 Bearer Token，接口约定见 [bridge-contract.md](docs/bridge-contract.md)。

本地测试桥：

```bash
GAMEPULSE_TOKEN=local-only python3 bridge/server.py
```

随后在应用设置中填写 `http://127.0.0.1:8765` 和 `local-only`。

## 隐私与安全

- 登录凭据仅保存在当前电脑用户的本地存储中。
- 手机号和短信验证码不会保存。
- 日志不会输出 Cookie、Token、手机号或验证码。
- 凭据不会发送给 GPT 或其他云端模型。
- 重新登录必须由用户通过官方扫码、短信验证码或人机验证完成。

## 免责声明

GamePulse 是非官方开源工具，与米哈游、鹰角网络、库洛游戏无隶属或合作关系。官方接口变化可能导致数据暂时不可用，请勿将本项目用于绕过验证码、风控或其他安全机制。
