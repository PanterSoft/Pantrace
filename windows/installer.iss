; Built by CI: iscc /DAppVersion=1.2.3 /DArch=x64 windows\installer.iss
; Arch is x64 or arm64 and picks both the Flutter build output and the
; architectures the installer accepts.
#ifndef Arch
  #define Arch "x64"
#endif

[Setup]
AppName=Pantrace
AppVersion={#AppVersion}
AppPublisher=PanterSoft
AppPublisherURL=https://github.com/PanterSoft/Pantrace
DefaultDirName={autopf}\Pantrace
DefaultGroupName=Pantrace
PrivilegesRequired=lowest
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
OutputDir=..
OutputBaseFilename=Pantrace-windows-{#Arch}-setup
Compression=lzma2
SolidCompression=yes

[Tasks]
Name: desktopicon; Description: "Create a &desktop icon"; Flags: unchecked

[Files]
Source: "..\build\windows\{#Arch}\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\Pantrace"; Filename: "{app}\pantrace.exe"
Name: "{autodesktop}\Pantrace"; Filename: "{app}\pantrace.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\pantrace.exe"; Description: "Launch Pantrace"; Flags: nowait postinstall skipifsilent
