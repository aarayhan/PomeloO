; PomeloO installer (Inno Setup 6). Built by scripts\build.ps1 -Installer from dist\PomeloO.
; Per-user install: no admin rights, nothing system-wide, a clean uninstall.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define Dist "..\dist\PomeloO"

[Setup]
AppId={{8C1E6B5A-3F2D-4E77-9B1A-5D0C2F7E9A41}
AppName=PomeloO
AppVersion={#AppVersion}
AppVerName=PomeloO {#AppVersion}
AppPublisher=PomeloO contributors
AppPublisherURL=https://github.com/aarayhan/PomeloO
AppSupportURL=https://github.com/aarayhan/PomeloO/issues
AppUpdatesURL=https://github.com/aarayhan/PomeloO/releases
DefaultDirName={localappdata}\Programs\PomeloO
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\dist
OutputBaseFilename=PomeloO-Setup-{#AppVersion}
SetupIconFile=..\assets\pomeloo.ico
UninstallDisplayIcon={app}\PomeloO.exe
UninstallDisplayName=PomeloO
LicenseFile=..\LICENSE
Compression=lzma2/max
SolidCompression=yes
LZMANumBlockThreads=4
WizardStyle=modern
; the tray app holds its files open: close it for upgrades and uninstalls
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "explorermenu"; Description: "Add PomeloO to the right-click menu in Explorer"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "{#Dist}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\PomeloO"; Filename: "{app}\PomeloO.exe"
Name: "{autodesktop}\PomeloO"; Filename: "{app}\PomeloO.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\PomeloO.exe"; Parameters: "--register"; Flags: runhidden waituntilterminated; Tasks: explorermenu; StatusMsg: "Adding the right-click menu..."
Filename: "{app}\PomeloO.exe"; Description: "Start PomeloO now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM PomeloO.exe"; Flags: runhidden; RunOnceId: "StopApp"
Filename: "{app}\PomeloO.exe"; Parameters: "--unregister"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveMenu"

[Registry]
; the app writes its own start-with-Windows entry; the uninstaller removes it
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "PomeloO"; ValueType: none; Flags: uninsdeletevalue

[UninstallDelete]
; the private LibreOffice engine (if it was downloaded) and its profile; settings in %APPDATA% stay
Type: filesandordirs; Name: "{localappdata}\PomeloO"
