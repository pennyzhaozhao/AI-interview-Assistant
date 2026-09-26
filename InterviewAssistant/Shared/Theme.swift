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
        "Waiting for interview question": "等待面试问题",
        "Waiting for interview question...": "等待面试问题...",
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
