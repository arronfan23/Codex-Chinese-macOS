# Codex Chinese for macOS

[![Release](https://img.shields.io/github/v/release/arronfan23/Codex-Chinese-macOS?include_prereleases&logo=github)](https://github.com/arronfan23/Codex-Chinese-macOS/releases)
[![Build DMG](https://github.com/arronfan23/Codex-Chinese-macOS/actions/workflows/release.yml/badge.svg)](https://github.com/arronfan23/Codex-Chinese-macOS/actions/workflows/release.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](#系统要求)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**简体中文**

为 macOS 版 Codex 桌面应用（ChatGPT.app / Codex.app）启用**简体中文界面**的一键式工具，并提供中文版的启动 / 重启入口。

![icon](assets/icon.png)

> 官方安装包内本就自带完整的简体中文资源（菜单、界面文案），只是被功能开关锁在英文。
> 本工具通过本地补丁"解锁"这些官方资源——**不是翻译，而是开关**。

- **完全离线**：全过程不联网、不上传任何数据
- **不动原版**：不修改"应用程序"里的官方 App，而是生成独立副本 `~/Applications/Codex 中文版.app`，两者并存
- **可随时卸载**：副本移入废纸篓即可，不留残余；聊天记录与登录状态不受任何影响（数据与原版共用）
- **Apple 芯片 / Intel 芯片通用**：工具本身是纯脚本，副本架构自动跟随你机器上的官方原版

## 下载安装

从 [**Releases**](https://github.com/arronfan23/Codex-Chinese-macOS/releases) 下载 `Codex中文启动器.dmg`：

1. 打开 DMG，将 **Codex中文启动器.app** 拖入"应用程序"文件夹
2. 双击运行，点主按钮 **〔汉化并启动〕**（约 1-2 分钟，离线完成，进度条可见）
3. 完成后自动打开 **Codex 中文版**，界面即为简体中文

> **首次打开提示"无法验证 / 已损坏"？** 这是因为副本使用本地 ad-hoc 签名（无开发者证书）。
> 处理：访达中**右键点击 App → 打开**；或到 *系统设置 → 隐私与安全性* 点"仍要打开"。只需一次。

## 使用

主按钮会根据当前状态自动切换：

| 状态 | 主按钮 | 行为 |
|---|---|---|
| 未安装 | **汉化并启动** | 打补丁 + 自动启动，带进度条 |
| 已安装 | **启动中文版** | 直接启动 |
| 正在运行 | **重启中文版** | 结束旧实例并重新启动 |

另有〔卸载汉化〕（移入废纸篓）与〔使用说明〕。

### 命令行

```bash
# 检测官方应用与补丁兼容性
/usr/bin/perl codex-zh.pl inspect [--json]

# 安装（自动发现 ChatGPT.app / Codex.app，也可 --app 指定）
/usr/bin/perl codex-zh.pl install [--destination ~/Applications/Codex\ 中文版.app]

# 卸载（校验安装清单与完整性后经 Finder 移入废纸篓）
/usr/bin/perl codex-zh.pl uninstall --app ~/Applications/Codex\ 中文版.app

# 自测（57 项断言，覆盖补丁 / asar 完整性 / Mach-O 处理 / 异常防御）
/usr/bin/perl codex-zh.pl selftest
```

依赖仅为 macOS 系统自带组件：perl（Digest::SHA / JSON::PP）、plutil、codesign、ditto、osascript。

## 工作原理

对官方 App 的**独立副本**做以下处理（原版永不修改）：

1. **解锁语言开关**：在 `app.asar` 内的 JS 中做三处**等长**字节替换
   - `x?.get(\`enable_i18n\`, !1)` → `!0`（打开 i18n 功能开关）
   - 界面/生效语言的消费点 → 替换为 `"zh-CN"` 字面量（空格填充保持等长）
2. **同步完整性链**（等长替换保证 asar 偏移不变，可原位更新）：
   - 重算补丁文件的 SHA256 与 4 MiB 分块哈希，在 asar header 原位更新
   - 同步 `Info.plist` 的 `ElectronAsarIntegrity`
3. **处理厂商定制校验**：OpenAI 定制版将 asar 哈希内嵌于 Codex Framework 的
   `__DATA_CONST,__asar_integrity` 节；本工具清零该节以跳过这项校验（实测清零即跳过）
4. **本地 ad-hoc 重签**：嵌套 bundle 深者先签、**不带 entitlements**
   （原版 entitlements 含需开发者证书的受限条目，ad-hoc 携带会被 AMFI 内核击杀）
5. 清除 quarantine 属性，写安装清单 `codex-zh-install.json`（卸载前校验）

## 系统要求

- macOS 13 (Ventura) 或更高
- Apple 芯片（M 系列）或 Intel 芯片
- 已安装官方 Codex 桌面版（App 名为 ChatGPT.app 或 Codex.app 均可，自动识别）

## 常见问题

<details>
<summary><b>Codex 官方更新后还能用吗？</b></summary>

官方更新可能改变语言相关代码的位置或形态，导致补丁不兼容。请先〔卸载汉化〕，
等待本仓库发布适配版本后再重新安装。原版不受任何影响。
</details>

<details>
<summary><b>装好中文版后，能删掉原来的 ChatGPT.app 吗？</b></summary>

技术上可以（聊天数据存于 <code>~/Library/Application Support/Codex</code>，不在任何 App 里），
但<b>建议保留</b>：官方更新后需要用新版原版重新汉化；原版也是出问题时的现成回退方案。
</details>

<details>
<summary><b>提示"未找到 Codex 桌面版"？</b></summary>

确认已安装官方桌面版（ChatGPT.app 或 Codex.app）。特殊位置可用
<code>--app /实际路径/XX.app</code> 指定，详见上文命令行一节。
</details>

## 从源码构建

```bash
git clone https://github.com/arronfan23/Codex-Chinese-macOS.git
cd Codex-Chinese-macOS
bash build-dmg.sh        # 产物: build/Codex中文启动器.dmg
```

要求：macOS 自带的 osacompile / iconutil / hdiutil，以及 node（生成应用图标）。
推送 `v*` 标签时，GitHub Actions 会自动构建 DMG 并发布到 Releases。

## 相关项目

- **Windows 版**：[arronfan23/Codex-Chinese](https://github.com/arronfan23/Codex-Chinese)

## 免责声明

本项目并非 OpenAI 官方产品，与 OpenAI 无任何关系；"Codex"及相关商标归其权利人所有。
本项目仅供个人学习与研究使用，请遵守当地法律法规及软件许可协议。
使用本项目产生的一切后果由使用者自行承担。

## 许可证

[MIT](LICENSE) © 2026 arronfan23
