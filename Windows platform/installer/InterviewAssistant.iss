; Interview AI — Windows installer (Inno Setup 6).
;
; Per-user install (no administrator rights) into %LocalAppData%\Programs\Interview AI,
; Start menu shortcut, optional desktop shortcut, entry in Settings → Apps with uninstall.
; Installing a newer Setup over an existing install upgrades it in place; user data lives in
; %LocalAppData%\InterviewAssistant and is never touched by install or uninstall.
;
; Built by .github/workflows/windows-release.yml:
;   ISCC.exe /DAppVersion=1.2.0 /DSourceExe=path\to\InterviewAssistant.exe /O<out> InterviewAssistant.iss
;
; The in-app updater runs the downloaded Setup with:
;   /SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /updatedfrom=<old version>
; and the [Run] entry below reopens the app afterwards.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceExe
  #define SourceExe "..\publish\InterviewAssistant.exe"
#endif

#define AppName "Interview AI"
#define AppExeName "InterviewAssistant.exe"
#define AppPublisher "pennyzhaozhao"
#define AppUrl "https://github.com/pennyzhaozhao/AI-interview-Assistant"

[Setup]
; Never change AppId: it identifies the installation for upgrades and uninstall.
AppId={{EC308F5A-D1CC-44C5-9628-732C20199D6E}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
SetupIconFile=..\src\InterviewAssistant.App\Assets\InterviewAssistant.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
OutputBaseFilename=InterviewAssistant-{#AppVersion}-Windows-x64-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
ShowLanguageDialog=auto
UsePreviousLanguage=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "zh"; MessagesFile: "ChineseSimplified.isl"

[CustomMessages]
en.LaunchApp=Launch {#AppName}
zh.LaunchApp=启动 {#AppName}

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; DestName: "{#AppExeName}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
; Interactive install: "Launch Interview AI" checkbox on the last page.
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent
; In-app update (silent): reopen the app and let it show "Update successful".
Filename: "{app}\{#AppExeName}"; Parameters: "--updated-from ""{param:updatedfrom|}"""; Flags: nowait; Check: IsInAppUpdate

[Code]
function IsInAppUpdate: Boolean;
begin
  Result := WizardSilent and (ExpandConstant('{param:updatedfrom|}') <> '');
end;
