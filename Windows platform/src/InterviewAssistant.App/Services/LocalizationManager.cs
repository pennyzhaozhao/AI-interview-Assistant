using System.ComponentModel;
using System.Globalization;
using System.Windows.Data;
using System.Windows.Markup;

namespace InterviewAssistant.Services;

public sealed class LocalizationManager : INotifyPropertyChanged
{
    private static readonly IReadOnlyDictionary<string, string> EnglishAliases = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["HomeRoleDescription"] = "Shape the interview around the exact opportunity.",
        ["HomeCompanyDescription"] = "Record the website, business, compensation structure, and company understanding you may be asked about in interviews.",
        ["KnowledgeEditDescription"] = "Edit metadata, import sources, and decide whether this asset is available to interviews.",
        ["StorageDescription"] = "Interview history, knowledge bases, and screenshots are stored together in this folder.",
        ["AboutDescription"] = "Version, support, and app information",
        ["Your calm interview copilot."] = "Your calm interview copilot.",
        ["EditSourceDescription"] = "Edit the source title and full text. Changes are saved locally.",
        ["ScreenshotModeDescription"] = "Choose whether screenshots use a preset region for silent capture during interviews.",
        ["PresetRegionDescription"] = "Set the region before the interview, then capture silently without stealing focus.",
        ["ManualRegionDescription"] = "Select an area manually each time. This can briefly move focus away from the interview.",
        ["RegionSetupHint"] = "Set the region before the interview starts so capturing does not affect the interview window.",
        ["WebsiteBlockedMessage"] = "The website refused automated access (HTTP {0}), usually because of bot protection. Try another company page (home or About page), or paste the company introduction into the notes",
        ["VoiceprintPrivacyNote"] = "Voiceprints are biometric data. They are encrypted on this device with Windows Data Protection and never uploaded."
    };

    private static readonly IReadOnlyDictionary<string, string> Chinese = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["Interview"] = "面试", ["Director Mode"] = "导演模式", ["Knowledge Base"] = "知识库", ["History"] = "历史", ["Settings"] = "设置",
        ["Interview AI"] = "Interview AI", ["Practice smarter. Ace your next interview."] = "更聪明地练习，拿下下一场面试。",
        ["Start Interview"] = "开始面试", ["Mock Interview"] = "模拟面试", ["Choose Knowledge"] = "选择知识库",
        ["Microphone"] = "麦克风", ["System Audio"] = "扬声器", ["Muted"] = "静音", ["Choose code language"] = "选择代码语言",
        ["Role"] = "角色", ["Target role"] = "目标岗位", ["Job description"] = "职位描述", ["Company Introduction"] = "公司介绍",
        ["Company Name"] = "公司名称", ["Company Website"] = "公司官网", ["Company Notes"] = "公司备注", ["Parse Website"] = "解析网站",
        ["Add a target role before starting."] = "请先填写目标岗位。", ["Mock interview setup is ready. The interview room is the next module."] = "模拟面试资料已就绪，下一步将进入面试房间。",
        ["Generating mock interview questions…"] = "正在生成模拟面试题…", ["Generating…"] = "正在生成…", ["Answer with your own voice. AI asks, records, and evaluates after the interview."] = "用自己的声音回答。AI 负责提问、录音转写，并在结束后评估。",
        ["Generating mock interview questions from your role, JD, and selected knowledge bases."] = "正在根据岗位、职位描述和选中的知识库生成模拟面试题。",
        ["Interviewer"] = "面试官", ["Replay"] = "重播", ["Start Recording"] = "开始录音", ["Stop Recording"] = "停止录音", ["Ready to record"] = "可以开始录音",
        ["Submit Answer"] = "提交回答", ["Submit Interview"] = "提交面试", ["Record or type an answer first."] = "请先录制或输入回答。", ["Speech recognized"] = "语音已识别",
        ["Edit the transcript before submitting. No AI help is shown during mock interviews."] = "提交前可以编辑转写内容。模拟面试过程中不会显示 AI 回答提示。",
        ["Generating Interview Evaluation"] = "正在生成面试评估", ["AI is reviewing your answers, scoring each question, and preparing improvement suggestions."] = "AI 正在审阅回答、逐题评分并准备改进建议。",
        ["Interview Evaluation"] = "面试评估", ["Strengths"] = "优势", ["Improvement Suggestions"] = "改进建议", ["Question Review Details"] = "逐题复盘详情",
        ["Your Answer"] = "你的回答", ["AI Deep Feedback"] = "AI 深度反馈", ["Suggested Answer"] = "参考回答", ["Mock Interview Failed"] = "模拟面试启动失败", ["Retry"] = "重试", ["Close"] = "关闭",
        ["Evaluation complete."] = "评估完成。", ["Completed the mock interview with recorded answers."] = "已完成整场模拟面试并记录回答。",
        ["Use the STAR structure and add concrete evidence to every answer."] = "使用 STAR 结构，并为每个回答补充具体证据。", ["Add clearer context, your specific actions, and measurable results."] = "补充更清晰的背景、你的具体行动和可衡量结果。",
        ["Rewrite this answer with Situation, Task, Action, and Result, then connect it to the target role."] = "按照情境、任务、行动和结果重写回答，并与目标岗位建立联系。",
        ["Enter a valid company website first."] = "请先输入有效的公司网址。", ["Reading company website…"] = "正在读取公司网站…",
        ["Company website content was added to your notes."] = "公司网站内容已添加到备注。", ["Website could not be read: {0}"] = "无法读取网站：{0}",
        ["Interview workspace for {0} is ready."] = "{0} 的面试工作区已准备好。", ["Interview workspace is ready."] = "面试工作区已准备好。",
        ["HomeRoleDescription"] = "围绕具体岗位定制本次面试。",
        ["HomeCompanyDescription"] = "记录官网、业务、薪资架构和面试中可能被问到的公司理解。",
        ["Manage reusable context as enabled assets for interview sessions."] = "管理可复用的面试上下文资料。",
        ["Search knowledge"] = "搜索知识库", ["Select"] = "选择", ["Cancel"] = "取消", ["Select All"] = "全选", ["Delete Selected"] = "删除所选",
        ["New Asset"] = "新建资料", ["Enabled"] = "开启", ["Off"] = "关闭", ["No knowledge bases yet."] = "还没有知识库。",
        ["Select or create a knowledge base to edit its details."] = "选择或新建知识库以编辑详情。",
        ["Enabled for interviews"] = "用于面试", ["AI will prioritize this asset when answering."] = "AI 回答时会优先参考这份资料。",
        ["Title"] = "标题", ["Description"] = "描述", ["Import source"] = "导入来源", ["Import"] = "导入", ["Upload File"] = "上传文件",
        ["Sources"] = "来源", ["Add Main Content"] = "添加主要内容", ["Main Content"] = "主要内容", ["Edit Source"] = "编辑来源",
        ["Source title"] = "来源标题", ["Content"] = "内容", ["Save"] = "保存", ["Saving…"] = "正在保存…", ["Saved"] = "已保存",
        ["EditSourceDescription"] = "编辑来源标题和完整文字，修改将保存在本机。",
        ["KnowledgeEditDescription"] = "编辑元数据、导入来源，并决定这份资料是否用于面试。",
        ["Choose which materials AI can use during interviews."] = "选择面试期间 AI 可以使用的材料。",
        ["Review formal and mock interview sessions stored on this device."] = "查看过往面试对话和结果。",
        ["History Type"] = "历史类型", ["Formal Interview"] = "正式面试", ["Search history"] = "搜索历史",
        ["Conversation"] = "会话", ["Select a session to inspect the interview flow."] = "选择一个会话来查看面试流程。", ["No interview history yet."] = "还没有面试历史。",
        ["Summary"] = "总结", ["Question"] = "问题", ["Answer"] = "回答", ["No summary yet"] = "暂无总结",
        ["Language"] = "语言", ["Mode"] = "模式", ["Storage Location"] = "存储位置", ["Choose folder"] = "选择文件夹", ["Open folder"] = "打开文件夹", ["Clear all data"] = "清空全部数据",
        ["Mock Interviewer Language"] = "模拟面试官语言", ["Interviewer Speech Language"] = "面试官语音语言", ["API Configure"] = "API 配置",
        ["Screenshot Hotkey"] = "截图快捷键", ["Screenshot OCR"] = "截图识别", ["Screenshot Mode"] = "截图模式", ["Set Up Voices"] = "设置声纹", ["About"] = "关于",
        ["ScreenshotModeDescription"] = "选择面试中截图是否使用预设区域静默捕获。",
        ["Preset Region Screenshot"] = "预设区域截图", ["Manual Selection Screenshot"] = "手动框选截图",
        ["PresetRegionDescription"] = "提前设置截图区域，面试中可静默截图，不影响窗口焦点。",
        ["ManualRegionDescription"] = "每次手动框选区域，可能导致面试窗口短暂失焦。",
        ["Screen capture is available"] = "屏幕截图功能可用", ["Screenshot region set"] = "截图区域已设置", ["Screenshot region not set"] = "未设置截图区域",
        ["Set Region"] = "设置区域", ["Reset"] = "重新设置", ["RegionSetupHint"] = "建议在面试开始前设置好区域，面试中直接截图，不影响面试窗口焦点。",
        ["Follow app language"] = "跟随 App 语言", ["English"] = "英文", ["APPEARANCE"] = "外观", ["DATA STORAGE"] = "数据存储",
        ["StorageDescription"] = "历史记录、知识库和截图统一保存在这个文件夹中。",
        ["Changing the location copies your existing data safely. Restart the app once to begin using the new folder."] = "更改位置时会安全复制现有数据。重启应用后开始使用新文件夹。",
        ["Hide prompter during screen sharing"] = "屏幕共享时隐藏提示板", ["Hide Interview AI from the taskbar during interviews"] = "面试期间从任务栏隐藏 Interview AI",
        ["AboutDescription"] = "版本、支持与应用信息", ["ABOUT"] = "关于", ["Your calm interview copilot."] = "你的冷静面试助手。",
        ["Version"] = "版本", ["Build"] = "构建版本", ["Platform"] = "平台", ["Storage"] = "存储", ["Local only"] = "仅本地",
        ["Check for Updates..."] = "检查更新…", ["Checking for Updates..."] = "正在检查更新…", ["Contacting GitHub Releases..."] = "正在连接 GitHub Releases…",
        ["Version {0} is available"] = "发现新版本 {0}", ["InterviewAssistant {0} is the latest version."] = "InterviewAssistant {0} 已是最新版本。",
        ["InterviewAssistant {0} is installed."] = "当前已安装 InterviewAssistant {0}。", ["Unable to Check for Updates"] = "无法检查更新。",
        ["Download Update"] = "下载更新", ["Update Available"] = "发现更新", ["Would you like to open the download now?"] = "是否立即打开下载页面？",
        ["Privacy Policy"] = "隐私政策", ["Terms of Service"] = "服务条款",
        ["Host a prompt board or connect as a controller"] = "开启提示板，或作为控制端连接", ["Start"] = "开始", ["Connect"] = "连接", ["Clear"] = "清空", ["Send"] = "发送",
        ["API Configuration"] = "API 配置", ["Configure speech recognition and the LLM separately. Credentials stay on this device, and requests go directly to the selected provider."] = "语音识别与 LLM 分开配置。所有凭证仅保存在本机，请求直接发送给对应服务商。",
        ["Speech Recognition"] = "语音识别", ["Used to transcribe the interviewer in real time. Volcano requires an App ID and Access Token; Windows on-device recognition requires no credentials."] = "用于实时识别面试官语音。豆包语音识别使用 App ID 与 Access Token；Windows 本地识别无需凭证。",
        ["Recognition Engine"] = "识别引擎", ["Recognition Model"] = "识别模型", ["Test Connection"] = "测试连接", ["Provider"] = "服务商", ["Select where responses should be generated."] = "选择回答由哪个服务生成。",
        ["Model"] = "模型", ["Current model"] = "当前模型", ["Choose a supported model or enter a custom model identifier."] = "选择支持的模型，或输入自定义模型标识。", ["Connection"] = "连接", ["The API key is kept in Windows Credential Manager and is sent only to the selected provider."] = "API Key 保存在 Windows 凭据管理器中，仅发送给所选服务商。",
        ["SPEAKER RECOGNITION"] = "声纹识别",
        ["The 2.0 hourly plan is recommended. Create an app in the Volcano console and enable the matching model."] = "推荐选择 2.0 小时版。请在豆包语音控制台创建应用并开通对应模型。",
        ["YOUR IP ADDRESS"] = "你的 IP 地址", ["ENTER HOST IP ADDRESS"] = "输入 HOST IP 地址", ["WEB CONTROLLER"] = "网页控制端", ["Scan to send without the app"] = "扫码即可发送，无需安装 App",
        ["Waiting for host connection"] = "等待 Host 连接",
        ["The Host prompt board must be running on the same Wi-Fi."] = "Host 提示板需要在同一 Wi-Fi 下运行。", ["Controller address QR"] = "网页控制端已就绪", ["QUESTION"] = "问题", ["Host prompt board status"] = "Host 提示板状态",
        ["Waiting for the Host to hear or capture a question"] = "等待 Host 听到或截取题目", ["SEND MARKDOWN CONTENT"] = "发送 MARKDOWN 内容", ["Supports headings, lists, code blocks and links"] = "支持标题、列表、代码块和链接",
        // Mock interview + About page wording aligned with the macOS app.
        ["End Interview"] = "结束面试", ["Score"] = "得分", ["Start Another Mock Interview"] = "再来一场模拟面试",
        ["Strengths"] = "表现优势", ["Question Review Details"] = "问答记录详情", ["Your Answer"] = "你的回答",
        ["AI Deep Feedback"] = "AI 深度评价", ["Suggested Answer"] = "参考优化答案", ["No feedback yet."] = "暂无评估。",
        ["Edit the transcript before submitting. No AI help is shown during mock interviews."] = "提交前可以编辑语音转写稿。模拟面试过程中不会显示 AI 帮助回答。",
        ["You're up to date"] = "已是最新版本", ["A newer version is ready to download."] = "新版本已可下载。",
        ["Check your internet connection and try again."] = "请检查网络连接后重试。", ["Unable to Check for Updates"] = "无法检查更新",
        ["Release Notes"] = "更新说明",
        // Voices (speaker recognition), wording from the macOS app.
        ["OK"] = "好",
        ["Later"] = "稍后",
        ["Delete"] = "删除",
        ["Done"] = "完成",
        ["More"] = "更多",
        ["Voice"] = "声音",
        ["Voices"] = "声音",
        ["None"] = "无",
        ["Active"] = "正在使用",
        ["Available"] = "可用",
        ["Choose the voice that belongs to you during an interview."] = "选择面试时代表你的声音；选择“无”可关闭识别。",
        ["Turn off voice recognition"] = "关闭说话人识别",
        ["Add Voice…"] = "添加声音…",
        ["Rename Voice"] = "重命名声音",
        ["Voice Name"] = "声音名称",
        ["Enter a name that will help you recognize this voice."] = "输入一个便于辨认的声音名称。",
        ["Delete Voice"] = "删除声音",
        ["This removes the voiceprint from this device."] = "这会从本机删除该声纹。",
        ["Voice recognition is off."] = "说话人识别已关闭。",
        ["Active voice updated."] = "已切换当前声音。",
        ["Recognition Sensitivity"] = "识别灵敏度",
        ["Higher sensitivity is stricter when deciding whether a speaker is you."] = "灵敏度越高，判断说话人是否为你时越严格。",
        ["VoiceprintPrivacyNote"] = "声纹属于生物特征数据，会使用 Windows 数据保护加密保存在本机，绝不会上传。",
        ["Add a Voice"] = "添加声音",
        ["Voice Added"] = "声音已添加",
        ["This voice is now selected for speaker recognition."] = "此声音已设为当前识别声音。",
        ["Speak naturally using the microphone and room you normally use for interviews."] = "请使用平时面试的麦克风和环境自然说话。",
        ["Start Voice Setup"] = "开始设置声音",
        ["Processing…"] = "正在处理…",
        ["Voice setup is complete."] = "声音设置完成。",
        ["Downloading..."] = "正在下载…",
        ["Download Speaker Model (28.3 MB)"] = "下载声纹模型（28.3 MB）",
        ["Downloading the on-device speaker model..."] = "正在下载端侧声纹模型…",
        ["Speaker model downloaded and verified"] = "声纹模型已下载并校验",
        ["Read this passage for about 15 seconds using the same microphone and room you will use for interviews."] = "请使用面试时相同的麦克风和环境，朗读这段文字约 15 秒。",
        ["Recording..."] = "正在录音…",
        ["Keep speaking naturally until recording finishes."] = "请自然朗读，直到录音结束。",
        ["No voice profile is enrolled"] = "尚未注册声纹",
        ["Record at least three voice samples"] = "请至少录制三段声音样本",
        ["The voice sample was too short or unclear"] = "声音样本太短或不够清晰",
        ["Download the speaker model first"] = "请先下载声纹模型",
        ["The downloaded speaker model failed verification"] = "下载的声纹模型校验失败",
        ["Speaker Recognition"] = "说话人识别",
        // Company website research (macOS wording).
        ["Parsing the company website and generating a research summary..."] = "正在解析公司官网并生成调研摘要…",
        ["Website research summary (please review manually):"] = "官网调研摘要（请人工核对）：",
        ["Company research summary generated. Please review it quickly before the interview."] = "已生成公司调研摘要，面试前请快速核对一遍。",
        ["Parsing failed: {0}. You can fill in the company notes manually."] = "解析失败：{0}。你可以手动填写公司备注。",
        ["No content suitable for analysis was extracted from the company website."] = "没有从公司官网提取到可用于分析的内容。",
        ["The current AI provider did not return company information."] = "当前 AI 服务没有返回公司信息。",
        ["Source returned HTTP {0}"] = "网站返回 HTTP {0}",
        ["WebsiteBlockedMessage"] = "该网站拒绝了程序访问（HTTP {0}），通常是网站开启了反爬虫保护。可以换成公司的其他页面（如官网首页、About 页面），或把公司介绍直接粘贴到公司备注里",
        ["Enter a valid company website first."] = "请先输入有效的公司官网地址。"
    };

    public static LocalizationManager Instance { get; } = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? LanguageChanged;
    public bool IsChinese { get; private set; }
    public string this[string key]
    {
        get
        {
            if (IsChinese && Chinese.TryGetValue(key, out var chinese)) return chinese;
            return EnglishAliases.TryGetValue(key, out var english) ? english : key;
        }
    }

    public static string Text(string key) => Instance[key];

    public static void Apply(string language)
    {
        var chinese = language.StartsWith("zh", StringComparison.OrdinalIgnoreCase) || language == "简体中文";
        if (Instance.IsChinese == chinese) return;
        Instance.IsChinese = chinese;
        CultureInfo.CurrentUICulture = chinese ? CultureInfo.GetCultureInfo("zh-Hans") : CultureInfo.GetCultureInfo("en");
        Instance.PropertyChanged?.Invoke(Instance, new PropertyChangedEventArgs("Item[]"));
        Instance.LanguageChanged?.Invoke();
    }
}

[MarkupExtensionReturnType(typeof(object))]
public sealed class LocExtension : MarkupExtension
{
    public string Key { get; set; } = "";

    public override object ProvideValue(IServiceProvider serviceProvider) =>
        new Binding($"[{Key}]") { Source = LocalizationManager.Instance, Mode = BindingMode.OneWay }
            .ProvideValue(serviceProvider);
}
