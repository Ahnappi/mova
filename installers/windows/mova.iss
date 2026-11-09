; Inno Setup 脚本：为 mova 生成 Windows 安装程序。
;
; 编译方式（CI 与本地一致）：
;   iscc installers\windows\mova.iss /DMyAppVersion=1.0.3
;
; MyAppVersion 建议由构建方从 pubspec.yaml 的 version 取出来传入，
; 这样 exe 资源里的版本号、安装程序版本号、「应用和功能」里显示的
; 版本号三者永远一致。不传则用下面这个兜底值。
;
; windows-latest 这个 GitHub Runner 预装了 Inno Setup，
; CI 里直接 iscc 即可，不需要额外安装步骤。

#ifndef MyAppVersion
  #define MyAppVersion "1.0.1"
#endif

; CI 会传成 mova_win_x64_setup，好跟其它产物对齐命名。
#ifndef MyOutputBaseFilename
  #define MyOutputBaseFilename "mova_setup"
#endif

#define MyAppName "mova"
#define MyAppPublisher "Ahnappi"
#define MyAppURL "https://github.com/Ahnappi/mova"
#define MyAppExeName "mova.exe"

[Setup]
; AppId 必须是固定的 GUID：它决定「应用和功能」里把这个安装识别为
; 同一个应用。改了它，新版本会被当成另一个软件装一份，而不是升级。
AppId={{534659BE-9BF5-4D36-AF67-774466396BEA}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
VersionInfoVersion={#MyAppVersion}

; {autopf} = Program Files（64 位系统上是 Program Files，不是 x86）。
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}

; 卸载条目：这两行决定「设置 → 应用和功能」里显示成什么样。
UninstallDisplayName={#MyAppName} {#MyAppVersion}
UninstallDisplayIcon={app}\{#MyAppExeName}

; 输出。路径相对于本脚本所在目录（installers\windows\）。
OutputDir=..\..\dist
OutputBaseFilename={#MyOutputBaseFilename}

; 装到 Program Files 需要管理员权限，这是 Windows 的规矩。
; 加这一行允许用 /NORESTART 之类参数覆盖，方便自动化部署。
PrivilegesRequiredOverridesAllowed=dialog

; 覆盖旧版本：ignoreversion 让新版本直接替换，不做版本号比较。
; 没有它，升级时会因文件版本相同而被跳过。
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
WizardResizable=yes

; 只在 64 位 Windows 上以 64 位模式安装（mova 只出 x64 包）。
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; 覆盖安装时若 mova 正在运行，自动关掉它，而不是留一堆文件占用错误。
CloseApplications=yes
RestartApplications=no

[Languages]
; 中文用**仓库里**的语言文件（installers\windows\Languages\ChineseSimplified.isl）：
; 中文不是 Inno Setup 的默认语言，编译器自带的 Languages 目录有没有它，
; 取决于装的是完整版还是精简版、装到哪台机器上。用它就等同于把「这台
; CI 机器正好装了中文包」当前提——换个 Runner 就编不过（或直接退回英文）。
; 英文仍用编译器自带的 Default.isl，它一定存在，不必复制一份进仓库。
Name: "chinesesimplified"; MessagesFile: "Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"; Flags: unchecked

[Files]
; Release 目录里除了 exe，还有 flutter_windows.dll、data\（Flutter 资源）
; 以及 media_kit 的 mpv 相关 dll，必须整目录带走。
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; \
    Description: "{cm:LaunchProgram,{#MyAppName}}"; \
    Flags: nowait postinstall skipifsilent

[Code]
// 卸载收尾：询问要不要连本地数据一起删。
//
// 默认**不删**——传输历史和设置是用户的数据，正经软件不会在卸载时
// 悄悄抹掉。这里做成一次明确的选择，并把路径摊给用户看。
//
// 顺带检查 com.example 那个旧目录：早期版本用模板默认的
// CompanyName="com.example"，数据落在 %APPDATA%\com.example\mova。
// 换到 Ahnappi 之后旧目录就没人管了，借卸载的时机给它一次清理机会。
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  CurrentDir: String;
  LegacyDir: String;
  Prompt: String;
begin
  if CurUninstallStep <> usPostUninstall then
    exit;

  CurrentDir := ExpandConstant('{userappdata}\Ahnappi\mova');
  LegacyDir  := ExpandConstant('{userappdata}\com.example\mova');
  Prompt := '';

  if DirExists(CurrentDir) then
    Prompt := Prompt + CurrentDir + #13#10;
  if DirExists(LegacyDir) then
    Prompt := Prompt + LegacyDir + '（旧版本留下的）' + #13#10;

  if Prompt <> '' then
  begin
    if MsgBox('是否删除 mova 的本地数据（传输历史与设置）？' + #13#10 + #13#10 +
              Prompt + #13#10 + '选「否」则保留这些数据，下次安装还能接着用。',
              mbConfirmation, MB_YESNO) = IDYES then
    begin
      if DirExists(CurrentDir) then
        DelTree(CurrentDir, True, True, True);
      if DirExists(LegacyDir) then
        DelTree(LegacyDir, True, True, True);
    end;
  end;
end;
