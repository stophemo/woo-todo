#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef IconPath
  #error IconPath is required
#endif

[Setup]
AppId={{B64B8A7B-A289-4B46-B6AB-F28B39E7D40A}
AppName=Woo Todo
AppVersion={#AppVersion}
AppPublisher=stophemo
AppPublisherURL=https://github.com/stophemo/woo-todo
AppSupportURL=https://github.com/stophemo/woo-todo/issues
DefaultDirName={localappdata}\Programs\Woo Todo
DefaultGroupName=Woo Todo
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#OutputDir}
OutputBaseFilename=Woo-Todo-v{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\WooTodo.exe
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName=Woo Todo
VersionInfoDescription=无我待办 Windows 安装程序
SetupIconFile={#IconPath}

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\Unofficial\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务："; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Woo Todo"; Filename: "{app}\WooTodo.exe"; AppUserModelID: "stophemo.WooTodo"
Name: "{autodesktop}\Woo Todo"; Filename: "{app}\WooTodo.exe"; Tasks: desktopicon; AppUserModelID: "stophemo.WooTodo"

[Registry]
Root: HKCU; Subkey: "Software\Classes\wootodo"; ValueType: string; ValueData: "URL:Woo Todo Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\wootodo"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\wootodo\DefaultIcon"; ValueType: string; ValueData: """{app}\WooTodo.exe"",0"
Root: HKCU; Subkey: "Software\Classes\wootodo\shell\open\command"; ValueType: string; ValueData: """{app}\WooTodo.exe"" --uri ""%1"""

[Run]
Filename: "{app}\WooTodo.exe"; Description: "启动 Woo Todo"; Flags: nowait postinstall skipifsilent
