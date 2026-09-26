<div align="center">
  <img src="./appicon.png" width="128" alt="InterviewAssistant app icon" />

  # InterviewAssistant

  **本地优先、开源的 Apple 平台 AI 面试准备与辅助工具**

  语音识别 · 实时回答 · 个人知识库 · 截图问答 · 模拟面试 · 本地复盘

  [功能](#功能概览) · [快速开始](#快速开始) · [模型配置](#选择-ai-模型) · [使用说明](#使用指南) · [数据与隐私](#数据存储与隐私) · [常见问题](#常见问题)
</div>

> [!IMPORTANT]
> 本项目适合面试练习、知识整理，以及在获得许可的场景中提供辅助。使用实时提示、录音、系统音频或屏幕捕获前，请确认符合面试方规则、当地法律和第三方服务条款。请勿用于欺骗、冒充或未经授权的录制。

## 项目简介

InterviewAssistant（应用内显示为 **Interview AI**）使用 SwiftUI 构建，支持 macOS。它可以帮助用户：

- 在面试前整理岗位、JD、公司资料和个人经历；
- 建立多个个人知识库，并决定本场面试允许 AI 使用哪些资料；
- 在 macOS 上通过悬浮提示板识别语音、分析截图并生成回答建议；
- 进行模拟面试，获得逐题反馈、建议答案和整体评价；
- 在本机查看正式面试与模拟面试的历史记录。

AI 请求由应用直接发送到用户自己选择的模型服务商。

> [!NOTE]
> “本地优先”不代表所有组合都完全离线。使用 OpenAI、Claude、DeepSeek、Gemini、火山方舟或豆包语音时，请求所需的文本、知识库上下文、截图或音频会直接发送给对应服务商。若希望尽量减少数据离开设备，请使用 **Ollama + Apple 本地语音识别**。

## 界面预览

### 面试准备主页

填写目标岗位、Job Description 和公司资料，并为本场面试选择知识库。

<p align="center">
  <img src="./presentation%20img/index.png" width="920" alt="InterviewAssistant 面试准备主页" />
</p>

### macOS 实时提示板

悬浮提示板可以显示识别到的问题、AI 回答和截图分析结果。

<p align="center">
  <img src="./presentation%20img/hint%20board.png" width="920" alt="InterviewAssistant 实时提示板" />
</p>

提示板可以收起，减少对屏幕内容的遮挡。

<p align="center">
  <img src="./presentation%20img/minimise%20board.png" width="920" alt="InterviewAssistant 最小化提示板" />
</p>

## 功能概览

### 面试准备

- 填写目标岗位和 Job Description；
- 记录公司名称、官网与公司备注；
- 使用当前配置的模型生成公司调研摘要；
- 为本次面试启用一个或多个知识库；
- 自动保留最近一次填写的工作区草稿；
- 从同一入口开始正式面试或模拟面试。

### macOS 实时提示板

- 使用独立悬浮窗口显示转写结果和回答建议；
- 支持麦克风与系统音频输入；
- 支持 Apple 本地语音识别和豆包流式语音识别；
- 支持 AI 回答流式输出；
- 支持展开、收起、置顶和调整字号；
- 可尝试在截图或屏幕共享时隐藏提示板；
- 支持中文、英文以及浅色、深色主题。

### 截图问答

- 可在面试前设置固定截图区域；
- 也可以在每次截图时手动框选区域；
- macOS 默认快捷键为 `⌘ Command + ⇧ Shift + S`；
- 支持连续截取多个区域后统一分析；
- 截图、问题和回答可以保存在本地历史记录中。

### 本地知识库

- 创建多个独立知识库；
- 手动新增、编辑、启用或停用知识条目；
- 支持导入 PDF、TXT、Markdown、RTF、HTML、JSON、DOC 和 DOCX；
- 支持导入公开网页或 GitHub 链接；
- 支持查看导入资料的提取内容；
- 可为不同面试启用不同的知识库；
- 没有知识库时，详情区保持为空，点击“新建资料”后才进入编辑状态。

### 模拟面试与复盘

- 根据岗位、JD、公司资料和知识库生成问题；
- 每场可选择 3–10 道题；
- 支持中文、英文或跟随应用语言；
- 逐题录音并提交回答；
- 获得评分、反馈与建议答案；
- 汇总优势、改进方向和整体评价；
- 支持导出模拟面试评估 PDF；
- 正式面试与模拟面试记录统一显示在历史页面。

## 平台功能差异

| 功能 | macOS | iOS / iPadOS |
| --- | :---: | :---: |
| 面试准备、知识库、历史记录 | ✅ | ✅ |
| 模拟面试 | ✅ | ✅ |
| AI 模型配置 | ✅ | ✅ |
| Apple 语音识别 | ✅ | ✅ |
| 悬浮提示板 | ✅ | — |
| 系统音频捕获 | ✅ | — |
| 预设区域截图与全局快捷键 | ✅ | — |
| 连接局域网 Ollama | ✅ | ✅ |

## 系统要求

- macOS 14.0 或更高版本，或 iOS / iPadOS 17.0 或更高版本；
- 从源码构建需要 Xcode 16 或兼容 Swift 6 的更高版本；
- macOS 完整功能需要麦克风、语音识别、屏幕与系统音频录制权限；
- 使用 Ollama 时，需要安装 Ollama 并下载至少一个本地模型；
- 使用外部模型或豆包语音时，需要用户自己的凭证和网络连接。

## 快速开始

目前仓库以源码形式提供。若 Releases 页面尚未提供安装包，请使用 Xcode 构建。

### 1. 克隆仓库

```bash
git clone https://github.com/pennyzhaozhao/AI-interview-Assistant.git
cd AI-interview-Assistant
```

### 2. 打开工程

```bash
open InterviewAssistant.xcodeproj
```

项目不包含 Firebase、Google Sign-In、Supabase 或 Cloudflare Workers，也不需要安装这些服务的 SDK。

### 3. 配置签名

在 Xcode 中依次选择：

1. `InterviewAssistant` Project；
2. `InterviewAssistant` Target；
3. `Signing & Capabilities`；
4. 选择自己的 Development Team；
5. 将默认的 `com.pennyzhaozhao.interviewassistant` 改成自己控制的唯一 Bundle Identifier。

个人调试可以使用 Personal Team。准备公开分发时，应使用自己的 Apple Developer 身份完成签名和公证。

### 4. 运行

- macOS：选择 `My Mac`；
- iOS / iPadOS：选择模拟器或真机；
- 选择 `InterviewAssistant` Scheme；
- 按 `⌘R` 构建并运行。

## 第一次启动建议

推荐按以下顺序完成设置：

1. 在 **设置 → 外观** 中选择界面语言和主题；
2. 在 **设置 → 数据存储** 中确认或更改本地数据目录；
3. 在 **设置 → API 配置 → 语音识别** 中选择 Apple 或豆包语音；
4. 在 **设置 → API 配置** 中选择 AI 服务商和具体模型；
5. 保存配置并执行一次“测试连接”；
6. 在 macOS 系统设置中授予需要的权限；
7. 创建知识库，填写目标岗位和 JD，再开始第一次面试。

## 选择 AI 模型

当前版本使用一套**全局模型配置**。正式面试、截图问答、公司资料解析和模拟面试都会读取最近保存的服务商与模型。

进入：

```text
设置 → API 配置
```

然后：

1. 在“服务商”中选择 Ollama、DeepSeek、OpenAI、Claude、Gemini 或火山方舟；
2. 在“当前模型”菜单中选择具体模型；
3. 检查 API URL；
4. 填写该服务商的 API Key；
5. 点击“测试连接”；
6. 测试成功后点击“保存”。

每个服务商的 API URL、模型和 API Key 会分别保存。切换回之前配置过的服务商时，不需要重复填写全部内容；最后保存的服务商就是当前生效的服务商。

> [!NOTE]
> 当前首页不会为每场面试单独选择模型。若要更换模型，请先到“设置 → API 配置”中切换并保存。当前版本只保证界面内置模型列表中的模型能够被选中并生效。

### 当前内置服务商

| 服务商 | 默认 API 地址 | 代码内置模型示例 | API Key |
| --- | --- | --- | --- |
| Ollama | `http://localhost:11434/v1` | `qwen2.5:7b`、`llama3.1:8b`、`qwen2.5:14b` | 通常不需要 |
| DeepSeek | `https://api.deepseek.com` | `deepseek-flash`、`deepseek-v4-pro` | 必需 |
| OpenAI | `https://api.openai.com/v1` | `gpt-4.1-mini`、`gpt-4.1`、`gpt-4o-mini`、`gpt-4o` | 必需 |
| Claude | `https://api.anthropic.com/v1/messages` | `claude-sonnet-4-5`、`claude-opus-4-1`、`claude-haiku-4-5` | 必需 |
| Gemini | `https://generativelanguage.googleapis.com/v1beta` | `gemini-2.0-flash`、`gemini-2.5-pro` | 必需 |
| 火山方舟 | `https://ark.cn-beijing.volces.com/api/v3` | `doubao-seed-1-8-251228` 等 | 必需 |

模型名称和服务商接口可能发生变化。若连接失败，请先查看对应服务商控制台，确认账号确实拥有该模型的调用权限。

## 配置 Ollama 本地模型

macOS 默认连接地址：

```text
http://localhost:11434/v1
```

示例：

```bash
ollama pull qwen2.5:7b
ollama serve
```

然后在应用中：

1. 服务商选择 **Ollama**；
2. API URL 填写 `http://localhost:11434/v1`；
3. 选择已经下载的模型；
4. API Key 留空；
5. 点击“测试连接”；
6. 点击“保存”。

在 iPhone 或 iPad 上连接 Mac 的 Ollama 时，两台设备需要处于同一可信局域网。API URL 应填写 Mac 的局域网地址，例如：

```text
http://192.168.1.10:11434/v1
```

让 Ollama 监听局域网地址：

```bash
OLLAMA_HOST=0.0.0.0 ollama serve
```

仅应在可信网络中开放该端口，并根据需要配置 macOS 防火墙。

## 配置语音识别

语音识别与回答模型分开配置。可以使用本地语音识别搭配外部模型，也可以使用外部语音识别搭配 Ollama。

### Apple 本地语音识别

进入 **设置 → API 配置 → 语音识别**，选择 **Apple 本地识别**。

- 不需要第三方语音 API 凭证；
- 配置简单；
- 可以减少音频离开设备的情况；
- 语言支持和离线可用性取决于系统版本、地区和已安装的语音资源。

### 豆包语音识别

如果 Apple 本地识别不能满足需求，可以直接连接豆包语音：

1. 在火山引擎 / 豆包语音控制台创建应用；
2. 开通对应版本的流式语音识别；
3. 复制 `App ID` 和 `Access Token`；
4. 在应用中选择 **豆包语音识别 2.0**；
5. 选择与控制台一致的识别模型；
6. 测试连接后保存。

常见资源 ID：

```text
volc.seedasr.sauc.duration
volc.seedasr.sauc.concurrent
```

实际资源 ID、权限和计费方式以服务商控制台为准。使用豆包语音时，音频会从设备直接发送给该服务商。

## macOS 权限

| 权限 | 用途 | 系统设置位置 |
| --- | --- | --- |
| 麦克风 | 获取用户或外部设备的语音 | 隐私与安全性 → 麦克风 |
| 语音识别 | 使用 Apple Speech | 隐私与安全性 → 语音识别 |
| 屏幕与系统音频录制 | 捕获系统音频和截图 | 隐私与安全性 → 屏幕与系统音频录制 |
| 本地网络 | 连接局域网 Ollama 或其他设备 | 隐私与安全性 → 本地网络 |

授权后如果功能仍无响应，请完全退出应用再重新打开。改变签名或 Bundle Identifier 后，macOS 可能会把它视为新的应用并要求重新授权。

## 使用指南

### 创建和选择知识库

1. 打开侧边栏中的 **知识库**；
2. 点击“新建资料”；
3. 填写名称和描述并保存；
4. 手动增加主要内容，或上传文件 / 导入公开链接；
5. 检查提取文本是否正确；
6. 使用知识库卡片上的开关决定它是否参与面试；
7. 回到面试主页，确认本场面试启用的知识库。

没有创建或选中知识库时，右侧详情区会保持为空。删除最后一个知识库后也不会出现无法保存的空表单。

建议每个项目至少整理：背景、目标、个人职责、关键行动、取舍、结果、失败与反思。不要导入无权发送给外部模型的机密内容。

### 开始正式面试

1. 先在 **设置 → API 配置** 中确认当前模型；
2. 在主页填写目标岗位和 Job Description；
3. 可选：填写公司名称、官网和备注；
4. 如果生成公司摘要，请人工核对内容；
5. 选择本场面试允许使用的知识库；
6. 点击“开始面试”；
7. 在 macOS 提示板中选择麦克风、系统音频或静音；
8. 结束后在“历史”中查看记录。

### 使用悬浮提示板

提示板支持三种音频状态：

- **麦克风**：识别当前麦克风输入；
- **系统音频**：识别会议软件、浏览器或其他应用播放的声音；
- **静音**：停止语音识别，但仍可使用截图问答。

“屏幕共享时隐藏提示板”依赖 macOS 和录屏软件的窗口捕获方式，不能保证在所有系统版本和软件中都不可见。正式使用前请自行测试。

### 使用截图问答

预设区域模式：

1. 打开 **设置 → 截图模式**；
2. 允许屏幕录制权限；
3. 选择“预设区域截图”；
4. 在面试前点击“设置区域”；
5. 按 `⌘⇧S` 或点击提示板截图按钮；
6. 可以继续截取其他区域；
7. 完成后统一分析。

手动框选模式会在每次截图时重新选择区域，适合页面布局经常变化的场景。如果快捷键冲突，可以在设置中重新录制。

### 进行模拟面试

1. 在设置中确认当前 AI 模型；
2. 在主页填写岗位与 JD；
3. 选择需要使用的知识库；
4. 点击“模拟面试”；
5. 选择 3–10 道题以及回答语言；
6. 逐题录音并提交回答；
7. 查看评分、反馈和建议答案；
8. 完成后查看整体总结；
9. 如有需要，导出评估 PDF。

### 查看和清理历史记录

“历史”页面同时显示正式面试与模拟面试记录。可以搜索、查看对话、评分、截图和建议答案，也可以删除不再需要的会话。

## 数据存储与隐私

### 自定义数据目录

进入：

```text
设置 → 数据存储
```

可以查看当前目录、选择新文件夹或清空用户数据；macOS 还可以直接在 Finder 中打开当前目录。

选择新位置时：

1. 应用会在所选位置创建 `InterviewAssistantData` 子目录；
2. 当前历史记录、知识库数据和已保存截图会复制到新目录；
3. 完成后需要完全退出并重新打开应用；
4. 新数据库可用后，应用会清理旧数据库文件。

“清空全部数据”会删除面试历史、知识库和保存的截图，但不会删除 Keychain 中的 API Key，也不会重置语言、主题等应用偏好。

> [!NOTE]
> 当前版本中，知识库条目与提取文本位于所选 SwiftData 数据库；为了支持 PDF 预览，导入文件的本地副本仍可能位于应用的 Application Support 目录。删除敏感原始文件前，请同时检查应用数据目录。

### 数据流

| 数据 | 默认存储位置 | 什么时候离开设备 |
| --- | --- | --- |
| API Key、ASR 凭证 | Apple Keychain | 连接对应服务商时用于鉴权 |
| 知识库条目和提取文本 | SwiftData，可在设置中迁移 | 作为相关上下文发送给所选外部模型时 |
| 正式与模拟面试历史 | SwiftData，可在设置中迁移 | 相关内容用于外部模型请求时 |
| 历史截图 | SwiftData 管理的外部数据，可随数据库迁移 | 发送截图问题给外部模型时 |
| 导入 PDF 的预览副本 | 本机 Application Support | PDF 内容参与外部模型请求时 |
| 语言、主题、快捷键 | UserDefaults | 不主动上传 |
| 麦克风 / 系统音频 | 识别流程内存 | 使用外部 ASR 时发送给对应服务商 |

项目维护者没有用于接收上述数据的服务器。第三方模型与语音服务如何处理数据，取决于用户选择的服务商及其隐私政策。

## 常见问题

### 不知道当前正在使用哪个模型

打开 **设置 → API 配置**。页面中的“服务商”和“当前模型”就是全局生效配置。最后点击“保存”的服务商会用于后续正式面试、模拟面试、截图问答和公司解析。

### API Key 不存在或保存后仍提示缺少

- 确认 API Key 与当前服务商匹配；
- 重新填写并点击“保存”；
- Bundle Identifier 或签名改变后，Keychain 访问组可能变化，需要重新保存；
- Ollama 通常不需要 API Key，但本地服务必须正在运行。

### Ollama 无法连接

- 执行 `ollama list`，确认需要的模型已经下载；
- 执行 `ollama serve`，确认服务正在运行；
- macOS 使用 `http://localhost:11434/v1`；
- iOS 使用 Mac 的局域网 IP，不能填写 iPhone 自己的 `localhost`；
- 检查 macOS 防火墙和本地网络权限。

### 系统音频无法识别

- 授予“屏幕与系统音频录制”权限；
- 完全退出并重新打开应用；
- 确认提示板处于“系统音频”状态；
- 确认目标应用正在播放声音；
- 检查 Zoom、Teams 或其他会议软件当前使用的输出设备。

### Apple 语音识别不可用

- 授予麦克风和语音识别权限；
- 检查所选语言是否受系统支持；
- 下载需要的系统语音资源；
- 确认当前输入设备可以正常录音。

### 截图快捷键无响应

- 检查快捷键是否与其他应用冲突；
- 在设置中重新录制快捷键；
- 授予屏幕与系统音频录制权限；
- 使用预设模式时，先保存截图区域；
- 尝试切换到手动框选模式。

### 公司官网解析失败

- 确认网址包含 `https://`；
- 某些网站会阻止抓取或依赖浏览器端渲染；
- 检查当前模型的连接状态；
- 无法自动解析时，将可信内容手动填写到公司备注。

### 更换数据位置后仍显示旧目录

- 确认选择目录时没有取消文件访问授权；
- 等待应用显示复制成功；
- 完全退出 InterviewAssistant，而不是只关闭窗口；
- 重新启动后再检查“设置 → 数据存储”；
- 不要在应用运行时手动移动 `.store`、`-wal` 或 `-shm` 文件。

## 技术栈

| 模块 | 技术 |
| --- | --- |
| 客户端 | Swift 6、SwiftUI、SwiftData |
| macOS 音频 | AVFoundation、ScreenCaptureKit |
| 本地语音 | Apple Speech Framework |
| 可选外部语音 | 豆包 / 火山引擎流式 ASR WebSocket |
| 凭证 | Apple Keychain |
| 文档处理 | PDFKit、系统文档导入能力 |
| 本地模型 | Ollama（OpenAI-compatible API） |
| 外部模型 | OpenAI、Claude、DeepSeek、Gemini、火山方舟 |

## 项目结构

```text
.
├── InterviewAssistant/
│   ├── History/                  # 正式与模拟面试历史
│   ├── KnowledgeBase/            # 知识库、文档导入和 PDF 预览
│   ├── MockInterview/            # 模拟面试、评分和 PDF 导出
│   ├── Receiver/                 # 悬浮提示板、音频、ASR 和截图
│   ├── Resources/                # Info.plist、权限和 Assets
│   ├── Sender/                   # 局域网提示发送实验模块
│   ├── Settings/                 # 外观、数据目录、快捷键和 API 配置
│   ├── Shared/                   # 数据模型、Keychain、AI 和通用服务
│   └── Setup/                    # 面试准备工作流
├── InterviewAssistant.xcodeproj/ # Xcode 工程
├── presentation img/             # README 演示图片
├── scripts/build-dmg.sh           # macOS DMG 构建脚本
├── DESIGN_SYSTEM.md               # UI 设计规范
├── LICENSE                        # MIT License
└── README.md
```

## 构建 macOS DMG

```bash
./scripts/build-dmg.sh
```

构建产物位于 `dist/`。公开分发前还需要：

1. 使用自己的 Developer ID Application 证书签名；
2. 使用 Apple Developer 账号完成 notarization；
3. staple 公证票据；
4. 在没有开发环境的 Mac 上测试安装和首次授权；
5. 确认产物中没有 API Key、个人证书或本地数据库。

## 开发与安全说明

- 新增外部请求时，必须明确记录数据会发送到哪里；
- 不要提交 API Key、Token、证书、配置文件或个人数据库；
- 新增模型服务商时，将 URL、鉴权和响应解析集中在 `AIService.swift`；
- 修改 SwiftData 模型时，应设计已有用户的数据迁移方案；
- 修改权限时，应同步更新 `Info.plist`、entitlements 和 README；
- 提交前至少验证 macOS 与 iOS 构建；
- `.gitignore` 已排除数据库、凭证、Xcode 用户数据和常见构建产物。

如果发现凭证泄露、隐私数据暴露或其他安全问题，请不要把敏感内容粘贴到公开 Issue。可以先提交不含敏感细节的安全报告，再通过仓库维护者公开提供的安全渠道继续沟通。

## 贡献

欢迎提交 Issue 和 Pull Request：

1. Fork 仓库；
2. 创建功能分支；
3. 完成修改和必要测试；
4. 确认提交中没有个人信息、凭证或本地数据库；
5. 在 Pull Request 中说明背景、实现方式和验证结果。

示例：

```bash
git checkout -b feature/your-feature
git commit -m "feat: describe your change"
git push origin feature/your-feature
```

## 开源许可证

本项目使用 [MIT License](./LICENSE)。你可以使用、复制、修改和分发代码，但软件按“原样”提供，不附带任何形式的担保。

---

如果这个项目对你有帮助，欢迎 Star、提交反馈或贡献更好的本地面试工作流。
