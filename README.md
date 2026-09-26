<div align="center">
  <img src="./appicon.png" width="128" alt="InterviewAssistant app icon" />

  # InterviewAssistant

  **本地优先、开源的 macOS / iOS AI 面试准备与辅助工具**

  语音识别 · 实时回答 · 个人知识库 · 截图问答 · 模拟面试 · 本地复盘

  [功能](#功能概览) · [快速开始](#快速开始) · [配置](#配置指南) · [使用](#使用指南) · [隐私](#隐私与数据流) · [开发](#开发说明)
</div>

> [!IMPORTANT]
> 本项目用于面试练习、知识整理，以及在获得许可的场景中提供辅助。使用实时提示、录音、系统音频或屏幕捕获前，请确认符合面试方规则、当地法律和第三方服务条款。请勿用于欺骗、冒充或未经授权的录制。

## 项目简介

InterviewAssistant（应用内显示为 **Interview AI**）是一款使用 SwiftUI 构建的 Apple 平台面试工具。它可以在面试前整理岗位、JD、公司资料和个人经历，在模拟面试中生成问题并给出反馈，也可以在 macOS 上通过悬浮提示板识别语音或截图内容，再结合本地知识库生成回答建议。

本项目没有账户系统，也不依赖项目作者维护的服务器：

- 不需要注册或登录；
- 不使用 Firebase、Google Sign-In、Supabase 或 Cloudflare Worker；
- 历史记录、知识库和设置由 SwiftData / UserDefaults 保存在本机；
- API Key 与语音服务凭证保存在 Apple Keychain；
- AI 请求从设备直接发送到你选择的模型服务商；
- 使用 Ollama + Apple 本地语音识别时，可以组成不依赖云端账户的本地工作流。

> [!NOTE]
> “本地优先”不等于所有模式都完全离线。选择 OpenAI、Claude、DeepSeek、Gemini、火山方舟或豆包语音时，完成请求所需的数据会直接发送给对应服务商。要尽量离线，请选择 Ollama 和 Apple 本地语音识别。

## 功能概览

### 面试准备

- 填写目标岗位和 Job Description；
- 整理公司名称、官网和补充备注；
- 通过所选模型生成公司调研摘要；
- 为每场面试选择不同的本地知识库；
- 选择回答模型和面试语言；
- 自动保留最近一次工作区草稿。

### macOS 实时提示板

- 独立悬浮窗口显示转写结果和回答建议；
- 支持麦克风与系统音频输入；
- 支持 Apple 本地语音识别和豆包流式语音识别；
- 支持模型流式输出；
- 支持隐藏 Dock 图标；
- 可将提示板排除在部分截图或屏幕共享画面之外；
- 支持中英文界面以及浅色 / 深色主题。

### 截图问答

- 预先设置固定截图区域，面试中快速捕获；
- 也可以每次手动框选区域；
- 默认快捷键为 `⌘ Command + ⇧ Shift + S`；
- 支持连续截取多个片段后统一分析；
- 截图和回答可保存在本地历史记录中。

### 本地知识库

- 创建多个知识库并按面试选择启用；
- 手动新增、编辑和停用知识条目；
- 导入 PDF、TXT、Markdown、RTF、HTML、JSON、DOC、DOCX；
- 导入公开网页或 GitHub 链接；
- 本地保存并预览导入的 PDF；
- 将相关知识作为回答上下文直接发送给你配置的模型。

### 模拟面试与复盘

- 根据岗位、JD、公司资料和知识库生成题目；
- 每次可选择 3–10 道题；
- 支持中文、英文或跟随应用语言；
- 录音回答并获得评分、反馈和建议答案；
- 汇总优势、改进方向和整体评价；
- 导出模拟面试评估 PDF；
- 正式面试与模拟面试记录统一保存在本机。

## 技术栈

| 模块 | 技术 |
| --- | --- |
| 客户端 | Swift 6、SwiftUI、SwiftData |
| macOS 音频 | AVFoundation、ScreenCaptureKit |
| 本地语音 | Apple Speech Framework |
| 可选云端语音 | 豆包 / 火山引擎流式 ASR WebSocket |
| 本地凭证 | Apple Keychain |
| 文档处理 | PDFKit、系统文档导入能力 |
| 本地模型 | Ollama（OpenAI-compatible API） |
| 外部模型 | OpenAI、Claude、DeepSeek、Gemini、火山方舟 |

## 系统要求

- macOS 14.0 或更高版本；或 iOS / iPadOS 17.0 或更高版本；
- Xcode 16 或兼容 Swift 6 的更高版本；
- macOS 完整功能需要麦克风、语音识别以及屏幕与系统音频录制权限；
- 使用 Ollama 时，需要本机安装 Ollama 和至少一个模型；
- 使用外部模型或豆包语音时，需要对应服务商的凭证和网络连接。

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/<YOUR_GITHUB_USERNAME>/<YOUR_REPOSITORY>.git
cd <YOUR_REPOSITORY>
```

发布前请将上面的占位地址替换为你的真实仓库地址。

### 2. 打开工程

```bash
open InterviewAssistant.xcodeproj
```

项目已经移除第三方登录 SDK，正常情况下不需要下载 Firebase 或 Google Sign-In 依赖。

### 3. 配置签名

在 Xcode 中选择：

1. `InterviewAssistant` Project；
2. `InterviewAssistant` Target；
3. `Signing & Capabilities`；
4. 选择你自己的 Development Team；
5. 将 `com.example.interviewassistant` 改成你控制的唯一 Bundle Identifier。

仅在自己的 Mac 上调试时，可以使用 Personal Team。

### 4. 选择平台并运行

- macOS：选择 `My Mac`，支持悬浮提示板、系统音频和截图；
- iOS / iPadOS：选择模拟器或真机，适合管理知识库、模拟面试和查看历史；
- 在 Xcode 中选择 `InterviewAssistant` Scheme，按 `⌘R`。

### 5. 配置模型

第一次启动后进入 **设置 → API 配置**。如果希望完全本地运行，建议先配置 Ollama；如果使用外部服务，则填写自己的 API Key。

## 配置指南

### 方案 A：Ollama 本地模型

macOS 默认地址：

```text
http://localhost:11434/v1
```

示例安装和启动方式：

```bash
ollama pull qwen2.5:7b
ollama serve
```

然后在应用中：

1. 服务商选择 **Ollama**；
2. API URL 填写 `http://localhost:11434/v1`；
3. 模型填写已经下载的模型名，例如 `qwen2.5:7b`；
4. API Key 留空；
5. 点击 **测试连接**；
6. 保存配置。

iPhone 或 iPad 连接 Mac 上的 Ollama 时，两台设备需要位于同一可信局域网，并使用 Mac 的局域网 IP，例如：

```text
http://192.168.1.10:11434/v1
```

Ollama 需要监听局域网地址：

```bash
OLLAMA_HOST=0.0.0.0 ollama serve
```

仅应在可信网络中开放该端口，并根据需要配置防火墙。

### 方案 B：直连外部模型

| 服务商 | 默认 API 地址 | 示例模型 | API Key |
| --- | --- | --- | --- |
| DeepSeek | `https://api.deepseek.com` | `deepseek-flash` | 必需 |
| OpenAI | `https://api.openai.com/v1` | `gpt-4.1-mini` | 必需 |
| Claude | `https://api.anthropic.com/v1/messages` | `claude-sonnet-4-5` | 必需 |
| Gemini | `https://generativelanguage.googleapis.com/v1beta` | `gemini-2.0-flash` | 必需 |
| 火山方舟 | `https://ark.cn-beijing.volces.com/api/v3` | 以控制台 Endpoint 为准 | 必需 |

配置步骤：

1. 选择服务商；
2. 确认 API URL；
3. 输入真实可用的模型名称；
4. 填写 API Key；
5. 点击 **测试连接**；
6. 测试成功后保存。

API Key 只写入 Apple Keychain，不应硬编码到源码或提交到 Git。

### Apple 本地语音识别

在 **设置 → API 配置 → 语音识别** 中选择 **Apple 本地语音识别**。

优点：

- 不需要第三方语音 API；
- 配置简单；
- 可减少音频离开设备的情况。

识别语言和离线可用性取决于操作系统版本、地区和本机已经安装的语音资源。

### 豆包语音识别（可选）

如果本地识别效果不能满足需求，可以直接连接豆包语音服务：

1. 在火山引擎 / 豆包语音控制台创建自己的应用；
2. 开通流式语音识别；
3. 复制 `App ID` 和 `Access Token`；
4. 在应用中选择 **豆包语音识别 2.0**；
5. 填写凭证和资源 ID；
6. 测试连接后保存。

常见资源 ID：

```text
volc.seedasr.sauc.duration
volc.seedasr.sauc.concurrent
```

实际值和计费方式以你自己的服务商控制台为准。音频会从设备直接发送到该服务商，不经过本项目作者的服务器。

### macOS 权限

| 权限 | 用途 | 系统设置位置 |
| --- | --- | --- |
| 麦克风 | 获取语音输入 | 隐私与安全性 → 麦克风 |
| 语音识别 | 使用 Apple Speech | 隐私与安全性 → 语音识别 |
| 屏幕与系统音频录制 | 捕获系统音频和截图 | 隐私与安全性 → 屏幕与系统音频录制 |
| 本地网络 | 连接局域网设备或 Ollama | 隐私与安全性 → 本地网络 |

授权后如果功能仍无响应，请完全退出应用再打开。改变签名或 Bundle Identifier 后，macOS 可能要求重新授权。

## 使用指南

### 开始正式面试

1. 在首页填写目标岗位；
2. 粘贴 Job Description；
3. 可选：填写公司名称、官网和备注；
4. 检查模型生成的公司摘要，不要把未经核实的内容当作事实；
5. 选择本场启用的知识库；
6. 确认模型；
7. 点击 **开始面试**；
8. 在悬浮提示板中选择麦克风、系统音频或静音；
9. 结束后在 **历史记录** 中查看本地记录。

### 使用悬浮提示板

提示板有三种音频状态：

- **麦克风**：识别麦克风输入；
- **系统音频**：识别会议软件、浏览器或其他应用播放的声音；
- **静音**：停止语音识别，仍可使用截图问答。

“屏幕共享时隐藏提示板”依赖 macOS 的窗口捕获行为，并不保证在所有录屏软件和系统版本中都不可见。正式使用前请自行测试。

### 使用截图问答

预设区域模式：

1. 打开 **设置 → 截图模式**；
2. 选择 **预设区域截图**；
3. 在面试前设置区域；
4. 按 `⌘⇧S` 或点击截图按钮；
5. 可继续截取其他区域；
6. 完成后统一分析。

手动框选模式会在每次截图时重新选择区域，适合布局经常变化的页面。如果快捷键冲突，可以在设置中重新录制。

### 管理本地知识库

1. 进入 **知识库**；
2. 创建“个人项目”“产品案例”“算法题”等知识库；
3. 手动新增条目，或上传文件 / 导入链接；
4. 检查提取文本是否准确；
5. 为当前面试启用需要的知识库；
6. 关闭暂时不希望参与回答的条目。

建议每个项目至少包含：背景、目标、你的职责、关键行动、取舍、结果、失败与反思。不要写入你无权发送给外部模型的机密信息。

### 进行模拟面试

1. 填写岗位与 JD；
2. 选择知识库和模型；
3. 点击 **模拟面试**；
4. 选择 3–10 道题和回答语言；
5. 逐题录音并提交回答；
6. 查看评分、反馈与建议答案；
7. 完成后查看整体总结；
8. 如有需要，导出评估 PDF。

## 隐私与数据流

| 数据 | 存储位置 | 什么时候离开设备 |
| --- | --- | --- |
| API Key、ASR 凭证 | Apple Keychain | 连接对应服务商时用于鉴权 |
| 知识库、历史记录 | 本机 SwiftData | 作为相关上下文发送给所选外部模型时 |
| 界面设置 | UserDefaults | 不主动上传 |
| 导入的 PDF | 应用本地容器 | 相关内容参与外部模型请求时 |
| 麦克风 / 系统音频 | 识别流程内存 | 仅使用外部 ASR 时发送给该服务商 |
| 截图 | 本地历史记录 | 作为问题内容发送给外部模型时 |

项目不提供账户、云同步、积分系统或自建 API 网关。没有任何数据会发送到 InterviewAssistant 项目维护者的服务器。

## 项目结构

```text
.
├── InterviewAssistant/
│   ├── History/                  # 本地历史记录
│   ├── KnowledgeBase/            # 本地知识库、文档导入和 PDF 预览
│   ├── MockInterview/            # 模拟面试、评分和 PDF 导出
│   ├── Receiver/                 # 悬浮提示板、音频、ASR 和截图
│   ├── Resources/                # Info.plist、权限和 Assets
│   ├── Sender/                   # 局域网提示发送实验模块
│   ├── Settings/                 # 外观、快捷键和 API 配置
│   ├── Shared/                   # 模型、Keychain、网络和通用服务
│   └── Setup/                    # 面试准备工作流
├── InterviewAssistant.xcodeproj/ # Xcode 工程
├── scripts/build-dmg.sh          # macOS DMG 构建脚本
├── DESIGN_SYSTEM.md              # UI 设计规范
├── LICENSE                       # MIT License
└── README.md
```

## 构建 macOS DMG

```bash
./scripts/build-dmg.sh
```

输出位于 `dist/`。公开分发前还需要：

1. 使用自己的 Developer ID Application 证书签名；
2. 使用 Apple Developer 账号完成 notarization；
3. staple 公证票据；
4. 在一台没有开发环境的 Mac 上验证安装和首次授权；
5. 确认 Release 构建中没有个人证书、API Key 或本地数据。

## 常见问题

### API Key 不存在

- 重新进入 API 配置页填写并保存；
- 检查服务商是否和 Key 对应；
- Bundle Identifier 或签名改变后，Keychain 访问组可能变化，需要重新保存；
- Ollama 不需要 API Key，但需要本地服务正在运行。

### Ollama 无法连接

- 执行 `ollama list` 确认模型存在；
- 执行 `ollama serve` 启动服务；
- macOS 使用 `http://localhost:11434/v1`；
- iOS 使用 Mac 的局域网 IP，不能使用 iPhone 自己的 `localhost`；
- 检查 macOS 防火墙和本地网络权限。

### 系统音频无法识别

- 授予“屏幕与系统音频录制”权限；
- 完全退出并重新打开应用；
- 确认提示板处于“系统音频”状态；
- 确认目标应用正在播放声音；
- Debug 与 Release 可能需要分别授权。

### Apple 语音识别不可用

- 授予麦克风和语音识别权限；
- 检查所选语言是否受系统支持；
- 下载相应系统语音资源；
- 确认音频输入设备工作正常。

### 截图快捷键无响应

- 检查是否与其他应用快捷键冲突；
- 在设置中重新录制快捷键；
- 授予屏幕录制权限；
- 使用预设模式时先保存区域；
- 尝试切换到手动框选模式。

### 公司官网解析失败

- 确认网址包含 `https://`；
- 某些网站会阻止抓取或依赖客户端渲染；
- 检查所选模型的连接状态；
- 无法自动解析时，将可信资料手动填写到公司备注。

## 开发说明

- 保持本地优先，新增外部请求时明确记录数据流；
- 不要在源码中提交 API Key、Token、证书或个人数据库；
- 新增模型服务商时，将 URL、鉴权和响应解析集中在 `AIService.swift`；
- 修改 SwiftData 模型时设计迁移方案；
- 修改权限时同步更新 `Info.plist`、entitlements 和 README；
- 提交前至少验证 macOS 与 iOS 构建；
- `.gitignore` 已排除数据库、凭证、Xcode 用户数据和构建产物。

## 贡献

欢迎提交 Issue 和 Pull Request：

1. Fork 仓库；
2. 创建功能分支；
3. 完成修改和测试；
4. 确认提交中没有个人信息或凭证；
5. 在 Pull Request 中说明背景、实现方式和验证结果。

```bash
git checkout -b feature/your-feature
git commit -m "feat: describe your change"
git push origin feature/your-feature
```

## 安全问题

如果发现凭证泄露、隐私数据暴露或其他安全问题，请不要在公开 Issue 中粘贴敏感内容。可以先创建一条不含敏感细节的安全报告，并通过仓库维护者公开提供的安全联系渠道继续沟通。

## 开源许可证

本项目使用 [MIT License](./LICENSE)。你可以使用、复制、修改和分发代码，但软件按“原样”提供，不附带任何形式的担保。

---

如果这个项目对你有帮助，欢迎 Star、提交反馈或贡献更好的本地面试工作流。
