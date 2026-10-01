import SwiftUI

enum AppThemeMode: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return L.t("Dark")
        case .light: return L.t("Light")
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .dark: return .dark
        case .light: return .light
        }
    }

    static var current: AppThemeMode {
        AppThemeMode(rawValue: UserDefaults.standard.string(forKey: AppPreferenceKey.themeMode) ?? "") ?? .dark
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppPreferenceKey.language) ?? "") ?? .english
    }
}

enum ScreenshotMode: String, CaseIterable, Identifiable {
    case presetRegion = "presetRegion"
    case manualSelect = "manualSelect"

    var id: String { rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "globalHotkey", Self.presetRegion.rawValue:
            self = .presetRegion
        case Self.manualSelect.rawValue:
            self = .manualSelect
        default:
            self = .presetRegion
        }
    }

    var displayName: String {
        switch self {
        case .presetRegion: return L.t("Preset Region Screenshot")
        case .manualSelect: return L.t("Manual Selection Screenshot")
        }
    }

    var description: String {
        switch self {
        case .presetRegion:
            return L.t("Set the screenshot region before the interview. During the interview, use the hotkey or screenshot button to capture silently without stealing focus.")
        case .manualSelect:
            return L.t("Select an area manually each time. This may briefly move focus away from the interview window.")
        }
    }
}

enum AppPreferenceKey {
    static let themeMode = "app_theme_mode"
    static let language = "app_language"
    static let manualTriggerHotkey = "manual_trigger_hotkey"
    static let screenshotHotkey = "screenshot_ocr_hotkey"
    static let screenshotMode = "screenshot_mode"
    static let screenshotPresetRegion = "screenshot_preset_region"
    static let mockInterviewLanguage = "mock_interview_language"
    static let interviewerLanguage = "interviewer_language"
    static let asrProvider = "asr_provider"
    static let hiddenFromScreenCapture = "hidden_from_screen_capture"
    static let migratedHiddenFromScreenCaptureDefault = "migrated_hidden_from_screen_capture_default_v1"
    static let hideDockIcon = "hide_dock_icon"
    static let speechHeuristicsEnabled = "speech_heuristics_enabled"
    static let speakerRecognitionEnabled = "speaker_recognition_enabled"
    static let speakerRecognitionSensitivity = "speaker_recognition_sensitivity"
    static let speakerRecognitionDebugLogging = "speaker_recognition_debug_logging"
}

enum L {
    static func t(_ key: String) -> String {
        guard AppLanguage.current == .chinese else { return key }
        return zhHans[key] ?? key
    }

    private static let zhHans: [String: String] = [
        "About": "关于",
        "Add a clear review title": "添加清晰的复盘标题",
        "Add Main Content": "添加主要内容",
        "Add source failed": "添加来源失败",
        "AI is reviewing your answers, scoring each question, and preparing improvement suggestions.": "AI 正在复盘你的回答、为每道题评分，并整理改进建议。",
        "AI": "AI",
        "AI Answer": "AI 回答",
        "AI Suggested Answer": "AI 建议回答",
        "AI-native prep": "AI 原生面试准备",
        "AI will prioritize this asset when answering.": "AI 回答时会优先参考这份资料。",
        "API Configure": "API 配置",
        "API Key": "API Key",
        "API settings": "API 设置",
        "API URL": "API URL",
        "Appearance": "外观",
        "Asset Details": "资料详情",
        "Auto Scroll Off": "自动滚动关闭",
        "Auto Scroll On": "自动滚动开启",
        "Balanced": "均衡",
        "Build": "构建版本",
        "Cancel": "取消",
        "Choose Knowledge": "选择知识库",
        "Check for Updates...": "检查更新…",
        "Checking for Updates...": "正在检查更新…",
        "Download Update": "下载更新",
        "Later": "稍后",
        "You're up to date": "已是最新版本",
        "Unable to Check for Updates": "无法检查更新",
        "Check your internet connection and try again.": "请检查网络连接后重试。",
        "A newer version is ready to download.": "已有新版本可供下载。",
        "Version %@ is available": "发现新版本 %@",
        "InterviewAssistant %@ is the latest version.": "InterviewAssistant %@ 已是最新版本。",
        "Choose code language": "选择代码语言",
        "Choose how many questions this mock interview should include.": "选择这次模拟面试要包含多少道题。",
        "Choose a provider, model, and key for interview answers.": "选择用于生成面试回答的服务商、模型和密钥。",
        "Choose which materials AI can use during interviews.": "选择面试期间 AI 可以使用的材料。",
        "Click to set": "点击设置",
        "Clear": "清空",
        "Clear History": "清空历史",
        "Close": "关闭",
        "Compact": "紧凑",
        "Configuration saved.": "配置已保存。",
        "Connection": "连接",
        "Connection failed": "连接失败",
        "Connection success": "连接成功",
        "Confirm Delete": "确认删除",
        "Contact Support": "联系支持",
        "Content": "内容",
        "Controls": "控制",
        "Continue Shot": "继续截图",
        "Conversation": "会话",
        "Conversation title": "会话标题",
        "Confirm": "确认",
        "Copy": "复制",
        "Copy Answer": "复制回答",
        "Copied": "已复制",
        "Real interview speech recognition": "真实面试语音识别",
        "Real interview AI answer": "真实面试 AI 回答",
        "Screenshot + AI answer": "截图 + AI 回答",
        "Company website research": "公司网站解析",
        "Company Introduction": "公司介绍",
        "Record the website, business, compensation structure, and company understanding you may be asked about in interviews.": "记录官网、业务、薪资架构和面试中可能被问到的公司理解。",
        "Company Name": "公司名称",
        "For example: Linear / DeepSeek / ByteDance": "例如：Linear / DeepSeek / 字节跳动",
        "Company Website": "公司网站",
        "Parse Website": "解析网站",
        "Parsing": "解析中",
        "Company Notes": "公司资料",
        "You can write: business, products, target users, competitors, compensation structure, what interviewers may care about, and why you want to join.": "可以写：公司业务、产品、目标用户、竞争对手、薪资架构、面试官可能关心的点、你为什么想加入。",
        "Parsing the company website and generating a research summary...": "正在解析公司网站并生成研究摘要...",
        "Website research summary (please review manually):": "官网解析摘要（请再手动校对）:",
        "Company research summary generated. Please review it quickly before the interview.": "已生成公司研究摘要，建议快速校对后再开始面试。",
        "Parsing failed: %@. You can fill in the company notes manually.": "解析失败：%@。你可以手动填写公司资料。",
        "Knowledge base RAG search": "知识库 RAG 检索",
        "Generate 5 mock questions": "模拟面试生成 5 题",
        "Generate 10 mock questions": "模拟面试生成 10 题",
        "Generate 20 mock questions": "模拟面试生成 20 题",
        "Mock interview speech recognition": "模拟面试语音识别",
        "Mock interview AI evaluation": "模拟面试 AI 评估",
        "Current model": "当前模型",
        "Currently showing": "当前显示的是",
        "Custom model": "自定义模型",
        "Danger Zone": "注意区域",
        "Dark": "深色",
        "Delay": "延迟",
        "Delete": "删除",
        "Delete Session": "删除会话",
        "Delete Selected": "删除所选",
        "Delete source failed": "删除来源失败",
        "Density": "密度",
        "Description": "描述",
        "Deselect All": "取消全选",
        "Disabled": "未启用",
        "Dismiss Keyboard": "收起键盘",
        "Done": "完成",
        "Edit Source": "编辑来源",
        "Edit metadata, import sources, and decide whether this asset is available to interviews.": "编辑元数据、导入来源，并决定这份资料是否用于面试。",
        "Email": "邮箱",
        "Enabled": "已启用",
        "Enabled for interviews": "用于面试",
        "Enabled for this interview": "已用于本次面试",
        "End Interview": "结束面试",
        "Enter prompt...": "输入提示内容...",
        "Enter this IP on the interview receiver.": "在面试接收端输入这个 IP。",
        "Finish Analysis": "完成分析",
        "Follow App Language": "跟随 App 语言",
        "GitHub source": "GitHub 来源",
        "Generate Code": "生成代码",
        "Generating Interview Evaluation": "正在生成面试评估",
        "History": "历史",
        "Hide Dock During Interview": "面试时隐藏 Dock",
        "Hide Dock Icon": "隐藏 Dock 图标",
        "Home": "首页",
        "Idle": "空闲",
        "Import": "导入",
        "Import Link": "导入链接",
        "Import a PDF or public GitHub link to turn it into interview-ready context.": "导入 PDF 或公开 GitHub 链接，转换为可用于面试的上下文。",
        "Import failed": "导入失败",
        "Import source": "导入来源",
        "Imported link": "导入的链接",
        "Importing PDF...": "正在导入 PDF...",
        "Importing...": "正在导入...",
        "Interview": "面试",
        "Interview AI": "Interview AI",
        "Interview History": "面试历史",
        "Interview context, notes, or portfolio material": "面试上下文、笔记或作品集材料",
        "Job description": "职位描述",
        "Keep iPhone and Mac on the same Wi-Fi, then use the Mac LAN IP.": "让 iPhone 和 Mac 连接同一个 Wi-Fi，然后使用 Mac 的局域网 IP。",
        "Knowledge": "知识库",
        "Knowledge Base": "知识库",
        "Knowledge base title": "知识库标题",
        "Keep one decimal, for example 2.0 or 3.5.": "保留一位小数，例如 2.0 或 3.5。",
        "Language": "语言",
        "Large": "大",
        "Light": "浅色",
        "Link imported": "链接已导入",
        "Listening": "正在监听",
        "Local IP": "本机 IP",
        "Local network": "本地网络",
        "Main Content": "主要内容",
        "Main Content added": "主要内容已添加",
        "Manage Knowledge": "管理知识库",
        "Manage model providers and API keys": "管理模型服务商和 API Key",
        "Manual Trigger": "手动触发",
        "Manage reusable context as enabled assets for interview sessions.": "管理可复用的面试上下文资料。",
        "Manual source": "手动来源",
        "Manual Selection Screenshot": "手动框选截图",
        "Mic": "麦克风",
        "Microphone": "麦克风",
        "Minimize": "最小化",
        "Mode": "模式",
        "Model": "模型",
        "More": "更多",
        "Must Mention": "必须提到",
        "New Asset": "新建资料",
        "New Knowledge Asset": "新建知识资料",
        "No Wi-Fi IP detected. Keep iPhone and Mac on the same Wi-Fi and avoid cellular addresses.": "没有检测到 Wi-Fi IP。请让 iPhone 和 Mac 连接同一个 Wi-Fi，并避免使用蜂窝网络地址。",
        "No interview history yet.": "还没有面试历史。",
        "No knowledge base is enabled for this interview.": "本次面试还没有启用知识库。",
        "No knowledge selected": "未选择知识库",
        "No messages sent yet": "还没有发送消息",
        "No sources yet": "还没有来源",
        "Not Listening": "未监听",
        "Not Signed In": "未登录",
        "Now": "刚刚",
        "Off": "关闭",
        "OK": "好的",
        "Ollama usually works without an API key.": "Ollama 通常不需要 API Key。",
        "OCR complete": "识别完成",
        "OCR running": "正在识别",
        "Getting screenshot...": "正在获取截图…",
        "Other language...": "其他语言...",
        "Page": "第",
        "PDF Preview": "PDF 预览",
        "PDF import failed": "PDF 导入失败",
        "PDF imported": "PDF 已导入",
        "PDF imported, but no readable text was found": "PDF 已导入，但没有找到可读取的文本",
        "PDF source": "PDF 来源",
        "Password": "密码",
        "Current Password": "原密码",
        "Email, App ID, password, and cloud sync": "绑定邮箱、App ID、密码和云端同步",
        "Enter your current password before setting a new one": "输入原密码后设置新密码",
        "Paste API key": "粘贴 API Key",
        "Paste the job description, responsibilities, or requirements here.": "在这里粘贴职位描述、职责或岗位要求。",
        "Platform": "平台",
        "Port": "端口",
        "Practice smarter. Ace your next interview.": "更聪明地练习，拿下下一场面试。",
        "Press any key...": "按任意键...",
        "Preparing answer suggestion...": "正在准备回答建议...",
        "Resize prompt height": "调整提示板高度",
        "Restore": "展开",
        "Waiting for AI answer...": "等待 AI 作答...",
        "Privacy Policy": "隐私政策",
        "Prompt": "提示",
        "Prompt Sender": "提示发送器",
        "Prompt sender IP": "提示发送器 IP",
        "Preset Region Screenshot": "预设区域截图",
        "Provider": "服务商",
        "Pull failed": "拉取失败",
        "Pull success.": "拉取成功。",
        "Question": "问题",
        "Question Review Details": "问答记录详情",
        "Quit": "退出",
        "Ready": "就绪",
        "Receiver IP": "接收端 IP",
        "Receiver not connected": "接收端未连接",
        "Recording": "录音中",
        "Recognized preview": "已识别内容预览",
        "Reusable interview context and source material.": "可复用的面试上下文和来源材料。",
        "Review past interview conversations and outcomes.": "查看过往面试对话和结果。",
        "Role": "角色",
        "Reset": "重新设置",
        "Save": "保存",
        "Save Asset": "保存资料",
        "Save and test the current provider settings.": "保存并测试当前服务商设置。",
        "Save source failed": "保存来源失败",
        "Saved": "已保存",
        "Search": "搜索",
        "Search history": "搜索历史",
        "Search knowledge": "搜索知识库",
        "Select a session to inspect the interview flow.": "选择一个会话来查看面试流程。",
        "Select": "选择",
        "Select All": "全选",
        "Select where responses should be generated.": "选择回答由哪个服务生成。",
        "Send": "发送",
        "Send History": "发送历史",
        "Sender": "发送",
        "Settings": "设置",
        "Screenshot": "截图",
        "Screenshot Mode": "截图模式",
        "Screenshot OCR": "截图识别",
        "Screen Recording Permission": "需要屏幕录制权限",
        "Open System Settings": "打开系统设置",
        "Screenshot region not set": "未设置截图区域",
        "Screenshot region saved. Use the hotkey or screenshot button during the interview to capture silently.": "截图区域已保存，面试中使用快捷键或截图按钮即可静默截图。",
        "Screenshot region set": "截图区域已设置",
        "Selecting region...": "选择区域中...",
        "Set Region": "设置区域",
        "Set screenshot region first": "需要先设置截图区域",
        "Set the region before the interview starts. During the interview, capture directly without affecting the interview window focus.": "建议在面试开始前设置好区域，面试中直接截图，不影响面试窗口焦点。",
        "Set the screenshot region before the interview. During the interview, use the hotkey or screenshot button to capture silently without stealing focus.": "提前设定截图区域，面试中按快捷键或点击截图按钮静默截图，不影响面试窗口焦点。",
        "Shape the interview around the exact opportunity.": "围绕具体岗位定制本次面试。",
        "Shot": "第",
        "Short description": "简短描述",
        "Show App": "显示应用",
        "Show Dock Icon": "显示 Dock 图标",
        "Source deleted": "来源已删除",
        "Source saved": "来源已保存",
        "Source title": "来源标题",
        "Sources": "来源",
        "Select an area manually each time. This may briefly move focus away from the interview window.": "每次手动框选区域，可能导致面试窗口短暂失焦。",
        "Analyzing": "分析中...",
        "captured, continue or finish": "已截取，继续截图或完成分析",
        "shots suffix": "张",
        "Standby": "待命",
        "Start Interview": "开始面试",
        "Starting": "正在启动",
        "Starting...": "正在开始...",
        "Stored locally in Keychain.": "已本地存储在 Keychain。",
        "Support": "支持",
        "Switch to Wi-Fi and try again.": "建议切换到 Wi-Fi 后重试。",
        "System": "系统",
        "System Audio": "系统音频",
        "Target role": "目标岗位",
        "Terms of Service": "服务条款",
        "Test Connection": "测试连接",
        "Testing...": "正在测试...",
        "The original PDF file is not available. Re-import this PDF to enable preview.": "原始 PDF 文件不可用。请重新导入该 PDF 以启用预览。",
        "Theme": "主题",
        "Thinking": "思考中",
        "This interview does not have AI question records yet.": "这场面试还没有 AI 问题记录。",
        "This cannot be undone.": "删除后无法恢复。",
        "Title": "标题",
        "URL format error": "URL 格式错误",
        "Unexpected response": "响应异常",
        "Unknown": "未知",
        "Untitled Knowledge Asset": "未命名知识资料",
        "Upload PDF": "上传 PDF",
        "Upload failed": "上传失败",
        "Upload success.": "上传成功。",
        "Uploading...": "正在上传...",
        "Please set a screenshot region in Settings before using preset region capture.": "请在设置中设置好截图区域后，再使用预设区域截图。",
        "Choose whether screenshots use a preset region for silent capture during interviews.": "选择面试中截图是否使用预设区域静默捕获",
        "Version": "版本",
        "Version, support, and app information": "版本、支持和应用信息",
        "Waiting": "等待中",
        "Waiting for connection": "等待连接",
        "Waiting for answer keywords": "等待回答关键词",
        "Waiting for answer": "等待回答",
        "Waiting for interview question": "等待面试问题",
        "Waiting for interview question...": "等待面试问题...",
        "New question detected · Tap to answer": "检测到新问题 · 点击回答",
        "🙋 You are answering": "🙋 你在作答",
        "Speaker Recognition": "说话人识别",
        "Set Up Voices": "设置声音",
        "Back to Settings": "返回设置",
        "Voices": "声音",
        "Voice": "声音",
        "None": "无",
        "Choose the voice that belongs to you during an interview.": "选择面试时代表你的声音；选择“无”可关闭识别。",
        "Turn off voice recognition": "关闭说话人识别",
        "Add Voice…": "添加声音…",
        "Active": "正在使用",
        "Available": "可用",
        "Rename Voice": "重命名声音",
        "Voice Name": "声音名称",
        "Enter a name that will help you recognize this voice.": "输入一个便于辨认的声音名称。",
        "Delete Voice": "删除声音",
        "This removes the voiceprint from this device.": "这会从本机删除该声纹。",
        "Voice recognition is off.": "说话人识别已关闭。",
        "Active voice updated.": "已切换当前声音。",
        "Recognition Sensitivity": "识别灵敏度",
        "Higher sensitivity is stricter when deciding whether a speaker is you.": "灵敏度越高，判断说话人是否为你时越严格。",
        "Add a Voice": "添加声音",
        "Voice Added": "声音已添加",
        "This voice is now selected for speaker recognition.": "此声音已设为当前识别声音。",
        "Speak naturally using the microphone and room you normally use for interviews.": "请使用平时面试的麦克风和环境自然说话。",
        "Start Voice Setup": "开始设置声音",
        "Preparing Microphone…": "正在准备麦克风…",
        "Processing…": "正在处理…",
        "Voice setup is complete.": "声音设置完成。",
        "Identify My Voice": "识别我的声音",
        "Sensitivity": "灵敏度",
        "Speaker Debug Logging": "声纹调试日志",
        "Enroll My Voice": "注册我的声音",
        "Re-enroll My Voice": "重新注册声音",
        "Re-enroll Voice": "重新注册声音",
        "Re-enroll or Test Voice": "重新注册或测试声音",
        "Your voiceprint stays on this device and is never uploaded.": "你的声纹仅保存在本机，绝不会上传。",
        "Voiceprints are biometric data. They are encrypted in Keychain and never uploaded.": "声纹属于生物特征数据，会加密保存在钥匙串中，绝不会上传。",
        "Speaker model ready": "声纹模型已就绪",
        "Speaker model is not downloaded": "尚未下载声纹模型",
        "Downloading...": "正在下载…",
        "Download Speaker Model (28.3 MB)": "下载声纹模型（28.3 MB）",
        "Downloading the on-device speaker model...": "正在下载端侧声纹模型…",
        "Speaker model downloaded and verified": "声纹模型已下载并校验",
        "Read this passage for about 15 seconds using the same microphone and room you will use for interviews.": "请使用面试时相同的麦克风和环境，朗读这段文字约 15 秒。",
        "Recording...": "正在录音…",
        "Keep speaking naturally until recording finishes.": "请自然朗读，直到录音结束。",
        "Voice enrollment complete. Run the self-check once to calibrate it.": "声音注册完成，请进行一次自检以校准阈值。",
        "Self-check": "声音自检",
        "Say one natural sentence to calibrate the matching threshold.": "自然说一句话，用于校准匹配阈值。",
        "Start Self-check": "开始自检",
        "Say one sentence now.": "现在请说一句话。",
        "Similarity: %.2f": "相似度：%.2f",
        "Self-check passed and thresholds were calibrated.": "自检完成，阈值已校准。",
        "Delete Voiceprint": "删除声纹",
        "No voice profile is enrolled": "尚未注册声纹",
        "Record at least three voice samples": "请至少录制三段声音样本",
        "The voice sample was too short or unclear": "声音样本太短或不够清晰",
        "Download the speaker model first": "请先下载声纹模型",
        "The downloaded speaker model failed verification": "下载的声纹模型校验失败",
        "Director Mode": "导演模式",
        "Director": "导演",
        "Host a prompt board or connect as a controller": "开启提示板，或作为控制端连接",
        "Start": "开始",
        "YOUR IP ADDRESS": "你的 IP 地址",
        "ENTER HOST IP ADDRESS": "输入 HOST IP 地址",
        "Connect": "连接",
        "Connected": "已连接",
        "Connected to host": "已连接 Host",
        "Waiting for host connection": "等待连接 Host",
        "WEB CONTROLLER": "网页控制端",
        "Scan to send without the app": "扫码即可发送，无需安装 App",
        "The Host prompt board must be running on the same Wi-Fi.": "Host 提示板需要在同一 Wi-Fi 下运行。",
        "QUESTION": "问题",
        "USER in AI mode": "用户处于 AI 模式",
        "USER in Director mode": "用户处于导演模式",
        "Waiting for the Host to hear or capture a question": "等待 Host 听到或截取题目",
        "SEND MARKDOWN CONTENT": "发送 MARKDOWN 内容",
        "Supports headings, lists, code blocks and links": "支持标题、列表、代码块和链接",
        "User switched to AI mode": "用户已切换至 AI 模式",
        "User switched to Director mode": "用户已切换至导演模式",
        "Host opened the prompt board": "对方已打开提示板",
        "Host closed the prompt board": "对方已关闭提示板",
        "AI Deep Feedback": "AI 深度评价",
        "Answer with your own voice. AI asks, records, and evaluates after the interview.": "用你自己的表达回答。AI 负责提问、记录，并在结束后评估。",
        "Behavioral": "行为面",
        "Double-click to view image": "双击查看大图",
        "Edit the transcript before submitting. No AI help is shown during mock interviews.": "提交前可以编辑语音转写稿。模拟面试过程中不会显示 AI 帮助回答。",
        "Formal Interview": "正式面试",
        "Generating...": "正在生成...",
        "Generating mock interview questions from your role, JD, and selected knowledge bases.": "正在根据你的岗位、JD 和选中的知识库生成模拟面试题。",
        "History Type": "历史类型",
        "Improvement Suggestions": "改进建议",
        "Interview Evaluation": "面试评估",
        "Interview Setup": "面试设置",
        "Interviewer": "面试官",
        "Interviewer Language": "面试官语言",
        "Interviewer Speech Language": "面试官语音语言",
        "Mock": "模拟",
        "Mock Interview": "模拟面试",
        "Mock Interview Complete": "模拟面试完成",
        "Mock Interview Failed": "模拟面试启动失败",
        "Mock Interview Options": "模拟面试设置",
        "Mock Interviewer Language": "模拟面试官语言",
        "No feedback yet.": "还没有反馈。",
        "Pick one project from your background. What problem did you solve and what was your personal contribution?": "从你的经历中选一个项目。你解决了什么问题？你的个人贡献是什么？",
        "Project Deep Dive": "项目深挖",
        "questions": "题",
        "Role Fit": "岗位匹配",
        "Score": "得分",
        "Start Another Mock Interview": "再来一场模拟面试",
        "Start Mock Interview from Home": "从主页开始模拟面试",
        "Start Mock Interview": "开始模拟面试",
        "Start Recording": "开始录音",
        "Stop Recording": "停止录音",
        "Fill in the role, job description, model, and knowledge bases on the Home page, then click Mock Interview.": "请先在主页填写岗位、JD、模型和知识库，然后点击模拟面试。",
        "Strengths": "表现优势",
        "Submit Answer": "提交回答",
        "Submit Interview": "提交面试",
        "Suggested Answer": "参考优化答案",
        "Tell me about yourself and why this role fits your experience.": "请介绍一下你自己，以及为什么这个岗位适合你的经历。",
        "What strengths would you bring to this position, and what evidence supports them?": "你会给这个岗位带来哪些优势？有什么经历可以证明？",
        "Your Answer": "你的回答",
        "Evaluation complete.": "评估已完成。",
        "The evaluation was generated, but its format could not be parsed. Please try another mock interview.": "评估已生成，但格式无法解析。建议重新进行一次模拟面试。",
        "Completed the mock interview with recorded answers.": "完成了整场模拟面试，并留下了可复盘的回答记录。",
        "The answers provide material for follow-up coaching and formal interview personalization.": "你的回答已经可以作为后续训练和正式面试个性化回答的素材。",
        "Maintained continuity across multiple interview questions.": "能够连续完成多道追问，说明表达耐力和准备度已经有基础。",
        "Use the STAR structure to make each answer easier to evaluate.": "用 STAR 结构组织回答，让面试官更容易判断情境、行动和结果。",
        "Add concrete metrics, trade-offs, and personal contribution for each project example.": "每个项目例子补充具体指标、取舍过程和你的个人贡献。",
        "Prepare one concise closing sentence that connects your experience to the target role.": "准备一句简洁收尾，把经历明确连接到目标岗位。",
        "Your answer has been recorded.": "你的回答已记录。",
        "Strengthen it by adding context, your specific action, measurable result, and one reflection tied to the role.": "建议补充背景、你的具体行动、可衡量结果，以及和岗位相关的一句复盘。",
        "For this question, keep your original example but restructure it:": "这题可以保留你原来的例子，但重新组织为：",
        "first state the situation and goal, then name your personal decision, explain the trade-off, quantify the result, and end by connecting the learning to": "先说明情境和目标，再讲你的个人决策，解释取舍，量化结果，最后把收获连接到",
        "this role": "这个岗位",
        "Export Evaluation PDF": "导出评估 PDF",
        "Mock Interview Evaluation": "模拟面试评估",
        "Question Review": "问答记录",
        "Created At": "创建时间",
        "Job Role": "岗位",
        "Overall Score": "总分",
        "AI Improvement Suggestion": "AI 改进建议",
        "PDF export failed.": "PDF 导出失败。",
        "Your calm interview copilot.": "你的冷静面试助手。",
        "Allow microphone and speech-recognition access in System Settings first.": "请先在系统设置中允许麦克风和语音识别权限。",
        "API Key (optional for Ollama)": "API Key（Ollama 可留空）",
        "Changing the location copies your existing data safely. Restart the app once to begin using the new folder; the previous database is removed after the new copy is available.": "更改位置时会安全复制现有数据。重新启动应用后将使用新文件夹，并在确认新副本可用后删除旧数据库。",
        "Choose Folder": "选择文件夹",
        "Clear All Data": "清空全部数据",
        "Clear Local Data": "清空本地数据",
        "Configure speech recognition and the LLM separately. Credentials stay in the local Keychain, and requests go directly to the selected provider.": "语音识别与 LLM 分开配置。所有凭证只保存在本机钥匙串，请求直接发送给对应服务商。",
        "Could not change the storage location: %@": "无法更改存储位置：%@",
        "Could not clear local data: %@": "无法清空本地数据：%@",
        "Data Storage": "数据存储",
        "Delete Previous Screenshot": "删除上一张截图",
        "Direct connection": "直接连接",
        "Doubao Streaming Speech 2.0 · Concurrent": "豆包流式语音 2.0 · 并发版",
        "Doubao Streaming Speech 2.0 · Hourly": "豆包流式语音 2.0 · 小时版",
        "Get this from the app details in the Doubao Voice console": "从豆包语音控制台的应用信息中获取",
        "Hide Prompter During Screen Sharing": "屏幕共享时隐藏提示板",
        "Interview history, knowledge bases, and screenshots are stored together in this folder.": "历史记录、知识库和截图统一保存在这个文件夹中。",
        "Interview history, knowledge bases, and screenshots were deleted.": "历史记录、知识库和截图已删除。",
        "Local only": "仅本地",
        "Open Folder": "打开文件夹",
        "Recognition Engine": "识别引擎",
        "Recognition Model": "识别模型",
        "Request Permission": "请求权限",
        "Screen Recording Permission Granted": "屏幕录制权限已开启",
        "Screen Recording Permission Not Granted": "尚未获得屏幕录制权限",
        "Screenshot Incomplete": "截图未完成",
        "Speech Recognition": "语音识别",
        "Storage": "存储",
        "Storage Location": "存储位置",
        "Streaming Speech 1.0 · Hourly": "流式语音 1.0 · 小时版",
        "The 2.0 hourly plan is recommended. Create an app in the Doubao Voice console, enable the matching model, then copy its App ID and Access Token.": "推荐选择 2.0 小时版。请先在豆包语音控制台创建应用并开通对应模型，然后复制该应用的 App ID 和 Access Token。",
        "The API key stays in the local Keychain and is never uploaded to an InterviewAssistant service. Ollama usually needs no key.": "API Key 只保存在本机钥匙串，不会上传到 InterviewAssistant 服务。Ollama 通常无需 Key。",
        "This folder already contains InterviewAssistant data. Choose another folder to avoid overwriting it.": "该文件夹中已有 InterviewAssistant 数据。请选择其他文件夹，避免覆盖现有数据。",
        "This is already the current storage location.": "这已经是当前存储位置。",
        "This permanently deletes all interview history, knowledge bases, and saved screenshots. API keys and app preferences are not affected.": "这会永久删除所有面试历史、知识库和已保存截图，但不会影响 API Key 和应用偏好设置。",
        "Upload File": "上传文件",
        "Used to transcribe the interviewer in real time. Doubao requires an App ID and Access Token; Apple on-device recognition requires no credentials.": "用于实时识别面试官语音。豆包语音识别使用 App ID 与 Access Token；Apple 本地识别无需凭证。",
        "View Doubao streaming speech documentation": "查看豆包双向流式语音识别文档",
        "When enabled, the prompter is hidden from screenshots and screen sharing.": "开启后，提示板不会出现在截图或屏幕共享画面中。",
        "Your data was copied successfully. Quit and reopen InterviewAssistant to use the new storage location.": "数据已成功复制。请完全退出并重新打开 InterviewAssistant，以使用新的存储位置。",
        "%d screenshots captured": "已获取 %d 张截图",
        "✅ Apple on-device speech recognition is available.": "✅ Apple 本地语音识别可以使用。",
        "✅ Connection successful: connected directly to %@": "✅ 连接成功：已直接连接到 %@",
        "A suggestion could not be generated. Try again later or capture a clearer question region.": "暂时无法生成建议。请稍后重试，或重新截取更清晰的题目区域。",
        "Apple On-Device Recognition": "Apple 本地识别",
        "Code": "代码",
        "Code generation failed. Try another language or try again.": "代码生成失败，请换一种语言或重试。",
        "Connection timed out": "连接超时",
        "Detecting...": "检测中...",
        "Disable this knowledge base": "关闭该知识库",
        "Doubao Speech Recognition 2.0": "豆包语音识别 2.0",
        "Doubao Voice %d: %@": "豆包语音 %d：%@",
        "Doubao Voice connection failed: %@": "豆包语音连接失败：%@",
        "Doubao Voice connection failed. Check the App ID, Access Token, and model access.": "豆包语音连接失败，请检查 App ID、Access Token 和模型权限。",
        "Doubao Voice handshake failed (%@). The selected plan is %@. Confirm that the same plan is enabled for this App ID and that the Access Token belongs to the same app.": "豆包语音握手失败（%@）。当前选择的是%@，请确认控制台为这个 App ID 开通了相同版本，并检查 Access Token 是否属于同一个应用。",
        "Doubao speech recognition is unavailable. Switching to Apple on-device recognition...": "豆包语音暂不可用，正在切换 Apple 本地识别...",
        "Drag to select a screenshot region  |  ESC to cancel": "拖动选择截图区域  |  ESC 取消",
        "Enable this knowledge base": "开启该知识库",
        "Enter the Doubao Voice App ID and Access Token in API settings first": "请先在 API 配置中填写豆包语音 App ID 和 Access Token",
        "Enter the Doubao Voice App ID and Access Token first.": "请先填写豆包语音 App ID 和 Access Token。",
        "Enter the Doubao Voice App ID and Access Token.": "请填写豆包语音 App ID 和 Access Token。",
        "File imported": "文件已导入",
        "File imported, but no readable text was found": "文件已导入，但没有找到可读取的文本",
        "Generating code...": "代码生成中...",
        "InterviewAssistant does not have Screen & System Audio Recording access, or macOS denied the request: %@. Enable the current version in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app.": "InterviewAssistant 没有屏幕与系统音频录制权限，或 macOS 拒绝了当前捕获请求：%@。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中启用当前版本，然后完全退出并重新打开应用。",
        "Microphone and speech-recognition permission required": "需要麦克风和语音识别权限",
        "Microphone permission required": "需要麦克风权限",
        "Neither Doubao nor Apple on-device speech recognition could start": "豆包语音和 Apple 本地识别都未能启动",
        "No clear question was recognized. Try capturing a larger region.": "没有识别到清晰题目，可以重新截取更大的区域。",
        "No content suitable for analysis was extracted from the company website.": "没有从公司网站提取到可供分析的内容。",
        "No display was found, so system audio cannot be captured.": "未找到显示器，无法捕获系统音频。",
        "OCR failed: %@": "OCR 识别失败：%@",
        "Screen-recording permission is required. Allow InterviewAssistant in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app.": "需要屏幕录制权限。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 InterviewAssistant，然后完全退出并重新打开应用。",
        "Screenshot failed: %@. If macOS denied this version, enable InterviewAssistant in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app.": "截图失败：%@。如果 macOS 拒绝了当前版本，请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中启用 InterviewAssistant，然后完全退出并重新打开应用。",
        "Starting Doubao speech recognition...": "正在启动豆包语音识别...",
        "System audio is available only on macOS": "系统声音仅支持 macOS",
        "System-audio capture was interrupted: %@": "系统音频捕获中断：%@",
        "The current AI provider did not return company information.": "当前 AI 服务未返回公司资料。",
        "The current microphone has no available audio input. Check the input device in Zoom/Teams and System Settings.": "当前麦克风设备没有可用的音频输入，请检查 Zoom/Teams 与系统声音设置中的输入设备。",
        "The Doubao Voice endpoint is invalid.": "豆包语音接口地址无效。",
        "The server closed the connection (%d)": "服务端关闭连接（%d）",
        "The server closed the connection: %@": "服务端关闭连接：%@",
        "The server returned an unknown error": "服务端返回未知错误",
        "The Volcano ASR response could not be parsed": "火山 ASR 返回无法解析",
        "Unable to encode the initialization request": "无法编码初始化请求",
        "Unable to save credentials: %@ (%d)": "无法保存凭证：%@（%d）",
        "Unknown handshake error": "未知握手错误",
        "Volcano ASR connection failed: %@": "火山 ASR 连接失败：%@",
        "Volcano ASR error %d: %@": "火山 ASR 错误 %d：%@",
        "Volcano ASR error: %d": "火山 ASR 错误：%d",
        "concurrent plan": "并发版",
        "hourly plan": "小时版",
        "⚠️ Doubao Voice disconnected: %@": "⚠️ 豆包语音连接断开：%@",
        "⚠️ The microphone changed. Reconnecting…": "⚠️ 麦克风设备已变化，正在重新连接…",
        "⚠️ The system-audio route changed. Reconnecting…": "⚠️ 系统音频通道已变化，正在重新连接…",
        "🎙 Listening...": "🎙 监听中...",
        "🎙 Listening with Doubao Voice...": "🎙 豆包语音监听中...",
        "🎙 Using Apple on-device recognition (Doubao failed to start: %@)": "🎙 Apple 本地识别中（豆包语音启动失败：%@）",
        "🔊 Listening to system audio with Doubao Voice...": "🔊 豆包语音系统声音监听中...",
        "🔊 Listening to system audio...": "🔊 系统声音监听中...",
        "🔍 Transcribing...": "🔍 识别中...",
        "🔗 Doubao Voice connected": "🔗 豆包语音已连接",
        "🔴 Doubao Voice is transcribing system audio...": "🔴 豆包语音正在识别系统声音...",
        "🔴 Recording with Doubao Voice...": "🔴 豆包语音录音中...",
        "🔴 Recording...": "🔴 录音中...",
        "❌ Unable to capture system audio: %@": "❌ 无法捕获系统音频：%@",
        "✅ Doubao Voice connection successful.": "✅ 豆包语音连接成功。",
        "connected": "已连接"
    ]
}

extension Color {
    static var appBG: Color { AppThemeMode.current == .dark ? Color(hex: "#0B1020") : Color(hex: "#F9FAFC") }
    static var appPanel: Color { AppThemeMode.current == .dark ? Color(hex: "#111827") : Color(hex: "#FFFFFF") }
    static var appSurface: Color { AppThemeMode.current == .dark ? Color(hex: "#111827") : Color(hex: "#FFFFFF") }
    static var appSurfaceHover: Color { AppThemeMode.current == .dark ? Color(hex: "#1E293B") : Color(hex: "#F1F5FA") }
    static var appField: Color { AppThemeMode.current == .dark ? Color.white.opacity(0.055) : Color(hex: "#F1F5F9") }
    static var appBorder: Color { AppThemeMode.current == .dark ? Color.white.opacity(0.06) : Color(hex: "#E2E8F0") }
    static var appText: Color { AppThemeMode.current == .dark ? Color(hex: "#F8FAFC") : Color(hex: "#172033") }
    static var appMuted: Color { AppThemeMode.current == .dark ? Color(hex: "#94A3B8") : Color(hex: "#728197") }
    static var appPrimary: Color { AppThemeMode.current == .dark ? Color(hex: "#6366F1") : Color(hex: "#2F6BFF") }
    static var appPrimaryHover: Color { AppThemeMode.current == .dark ? Color(hex: "#4F46E5") : Color(hex: "#2458DA") }
    static var appGreen: Color { AppThemeMode.current == .dark ? Color(hex: "#22C55E") : Color(hex: "#20964A") }
    static var appYellow: Color { AppThemeMode.current == .dark ? Color(hex: "#F59E0B") : Color(hex: "#C47A12") }
    static var appDanger: Color { AppThemeMode.current == .dark ? Color(hex: "#EF4444") : Color(hex: "#DC2626") }
    static var appButton: Color { AppThemeMode.current == .dark ? Color.white.opacity(0.075) : Color(hex: "#EEF3F8") }
    static var appAccent: Color { Color.appPrimary }

    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

enum AppRadius {
    static let card: CGFloat = 20
    static let button: CGFloat = 16
    static let input: CGFloat = 16
    static let modal: CGFloat = 24
}

extension Font {
    static let appTitle = Font.system(size: 40, weight: .bold)
    static let appTitleCompact = Font.system(size: 32, weight: .bold)
    static let appSection = Font.system(size: 24, weight: .semibold)
    static let appBody = Font.system(size: 16)
    static let appBodyMedium = Font.system(size: 16, weight: .medium)
    static let appCaption = Font.system(size: 14)
    static let appCaptionMedium = Font.system(size: 14, weight: .medium)
    static let appSmall = Font.system(size: 12)
}

struct PremiumCardModifier: ViewModifier {
    var radius: CGFloat = AppRadius.card
    var padding: CGFloat = 20
    var hover: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill((hover ? Color.appSurfaceHover : Color.appSurface).opacity(AppThemeMode.current == .dark ? 0.82 : 0.96))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(AppThemeMode.current == .dark ? 0.08 : 0.52), Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Color.appBorder, lineWidth: 1)
                    }
                    .shadow(color: Color(hex: "#52677A").opacity(AppThemeMode.current == .dark ? 0.35 : 0.10), radius: 28, x: 0, y: 12)
            }
    }
}

struct DarkFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.appBody)
            .foregroundStyle(Color.appText)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.appField)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous))
    }
}

enum AppButtonKind {
    case primary
    case secondary
    case ghost
}

struct AppButtonStyle: ButtonStyle {
    var prominent = false
    var kind: AppButtonKind?

    func makeBody(configuration: Configuration) -> some View {
        let resolved = kind ?? (prominent ? AppButtonKind.primary : AppButtonKind.secondary)

        configuration.label
            .font(.appCaptionMedium)
            .foregroundStyle(foreground(for: resolved))
            .padding(.horizontal, 18)
            .frame(minHeight: 46)
            .background(background(for: resolved, pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.button, style: .continuous))
            .opacity(configuration.isPressed ? 0.84 : 1)
    }

    private func foreground(for kind: AppButtonKind) -> Color {
        switch kind {
        case .primary: return Color.white
        case .secondary, .ghost: return Color.appText
        }
    }

    @ViewBuilder
    private func background(for kind: AppButtonKind, pressed: Bool) -> some View {
        switch kind {
        case .primary:
            (pressed ? Color.appPrimaryHover : Color.appPrimary)
        case .secondary:
            (pressed ? Color.appSurfaceHover : Color.appButton)
        case .ghost:
            Color.clear
        }
    }
}

struct StatusPill: View {
    let text: String
    var tint: Color = .appPrimary

    var body: some View {
        Text(text)
            .font(.appSmall.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct PremiumMenuPicker: View {
    @Binding var selection: String
    let options: [(value: String, label: String)]
    var minWidth: CGFloat = 160

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(selectedLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appText)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.appMuted)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: minWidth, minHeight: 40)
            .background(controlBackground)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? selection
    }

    private var controlBackground: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(
                LinearGradient(
                    colors: AppThemeMode.current == .dark
                        ? [Color(hex: "#263247"), Color(hex: "#182131")]
                        : [Color.white, Color(hex: "#F3F6FB")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(
                        AppThemeMode.current == .dark
                            ? Color.white.opacity(0.10)
                            : Color(hex: "#D9E2EE"),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: Color.black.opacity(AppThemeMode.current == .dark ? 0.20 : 0.07),
                radius: 8,
                x: 0,
                y: 3
            )
    }
}

struct PremiumSegmentedPicker: View {
    @Binding var selection: String
    let options: [(value: String, label: String)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(.system(size: 14, weight: option.value == selection ? .semibold : .medium))
                        .foregroundStyle(option.value == selection ? Color.white : Color.appText.opacity(0.78))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .padding(.horizontal, 10)
                        .background {
                            if option.value == selection {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.appPrimary, Color(hex: "#4F8CFF")],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .shadow(color: Color.appPrimary.opacity(0.22), radius: 6, x: 0, y: 3)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppThemeMode.current == .dark ? Color(hex: "#182131") : Color(hex: "#F2F5FA"))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.appBorder.opacity(0.9), lineWidth: 1)
                }
        }
    }
}

extension View {
    func darkField() -> some View {
        modifier(DarkFieldModifier())
    }

    func premiumCard(radius: CGFloat = AppRadius.card, padding: CGFloat = 20, hover: Bool = false) -> some View {
        modifier(PremiumCardModifier(radius: radius, padding: padding, hover: hover))
    }

    @ViewBuilder
    func appInsetGroupedListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.plain)
        #endif
    }
}
