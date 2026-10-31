# InterviewAssistant for Windows

Native Windows client for InterviewAssistant. It uses C#, WPF and modern .NET while preserving the product behaviour and visual language of the existing Apple client.

## Requirements

- Windows 11
- Visual Studio Community 2026 with the **.NET desktop development** workload
- .NET 10 SDK

## Build

Open `InterviewAssistant.Windows.sln` in Visual Studio, or run from PowerShell:

```powershell
dotnet restore .\InterviewAssistant.Windows.sln
dotnet build .\InterviewAssistant.Windows.sln
dotnet run --project .\src\InterviewAssistant.App\InterviewAssistant.App.csproj
```

Do not select the legacy `.NET Framework` WPF toolchain. This project targets modern `net10.0-windows`.

## Implemented foundation

- Native WPF application and Visual Studio solution
- Dark Interview AI design tokens and reusable controls
- Custom Windows title bar and collapsible sidebar
- Interview, Director, Knowledge Base, History and Settings pages
- Dependency-free MVVM infrastructure
- A Windows prompter prototype that is topmost and non-activating
- Capture exclusion request using `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`
- Persistent workspace drafts, knowledge bases and interview history in `%LOCALAPPDATA%\InterviewAssistant\Data`
- Per-provider AI configuration with API keys stored in Windows Credential Manager
- Real connection testing for OpenAI-compatible, Claude and Gemini APIs
- Director controller TCP client compatible with the Apple newline-delimited JSON packet protocol
- Functional knowledge-base creation, editing, enablement and material editing

## Next platform milestones

1. Verify the prompter on physical Windows hardware and common meeting apps.
2. Implement the Director Host TCP/HTTP listener and browser controller.
3. Implement WASAPI loopback and microphone capture.
4. Implement region selection, `Windows.Graphics.Capture` and OCR.
5. Port AI response streaming, Volcano ASR and speaker verification.
6. Add mock interviews, document import and JSON import/export compatibility.

Keep Windows-only code in this directory. The existing Swift and SwiftUI application remains the Apple client.
