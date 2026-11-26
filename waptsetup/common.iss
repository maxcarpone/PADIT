#ifndef edition
#error "Preprocessor variable edition must be defined"
#endif

#include "wapt.iss"

#define ssl_dir AddBackslash(SourcePath)+'ssl'

[InstallDelete]
#ifndef FastDebug
#ifndef waptenterprise
Type: filesandordirs; Name: "{app}\waptenterprise"; Check: CleanAgentRuntime()
#endif
#endif

[Files]
; sources of installer to rebuild a custom installer (ignoreversion because issc has no version)

#if edition != "waptstarter"

#ifndef FastDebug
Source: "{#wapt_base_dir}waptsetup\innosetup\*"; DestDir: "{app}\waptsetup\innosetup"; Flags: createallsubdirs recursesubdirs ignoreversion skipifsourcedoesntexist;
#endif

#if edition == "waptsetup"
Source: "{#wapt_base_dir}utils\signtool.exe"; DestDir: "{app}\utils"; Flags: ignoreversion;
#endif

Source: "{#wapt_base_dir}waptsetup\common.iss"; DestDir: "{app}\waptsetup";
Source: "{#wapt_base_dir}waptsetup\wapt.iss"; DestDir: "{app}\waptsetup";
Source: "{#wapt_base_dir}waptsetup\waptsetup.iss"; DestDir: "{app}\waptsetup";
Source: "{#wapt_base_dir}waptsetup\waptagent.iss"; DestDir: "{app}\waptsetup";
Source: "{#wapt_base_dir}waptsetup\services.iss"; DestDir: "{app}\waptsetup";
Source: "{#wapt_base_dir}wapt.ico"; DestDir: "{app}";

; sources to regenerate waptupgrade package
Source: "{#wapt_base_dir}waptupgrade\setup.py"; DestDir: "{app}\waptupgrade"; Flags: ignoreversion;
Source: "{#wapt_base_dir}waptupgrade\WAPT\*"; DestDir: "{app}\waptupgrade\WAPT"; Flags: createallsubdirs recursesubdirs ignoreversion skipifsourcedoesntexist;

; global management console
Source: "{#wapt_base_dir}waptconsole.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#wapt_base_dir}waptconsole.exe.manifest"; DestDir: "{app}";

Source: "{#wapt_base_dir}waptdevutils.py"; DestDir: "{app}";

#if edition == "waptsetup"
#ifndef waptenterprise
Source: "{#wapt_base_dir}wapttransition.exe"; DestDir: "{app}"; Flags: ignoreversion;
#endif
#endif
#endif

; authorized public keys
#if set_install_certs == ""
Source: "{#ssl_dir}\*"; DestDir: "{app}\ssl"; Tasks: installCertificates; Check: ClassicInstall(); Flags: createallsubdirs recursesubdirs skipifsourcedoesntexist
#else
Source: "{#ssl_dir}\*"; DestDir: "{app}\ssl"; Flags: createallsubdirs recursesubdirs skipifsourcedoesntexist; Check: ClassicInstall() and InstallCertCheck();
#endif

; local management console wapt selfservice
Source: "{#wapt_base_dir}waptself.exe"; DestDir: "{app}"; Flags: ignoreversion;  BeforeInstall: killtask('waptself.exe');

Source: "{#wapt_base_dir}waptmessage.exe"; DestDir: "{app}"; Flags: ignoreversion;  BeforeInstall: killtask('waptmessage.exe');


Source: "{param:CopyPackagesTrustedCA}"; DestDir: "{app}\ssl"; Flags: external createallsubdirs recursesubdirs; Check: ClassicInstall() and CopyPackagesTrustedCACheck();
Source: "{param:CopyServersTrustedCA}"; DestDir: "{app}\ssl\server"; Flags: external createallsubdirs recursesubdirs; Check: ClassicInstall() and CopyServersTrustedCACheck();

[Setup]
#ifdef waptenterprise
OutputBaseFilename={#edition}
#else
OutputBaseFilename={#edition}
#endif
#if edition == 'waptserversetup' 
DefaultDirName=c:\wapt
#else
DefaultDirName={commonpf32}\wapt
#endif

#if edition != 'waptagent' 
WizardImageFile={#wapt_base_dir}tranquilit.bmp
#endif

DisableProgramGroupPage=yes

[Languages]
Name:"en"; MessagesFile: "compiler:Default.isl"
Name:"fr";MessagesFile: "compiler:Languages\French.isl"
Name:"de";MessagesFile: "compiler:Languages\German.isl"

[Tasks]
#if edition != "waptserversetup"
Name: DisableHiberboot; Description: "{cm:DisableHiberBoot}"; GroupDescription: "{cm:Advanced}";
#endif

#if set_install_certs == ""
Name: InstallCertificates; Description: "{cm:InstallSSLCertificates}";  GroupDescription: "{cm:Advanced}"; Flags: unchecked;
#endif

#if use_random_uuid  == ""
Name: UseRandomUUID; Description: "{cm:UseRandomUUID}";  GroupDescription: "{cm:Advanced}"; Flags: unchecked;
#endif

Name: InstallStartPackages; Description: "{cm:InstallStartPackages}";  GroupDescription: "{cm:Advanced}";  Check: StartPackagesCheck();

#if set_verify_cert == ""
Name: VerifyServerCertificates; Description: "{cm:VerifyServerCertificates}";  GroupDescription: "{cm:Advanced}";
#endif

#if set_use_kerberos == ""
Name: UseKerberos; Description: "{cm:UseKerberosForRegister}";  GroupDescription: "{cm:Advanced}";
#endif

[INI]
#if edition != "waptserversetup"
Filename: {app}\wapt-get.ini; Section: global; Key: repo_url; String: {code:GetRepoURL}; Check: ClassicInstall() and MustChangeServerConfig;
#endif
Filename: {app}\wapt-get.ini; Section: global; Key: send_usage_report; String:  {#send_usage_report}; Check: ClassicInstall()

#if edition != "waptstarter"
Filename: {app}\wapt-get.ini; Section: global; Key: use_hostpackages; String: 1; Check: ClassicInstall()
  #if edition != "waptserversetup"
Filename: {app}\wapt-get.ini; Section: global; Key: wapt_server; String: {code:GetWaptServerURL}; Check: ClassicInstall() and MustChangeServerConfig;
  #endif

  #if set_use_kerberos == ''
Filename: {app}\wapt-get.ini; Section: global; Key: use_kerberos; String: {code:UseKerberosCheck}; Check: ClassicInstall()
  #else
Filename: {app}\wapt-get.ini; Section: global; Key: use_kerberos; String: {#set_use_kerberos}; Check: ClassicInstall()
  #endif
#endif

Filename: {app}\wapt-get.ini; Section: global; Key: check_certificates_validity; String: {#check_certificates_validity}; Check: ClassicInstall()

; needs to be relocated if waptagent is compiled on another base directory than target computers
#if set_verify_cert != ""
Filename: {app}\wapt-get.ini; Section: global; Key: verify_cert; String: {code:RelocateCertDirWaptBase}; Check: ClassicInstall()
#else
Filename: {app}\wapt-get.ini; Section: global; Key: verify_cert; String: {code:VerifyCertCheck}; Check: ClassicInstall()
#endif

#if use_fqdn_as_uuid != ""
Filename: {app}\wapt-get.ini; Section: global; Key: use_fqdn_as_uuid; String: {#use_fqdn_as_uuid}; Check: ClassicInstall()
#endif

#if use_ad_groups != ""
Filename: {app}\wapt-get.ini; Section: global; Key: use_ad_groups; String: {#use_ad_groups}; Check: ClassicInstall()
#endif

#if use_repo_rules != ""
Filename: {app}\wapt-get.ini; Section: global; Key: use_repo_rules; String: {#use_repo_rules}; Check: ClassicInstall()
#endif

#if waptservice_admin_filter != ""
Filename: {app}\wapt-get.ini; Section: global; Key: waptservice_admin_filter; String: {#waptservice_admin_filter}; Check: ClassicInstall()
#endif

#if maturities != ""
Filename: {app}\wapt-get.ini; Section: global; Key: maturities; String: {#maturities}; Check: ClassicInstall()
#endif

Filename: {app}\wapt-get.ini; Section: global; Key: uuid; String: {code:GenerateHostUUID}; Check: ClassicInstall() and MustChangeHostUUID;

#if edition != "waptserversetup"
Filename: {app}\wapt-get.ini; Section: global; Key: max_gpo_script_wait; String: 180; Tasks: DisableHiberboot; Check: ClassicInstall()
Filename: {app}\wapt-get.ini; Section: global; Key: pre_shutdown_timeout; String: 180; Tasks: DisableHiberboot; Check: ClassicInstall()
Filename: {app}\wapt-get.ini; Section: global; Key: hiberboot_enabled; String: {code:Gethiberboot_enabled}; Check: ClassicInstall()

  #if append_host_profiles != ""
Filename: {app}\wapt-get.ini; Section: global; Key: host_profiles; String: {code:GetHostProfiles}; Check: ClassicInstall()
  #endif

  #if set_waptaudit_task_period != ""
Filename: {app}\wapt-get.ini; Section: global; Key: waptaudit_task_period; String: {code:GetWaptauditTaskPeriod}; Check: ClassicInstall()
  #endif

  ; WaptWUA specific settings
  #ifdef waptwua
    #if set_waptwua_enabled != ""
Filename: {app}\wapt-get.ini; Section: waptwua; Key: enabled; String: {#set_waptwua_enabled}; Check: ClassicInstall()
    #endif

    #if set_waptwua_default_allow != ""
Filename: {app}\wapt-get.ini; Section: waptwua; Key: default_allow; String: {#set_waptwua_default_allow}; Check: ClassicInstall()
    #endif

    #if set_waptwua_offline != ""
Filename: {app}\wapt-get.ini; Section: waptwua; Key: offline; String: {#set_waptwua_offline}; Check: ClassicInstall()
    #endif
    
    #if set_waptwua_install_at_shutdown != ""
Filename: {app}\wapt-get.ini; Section: waptwua; Key: install_at_shutdown; String: {#set_waptwua_install_at_shutdown}; Check: ClassicInstall()
    #endif

    #if set_waptwua_allow_direct_download != ""
Filename: {app}\wapt-get.ini; Section: waptwua; Key: allow_direct_download; String: {#set_waptwua_allow_direct_download}; Check: ClassicInstall()
    #endif
    
    #if set_waptwua_install_delay != ""
Filename: {app}\wapt-get.ini; Section: waptwua; Key: install_delay; String: {#set_waptwua_install_delay}; Check: ClassicInstall()
    #endif
    
    #if set_waptwua_download_scheduling != ""
Filename: {app}\wapt-get.ini; Section: waptwua; Key: download_scheduling; String: {#set_waptwua_download_scheduling}; Check: ClassicInstall()
    #endif

  #endif
#endif


[Run]
#if edition != "waptserversetup"
Filename: "{app}\wapt-get.exe"; Parameters: "add-upgrade-shutdown"; Flags: runhidden; StatusMsg: {cm:UpdatePkgUponShutdown}; Description: "{cm:UpdatePkgUponShutdown}"; Check: ClassicInstall()

#if edition != "waptstarter"
Filename: "{app}\wapt-get.exe"; Parameters: "--use-gui --direct register"; Flags: runhidden; StatusMsg: {cm:RegisterHostOnServer}; Description: "{cm:RegisterHostOnServer}"; Check: ClassicInstall()
#endif

#if set_start_packages != "" 
Filename: "{app}\wapt-get.exe"; Parameters: "--direct --update-packages install {code:GetStartPackages}"; Tasks: installStartPackages; StatusMsg: {cm:InstallStartPackages}; Description: "{cm:InstallStartPackages} {code:GetStartPackages}"; Check: ClassicInstall()
#else
Filename: "{app}\wapt-get.exe"; Parameters: "--direct update"; Flags: runhidden; StatusMsg: {cm:UpdateAvailablePkg}; Description: "{cm:UpdateAvailablePkg}"; Check: ClassicInstall()
#endif

#endif

[Icons]
Name: "{commonstartup}\PADIT session setup"; Filename: "{app}\wapt-get.exe"; Parameters: "session-setup ALL"; Flags: runminimized excludefromshowinnewinstall; Check: ClassicInstall()

#if edition != "waptstarter"
Name: "{group}\{cm:WAPTConsole}"; Filename: "{app}\waptconsole.exe"; WorkingDir: "{app}"; Check: ClassicInstall() and Not IsWaptAgent();
#endif

Name: "{group}\{cm:WAPTSelf}"; Filename: "{app}\waptself.exe"; WorkingDir: "{app}"; Check: ClassicInstall()

[CustomMessages]
;English translations here
en.StartAfterSetup=Launch PADIT setup session upon session opening
en.RegisterHostOnServer=Register this computer onto PADIT server
en.UpdateAvailablePkg=Update the list of packages available on the main repository
en.UpdatePkgUponShutdown=Update packages upon shutdown                                   
en.EnableCheckCertificate=Get and enable the check of PADIT server https certificate
en.UseWaptServer=Report computer status to a PADIT server and enable remote management
en.InstallSSLCertificates=Install the certificates provided by this installer
en.InstallStartPackages=Install right now the packages {#set_start_packages}
en.UseKerberosForRegister=Use machine kerberos account for registration on PADIT server
en.VerifyServerCertificates=Verify https server certificates
en.DisableHiberBoot=Disable hiberboot, and increase shudown GPO timeout (recommended)
en.RemoveAllFiles=Do you want to delete all remaining files in PADIT installation directory {app} ?
en.UseWizard=Use Wizard to complete initial configuration steps
en.DontChangeServerSetup=Don't change current setup
en.StaticURLS=Static PADIT information
en.RunConfigTool=Run congifuration tool
en.WAPTConsole=PADIT Management console
en.WAPTSelf=PADIT Software self service
en.UseRandomUUID=Use a random UUID to identify the computer instead of BIOS
en.InstallationOptions=Installation options
en.RepoURL=Repository URL:
en.ServerURL=Server URL:
en.Example=Example
en.Advanced=Advanced

;French translations here
fr.StartAfterSetup=Lancer PADIT session setup à l'ouverture de session
fr.RegisterHostOnServer=Enregistre l'ordinateur sur le serveur PADIT
fr.UpdateAvailablePkg=Mise à jour des paquets disponibles sur le dépôt principal
fr.UpdatePkgUponShutdown=Mise à jour des paquets à l'extinction du poste
fr.EnableCheckCertificate=Activer la vérification du certificat https du serveur PADIT
fr.UseWaptServer=Activer l'utilisation d'un serveur PADIT et la gestion centralisée de cet ordinateur
fr.InstallSSLCertificates=Installer les certificats fournis par cet installeur.
fr.InstallStartPackages=Installer maintenant les paquets {#set_start_packages}
fr.UseKerberosForRegister=Utiliser le compte Kerberos de la machine pour l'enregistrement sur le serveur PADIT
fr.VerifyServerCertificates=Vérifier les certificats https
fr.DisableHiberBoot=Désactiver l'hiberboot, et augmenter le temps pour les GPO (recommandé)
fr.RemoveAllFiles=Des fichiers restent présents dans votre répertoire {app} Souhaitez-vous le supprimer ainsi que tous les fichiers qu'il contient ?
fr.UseWizard=Utiliser l'assistant pour achever la phase de configuration initiale.
fr.DontChangeServerSetup=Ne pas modifier la configuration actuelle
fr.StaticURLS=URLS PADIT statiques
fr.RunConfigTool=Exécuter l'assistant de configuration
fr.WAPTConsole=Console PADIT
fr.WAPTSelf=Self service logiciels PADIT
fr.UseRandomUUID=Utiliser un UUID aléatoire pour identifier l'ordinateur au lieu du BIOS
fr.InstallationOptions=Options d'installation
fr.RepoURL=URL du dépôt :
fr.ServerURL=URL du serveur :
fr.Example=Exemple
fr.Advanced=Avancé

;German translation here
de.StartAfterSetup=PADIT Setup-Sitzung bei Sitzungseröffnung starten
de.RegisterHostOnServer=Diesen Computer auf PADIT Server speichern
de.UpdateAvailablePkg=Liste der verfügbaren Pakete auf Main Repostitory aktualisieren
de.UpdatePkgUponShutdown=Packete aktualisieren beim herunterfahren
de.RunConfigTool=Führen Sie das Konfigurationstool aus
de.EnableCheckCertificate=Pruefung des HTTPS-Zertifikats des PADIT-Servers aktivieren
de.UseWaptServer=Computerstatus an einen PADIT-Server melden und Fernverwaltung aktivieren
de.InstallSSLCertificates=Die mit diesem Installationsprogramm bereitgestellten Zertifikate installieren
de.InstallStartPackages=Die Pakete {#set_start_packages} jetzt installieren
de.UseKerberosForRegister=Computerkonto fuer die Kerberos-Registrierung am PADIT-Server verwenden
de.VerifyServerCertificates=HTTPS-Serverzertifikate ueberpruefen
de.DisableHiberBoot=Schnellstart deaktivieren und Zeitlimit fuer Gruppenrichtlinien beim Herunterfahren erhoehen (empfohlen)
de.RemoveAllFiles=Alle verbleibenden Dateien im PADIT-Installationsverzeichnis {app} loeschen?
de.UseWizard=Assistenten zum Abschluss der Erstkonfiguration verwenden
de.DontChangeServerSetup=Aktuelle Konfiguration nicht aendern
de.StaticURLS=Statische PADIT-Verbindungsadressen
de.WAPTConsole=PADIT-Verwaltungskonsole
de.WAPTSelf=PADIT-Software-Selbstbedienung
de.UseRandomUUID=Zufaellige UUID anstelle der BIOS-Kennung zur Identifizierung des Computers verwenden
de.InstallationOptions=Installationsoptionen
de.RepoURL=Paketrepository-URL:
de.ServerURL=Server-URL:
de.Example=Beispiel
de.Advanced=Erweitert

[Code]
var
  RuntimeCleanupApproved: Boolean;
  cbDontChangeConfig, cbStaticUrl: TNewRadioButton;
  CustomPage: TWizardPage;
  edWaptServerUrl:TEdit;
  labRepo,labRepoExample,labServer,labServerExample: TLabel;

procedure OnServerClicked(Sender:TObject);
begin
   #if edition != "waptstarter"
   edWaptServerUrl.Enabled:= cbStaticUrl.Checked;
   labServer.Enabled:=cbStaticUrl.Checked;
   labServerExample.Enabled:=cbStaticUrl.Checked;
   #endif
   labRepo.Enabled:=cbStaticUrl.Checked;
   labRepoExample.Enabled:=cbStaticUrl.Checked;
   edWaptRepoUrl.Enabled:= cbStaticUrl.Checked;
end;

#if edition != "waptserversetup"
function GetRepoURL(Param:String):String;
begin
  if edWaptRepoUrl.Text <> 'unknown' then
    result := edWaptRepoUrl.Text
  else
  begin
    result := ExpandConstant('{param:repo_url|unknown}');
    if result='unknown' then
    begin
        result := '{#repo_url}';
        if result = '' then
            result := GetIniString('Global', 'repo_url','{#default_repo_url}', ExpandConstant('{app}\wapt-get.ini'))
    end;
  end;
end;

function GetWaptServerURL(Param: String):String;
begin
  if edWaptServerUrl.Text <> 'unknown' then
    result := edWaptServerUrl.Text
  else
  begin
    result := ExpandConstant('{param:wapt_server|unknown}');
    if result='unknown' then
    begin
      result := '{#wapt_server}';
      if result = '' then
        result := GetIniString('Global', 'wapt_server','{#default_wapt_server}', ExpandConstant('{app}\wapt-get.ini'));
    end;
  end;
end;
#endif

procedure RemoveWaptServer();
begin
  DeleteIniEntry('Global','wapt_server',ExpandConstant('{app}\wapt-get.ini'));
end;

procedure RemoveInstallDir();
var
  installdir: String;
  msg       : String;
  b         : boolean;
begin
  installdir := ExpandConstant('{app}');
  if not DirExists(installdir) then
    exit;

  msg := ExpandConstant('{cm:RemoveAllFiles}');
  msg := ExpandConstant( msg );
  b := ExpandConstant('{param:purge_wapt_dir|0}') = '1';
  b := b or (not runningSilently() and  (MsgBox(msg, mbConfirmation, MB_YESNO) = IDYES) );  // No need to ask if purge_wapt_dir is setted
  if b then
    Deltree(installdir, True, True, True);
end;



#if edition != "waptserversetup"
procedure InitializeWizard;
begin
  CustomPage := CreateCustomPage(wpSelectTasks, ExpandConstant('{cm:InstallationOptions}'), '');
  
  cbDontChangeConfig := TNewRadioButton.Create(WizardForm);
  cbDontChangeConfig.Parent := CustomPage.Surface;
  cbDontChangeConfig.Width := CustomPage.SurfaceWidth;
  cbDontChangeConfig.Caption := ExpandConstant('{cm:DontChangeServerSetup}');
  cbDontChangeConfig.Onclick := @OnServerClicked;

  cbStaticUrl := TNewRadioButton.Create(WizardForm);
  cbStaticUrl.Parent := CustomPage.Surface; 
  cbStaticUrl.Caption := ExpandConstant('{cm:StaticURLS}');
  cbStaticUrl.Width := CustomPage.SurfaceWidth;
  cbStaticUrl.Top := cbDontChangeConfig.Top + cbDontChangeConfig.Height + 5;
  cbStaticUrl.Onclick := @OnServerClicked;

  labRepo := TLabel.Create(WizardForm);
  labRepo.Parent := CustomPage.Surface; 
  labRepo.Left := cbStaticUrl.Left + 15;
  labRepo.Caption := ExpandConstant('{cm:RepoURL}');
  labRepo.Top := cbStaticUrl.Top + cbStaticUrl.Height + 5;

  edWaptRepoUrl := TEdit.Create(WizardForm);
  edWaptRepoUrl.Parent := CustomPage.Surface; 
  edWaptRepoUrl.Left := labRepo.Left + labRepo.Width + 5;
  edWaptRepoUrl.Width := CustomPage.SurfaceWidth - labRepo.Width - (labRepo.Left * 2);
  edWaptRepoUrl.Top := labRepo.Top;
  edWaptRepoUrl.text := 'unknown';

  labRepoExample := TLabel.Create(WizardForm);
  labRepoExample.Parent := CustomPage.Surface; 
  labRepoExample.Left := edWaptRepoUrl.Left;
  labRepoExample.Caption := ExpandConstant('{cm:Example}')+': https://srvwapt.domain.lan/wapt';
  labRepoExample.Top := edWaptRepoUrl.Top + edWaptRepoUrl.Height + 3;

  #if edition != "waptstarter"
  labServer := TLabel.Create(WizardForm);
  labServer.Parent := CustomPage.Surface; 
  labServer.Left := cbStaticUrl.Left + 15; 
  labServer.Caption := ExpandConstant('{cm:ServerURL}');
  labServer.Top := labRepoExample.Top + labRepoExample.Height + 5;
  
  edWaptServerUrl := TEdit.Create(WizardForm);;
  edWaptServerUrl.Parent := CustomPage.Surface; 
  edWaptServerUrl.Left :=labServer.Left + labServer.Width+5;
  edWaptServerUrl.Width := CustomPage.SurfaceWidth - labServer.Width - (labServer.Left * 2);
  edWaptServerUrl.Top := labServer.Top; 
  edWaptServerUrl.Text := 'unknown';  

  labServerExample := TLabel.Create(WizardForm);
  labServerExample.Parent := CustomPage.Surface; 
  labServerExample.Left := edWaptServerUrl.Left; 
  labServerExample.Caption := ExpandConstant('{cm:Example}')+': https://srvwapt.domain.lan';
  labServerExample.Top := edWaptServerUrl.Top + edWaptServerUrl.Height + 3;
  #endif
end;
#endif



procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  case CurUninstallStep of

    usPostUninstall:
      RemoveInstallDir();

  end;


end;


procedure DeinitializeUninstall();
begin
end;


function QueryTransitionServiceStatus(Handle: Longword; var Status: _SERVICE_STATUS): Longword;
  external 'QueryServiceStatus@advapi32.dll stdcall';

function TransitionFileAttributes(Path: String): Longword;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function TransitionLocalPath(const Path: String): Boolean;
var
  Current: String;
  Attr: Longword;
begin
  Result := False;
  if (Length(Path) <= 3) or (Copy(Path, 2, 2) <> ':\') or
    (CompareText(ExpandFileName(Path), Path) <> 0) or (Pos('"', Path) > 0) or
    (Pos(':', Copy(Path, 3, Length(Path))) > 0) then Exit;
  Current := Path;
  while Length(Current) > 3 do
  begin
    Attr := TransitionFileAttributes(Current);
    if (Attr = $FFFFFFFF) or ((Attr and $400) <> 0) then Exit;
    Current := ExtractFileDir(Current);
  end;
  Result := True;
end;

function TransitionWaptStopped(): Boolean;
var
  Manager, Service: Longword;
  Status: _SERVICE_STATUS;
begin
  Result := False;
  Manager := OpenSCManager('', '', SC_MANAGER_CONNECT);
  if Manager = 0 then Exit;
  try
    Service := OpenService(Manager, 'WAPTService', SERVICE_QUERY_STATUS);
    if Service = 0 then Exit;
    try
      Result := (QueryTransitionServiceStatus(Service, Status) <> 0) and
        (Status.dwCurrentState = SERVICE_STOPPED);
    finally
      CloseServiceHandle(Service);
    end;
  finally
    CloseServiceHandle(Manager);
  end;
end;

function TransitionHttpsURL(const Value: String): Boolean;
begin
  Result := (CompareText(Copy(Value, 1, 8), 'https://') = 0) and
    (Length(Value) > 8) and (Pos('@', Value) = 0) and (Pos(' ', Value) = 0) and
    (Pos('\', Value) = 0) and (Pos('"', Value) = 0) and (Pos('?', Value) = 0) and
    (Pos('#', Value) = 0) and (Pos(#13, Value) = 0) and (Pos(#10, Value) = 0);
end;

function TransitionCA(const Parameter: String): Boolean;
var
  Path: String;
  PEM: AnsiString;
begin
  Path := ExpandConstant('{param:' + Parameter + '|}');
  Result := TransitionLocalPath(Path) and FileExists(Path) and
    LoadStringFromFile(Path, PEM) and (Pos('-----BEGIN CERTIFICATE-----', PEM) = 1);
end;

function TransitionPathBelow(const Path, Root: String): Boolean;
begin
  Result := (CompareText(Path, Root) = 0) or
    (CompareText(Copy(Path, 1, Length(Root) + 1), Root + '\') = 0);
end;

function TransitionRuntimeOverlaps(const AppPath, ProtectedPath: String): Boolean;
var
  Parent, Name, LowerName: String;
begin
  Parent := ExtractFileDir(ProtectedPath);
  Name := ExtractFileName(ProtectedPath);
  LowerName := Lowercase(Name);
  Result := TransitionPathBelow(ProtectedPath, AppPath + '\lib\site-packages') or
    TransitionPathBelow(ProtectedPath, AppPath + '\waptenterprise') or
    TransitionPathBelow(AppPath + '\lib\site-packages', ProtectedPath) or
    TransitionPathBelow(AppPath + '\waptenterprise', ProtectedPath) or
    (CompareText(ProtectedPath, AppPath + '\waptservice') = 0) or
    ((CompareText(Parent, AppPath) = 0) and (Lowercase(ExtractFileExt(Name)) = '.pyc')) or
    ((CompareText(Parent, AppPath + '\waptservice') = 0) and
      ((Lowercase(ExtractFileExt(Name)) = '.pyc') or (Pos('waptservice.py', LowerName) = 1)));
end;

function RuntimePathSafe(const AppPath, WorkingDir, Value: String): Boolean;
var
  Path, Current, Part: String;
  Attr: Longword;
begin
  Result := False;
  if (Value = '') or (Pos('~', Value) > 0) or (Pos('/', Value) > 0) or
    (Pos('"', Value) > 0) or (Pos('%', Value) > 0) or (Copy(Value, 1, 1) = '\') or
    ((Pos(':', Value) > 0) and ((Copy(Value, 2, 2) <> ':\') or
      (Pos(':', Copy(Value, 4, Length(Value))) > 0))) then Exit;
  Path := Value;
  if Copy(Path, 2, 2) <> ':\' then Path := AddBackslash(WorkingDir) + Path;
  Path := RemoveBackslashUnlessRoot(ExpandFileName(Path));
  if Length(Path) <= 3 then Exit;
  Current := Path;
  while Length(Current) > 3 do
  begin
    Part := ExtractFileName(Current);
    if (Part = '') or (Part[Length(Part)] = '.') or (Part[Length(Part)] = ' ') then Exit;
    Attr := TransitionFileAttributes(Current);
    if (Attr <> $FFFFFFFF) and ((Attr and $400) <> 0) then Exit;
    Current := ExtractFileDir(Current);
  end;
  Result := not TransitionRuntimeOverlaps(AppPath, Path);
end;

function RuntimeTreeSafe(const Tree: String): Boolean;
begin
  Result := (TransitionFileAttributes(Tree) = $FFFFFFFF) or TransitionLocalPath(Tree);
end;

function TransitionRuntimeSafe(const AppPath, ConfigPath, PackagesDir, WorkingDir: String): Boolean;
var
  HTTPS, Key, Path: String;
  I: Integer;
begin
  HTTPS := Lowercase(GetIniString('global', 'verify_cert', '', ConfigPath));
  Result := (Pos('~', AppPath) = 0) and (Pos('~', WorkingDir) = 0) and
    RuntimeTreeSafe(AppPath + '\lib\site-packages') and
    RuntimeTreeSafe(AppPath + '\waptenterprise') and
    RuntimeTreeSafe(AppPath + '\waptservice') and
    RuntimePathSafe(AppPath, WorkingDir, ConfigPath) and
    RuntimePathSafe(AppPath, WorkingDir, PackagesDir) and
    RuntimePathSafe(AppPath, WorkingDir, AddBackslash(ExtractFileDir(ConfigPath)) + 'cache') and
    RuntimePathSafe(AppPath, WorkingDir, GetIniString('global', 'dbpath', AppPath + '\db\waptdb.sqlite', ConfigPath)) and
    RuntimePathSafe(AppPath, WorkingDir, GetIniString('global', 'private_dir', AppPath + '\private', ConfigPath)) and
    RuntimePathSafe(AppPath, WorkingDir, GetIniString('global', 'persistent_root_dir',
      AppPath + '\private\persistent', ConfigPath)) and
    RuntimePathSafe(AppPath, WorkingDir, GetIniString('global', 'public_certs_dir', AppPath + '\ssl', ConfigPath)) and
    ((HTTPS = '') or (HTTPS = '0') or (HTTPS = '1') or (HTTPS = 'true') or (HTTPS = 'false') or
      RuntimePathSafe(AppPath, WorkingDir, HTTPS));
  if not Result then Exit;
  for I := 0 to 2 do
  begin
    case I of
      0: Key := 'log_directory';
      1: Key := 'personal_certificate_path';
      2: Key := 'private_key';
    end;
    Path := GetIniString('global', Key, '', ConfigPath);
    if (Path <> '') and not RuntimePathSafe(AppPath, WorkingDir, Path) then
    begin
      Result := False;
      Exit;
    end;
  end;
end;

function TransitionServiceScript(const AppPath, WorkingDir, Arguments: String): Boolean;
var
  Script, Remaining: String;
  Ending: Integer;
begin
  Result := False;
  Remaining := Trim(Arguments);
  if Copy(Remaining, 1, 1) = '"' then
  begin
    Delete(Remaining, 1, 1);
    Ending := Pos('"', Remaining);
    if (Ending = 0) or ((Ending < Length(Remaining)) and
      (Remaining[Ending+1] <> ' ') and (Remaining[Ending+1] <> #9)) then Exit;
    Script := Copy(Remaining, 1, Ending - 1);
  end
  else
  begin
    Ending := 1;
    while (Ending <= Length(Remaining)) and (Remaining[Ending] <> ' ') and
      (Remaining[Ending] <> #9) do Inc(Ending);
    Script := Copy(Remaining, 1, Ending - 1);
  end;
  if (Script = '') or (Pos('~', Script) > 0) then Exit;
  if Copy(Script, 2, 2) <> ':\' then Script := AddBackslash(WorkingDir) + Script;
  Result := (CompareText(ExpandFileName(Script), AppPath + '\waptservice\service.py') = 0) and
    TransitionLocalPath(Script) and FileExists(Script);
end;

function CleanAgentRuntime(): Boolean;
begin
  Result := ClassicInstall() or
    (RuntimeCleanupApproved and (ExpandConstant('{param:TRANSITION|}') = '1') and ('{#edition}' = 'waptagent'));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  AppPath, ConfigPath, PackagesDir, WorkingDir, Application, Arguments: String;
begin
  Result := '';
  if ClassicInstall() then Exit;
  Result := 'Transition requires the supported agent installer and silent no-close/no-restart switches.';
  if (ExpandConstant('{param:TRANSITION|}') <> '1') or
    ('{#edition}' <> 'waptagent') or not runningSilently() or
    not HasSetupSwitch('/NOCLOSEAPPLICATIONS') or not HasSetupSwitch('/NORESTART') or
    HasSetupSwitch('/FORCECLOSEAPPLICATIONS') or HasSetupSwitch('/CLOSEAPPLICATIONS') or
    HasSetupSwitch('/RESTARTAPPLICATIONS') then Exit;

  AppPath := ExpandConstant('{app}');
  ConfigPath := ExpandConstant('{param:TRANSITION_INI|}');
  PackagesDir := ExpandConstant('{param:TRANSITION_PACKAGES_DIR|}');
  Result := 'Transition requires the existing agent and explicit historical configuration paths.';
  if not TransitionLocalPath(AppPath) or not FileExists(AppPath + '\wapt-get.exe') or
     not TransitionLocalPath(ConfigPath) or not FileExists(ConfigPath) or
     not TransitionLocalPath(PackagesDir) or not DirExists(PackagesDir) then Exit;

  if not RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Services\WAPTService\Parameters',
    'AppDirectory', WorkingDir) or (WorkingDir = '') then WorkingDir := AppPath;
  Result := 'Historical service must use the agent runtime and the supported service.py entry point.';
  if not TransitionLocalPath(WorkingDir) or not DirExists(WorkingDir) or
    not RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Services\WAPTService\Parameters',
      'Application', Application) or (CompareText(Application, AppPath + '\waptpython.exe') <> 0) or
    not RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Services\WAPTService\Parameters',
      'AppParameters', Arguments) or not TransitionServiceScript(AppPath, WorkingDir, Arguments) then Exit;
  Result := 'Existing INI, database, identity, trust or cache overlaps the runtime cleanup.';
  if not TransitionRuntimeSafe(AppPath, ConfigPath, PackagesDir, WorkingDir) then Exit;

  Result := 'Transition requires HTTPS endpoints and explicit server and package CA files.';
  if not TransitionHttpsURL(ExpandConstant('{param:wapt_server|}')) or
     not TransitionHttpsURL(ExpandConstant('{param:repo_url|}')) or
     not TransitionCA('verify_cert') or not TransitionCA('CopyPackagesTrustedCA') then Exit;
  Result := 'A transition CA destination already exists.';
  if (TransitionFileAttributes(AppPath + '\padit-transition-https.cabundle') <> $FFFFFFFF) or
     (TransitionFileAttributes(PackagesDir + '\padit-transition-packages.pem') <> $FFFFFFFF) then Exit;

#ifdef vcredist
  Result := 'The required VC++ redistributable must be installed before transition.';
  if not VCVersionInstalled(VC_2008_SP1_MFC_SEC_UPD_REDIST_X86) then Exit;
#endif

  Result := 'WAPTService must already be stopped by the transition engine.';
  if not TransitionWaptStopped() then Exit;
  RuntimeCleanupApproved := True;
  Result := '';
end;

procedure ApplyTransitionConfig();
var
  ConfigPath, HTTPSCA, PackageCA: String;
begin
  // Use the historical INI directly. All normal setup INI entries are disabled.
  if not TransitionWaptStopped() then RaiseException('WAPTService resumed during transition.');
  ConfigPath := ExpandConstant('{param:TRANSITION_INI|}');
  HTTPSCA := ExpandConstant('{app}\padit-transition-https.cabundle');
  PackageCA := ExpandConstant('{param:TRANSITION_PACKAGES_DIR|}') + '\padit-transition-packages.pem';
  if not FileCopy(ExpandConstant('{param:verify_cert|}'), HTTPSCA, True) or
     not FileCopy(ExpandConstant('{param:CopyPackagesTrustedCA|}'), PackageCA, True) then
    RaiseException('Cannot write transition CA files.');
  if not SetIniString('global', 'verify_cert', HTTPSCA, ConfigPath) or
     not SetIniString('global', 'wapt_server', ExpandConstant('{param:wapt_server|}'), ConfigPath) or
     not SetIniString('global', 'repo_url', ExpandConstant('{param:repo_url|}'), ConfigPath) then
    RaiseException('Cannot write transition endpoints to the historical configuration.');
end;

function InstallCertCheck:Boolean;
var
  value:String;
begin
  value := ExpandConstant('{param:InstallCerts|{#set_install_certs}}');
  Result := value <> '0';
end;

function MustChangeServerConfig:Boolean;
begin
  Result := runningSilently() or not cbDontChangeConfig.Checked;
#if edition == "waptstarter"
  // remove wapt_server entry because waptstarter must be standalone.  
  If Result then
  begin  
    DeleteIniEntry('global', 'wapt_server', ExpandConstant('{app}\wapt-get.ini'));
    DeleteIniEntry('global', 'use_hostpackages', ExpandConstant('{app}\wapt-get.ini'));
    DeleteIniEntry('global', 'use_ad_groups', ExpandConstant('{app}\wapt-get.ini'));
  end;
#endif
end;

function UseKerberosCheck(param:String):String;
begin
  if WizardIsTaskSelected('UseKerberos') then
     Result := '1'
  else
     Result := '0';
end;

function VerifyCertCheck(param:String):String;
begin
  if WizardIsTaskSelected('VerifyServerCertificates') then
     Result := '1'
  else
     Result := '0'
end;

function Gethiberboot_enabled(param:String):String;
begin
  // get supplied verify_cert from commandline, else take hardcoded in setup 
  Result := ExpandConstant('{param:DisableHiberBoot|{#set_disable_hiberboot}}');
  if Result = '' then
    if WizardIsTaskSelected('DisableHiberBoot') then
       Result := '0'
    else
       Result := '1'
end;


function GetStartPackages(Param: String):String;
begin
    // get supplied StartPackages from commandline, else take hardcoded in setup 
    result := ExpandConstant('{param:StartPackages|{#set_start_packages}}');
    if result = '*' then  
      result := '';
end;

function StartPackagesCheck:Boolean;
begin
  Result := GetStartPackages('') <> '';
end;


function IsWaptAgent:Boolean;
begin
  Result := '{#edition}' = 'waptagent';
end;

function RelocateCertDirWaptBase(Param: String):String;
var
  certdir: String;
begin
  // get supplied verify_cert from commandline, else take hardcoded in setup 
  certdir := ExpandConstant('{param:verify_cert|{#set_verify_cert}}');
  if (certdir<>'0') and (certdir<>'1') and (lowercase(certdir)<>'true') and (lowercase(certdir)<>'false') then
  begin
      if (pos('c:\tranquilit\wapt',lowercase(certdir))=1) then
        result := ExpandConstant('{app}')+'\'+copy(certdir,length('c:\tranquilit\wapt')+1,255)
      else if (pos('c:\program files (x86)\wapt',lowercase(certdir))=1) then
        result := ExpandConstant('{app}')+'\'+copy(certdir,length('c:\program files (x86)\wapt')+1,255)
      else if (pos('c:\program files\wapt\',lowercase(certdir))=1) then
        result := ExpandConstant('{app}')+'\'+copy(certdir,length('c:\program files\wapt\')+1,255)
      else if (pos('c:\wapt\',lowercase(certdir))=1) then
        result := ExpandConstant('{app}')+'\'+copy(certdir,length('c:\wapt\')+1,255)
      else if copy(certdir,2,1) <> ':' then
        // relative path to wapt base dir
        result := ExpandFileName(ExpandConstant('{app}')+'\'+certdir)
      else
        // absolute
        result := certdir;
  end
  else
    result := certdir;
  
end;

{
type
  TGuid = record
    D1: LongWord;
    D2: Word;
    D3: Word;
    D4: array[0..7] of Byte;
  end;
}

function CoCreateGuid(var Guid:TGuid):integer;
 external 'CoCreateGuid@ole32.dll stdcall';

function FormatGuid(Guid:TGuid):string;
begin
  result:=Format('%.8x-%.4x-%.4x-%.2x-%.2x-%.2x-%.2x-%.2x-%.2x-%.2x-%.2x', [Guid.D1, Guid.D2, Guid.D3, Guid.D4[0], Guid.D4[1], Guid.D4[2], Guid.D4[3], Guid.D4[4], Guid.D4[5], Guid.D4[6], Guid.D4[7]]);
end;

function GenerateHostUUID(Param:String):String;
var
  aGuid:TGuid;

begin
  CoCreateGuid(aGuid);
  Result := 'rnd-'+FormatGuid(aGuid);     
end;

function MustChangeHostUUID:Boolean;
var
  ForcedUUID:String;
begin
  Result := False;
  ForcedUUID := GetIniString( 'global', 'uuid', '', ExpandConstant('{app}\wapt-get.ini'));
  Result := ((ExpandConstant('{param:use_random_uuid|{#use_random_uuid}}')='1') or WizardIsTaskSelected('UseRandomUUID')) and (ForcedUUID='');
end;

function CopyPackagesTrustedCACheck:Boolean;
var
  value: String;
begin
  value := ExpandConstant('{param:CopyPackagesTrustedCA}')
  Result := (value <> '') and (value<>'0');     
end;

function CopyServersTrustedCACheck:Boolean;
var
  value: String;
begin
  value := ExpandConstant('{param:CopyServersTrustedCA}')
  Result := (value <> '') and (value<>'0');     
end;

function LocalWaptServiceIsConfigured() : Boolean;
var
  s : String;
  v : String;
begin
  result := false;
  s:= ExpandConstant('{#emit SetupSetting("AppId")}_is1');
  if not RegQueryStringValue( HKLM, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + s, 'InstallLocation', s ) then
    exit;

  s := s + '\wapt-get.ini';   
  if not FileExists( s ) then
    exit;

  v := GetIniString( 'global', 'wapt_server', '', s );
  if v = '' then
    exit;
  
  v := GetIniString( 'global', 'repo_url', '', s );
  if v = '' then
    exit;

  result := true;
end;

function StrToken(var S: String; Separator: String): String;
var
  I: Integer;
begin
  I := Pos(Separator, S);
  if I <> 0 then
  begin
    Result := Copy(S, 1, I - 1);
    Delete(S, 1,I+Length(Separator)-1);
  end
  else
  begin
    Result := S;
    S := '';
  end;
end;

function GetHostProfiles(param:String):String;
var
  AppendProfiles,profile: String;
begin
  Result := GetIniString('global', 'host_profiles', '',ExpandConstant('{app}\wapt-get.ini'));
  AppendProfiles := ExpandConstant('{param:append_host_profiles|{#append_host_profiles}}');
  if Result = '' then begin
    if AppendProfiles='*' then
      Result := ''
    else
      Result := AppendProfiles
  end
  else begin
    if AppendProfiles<>'*' then begin
      profile := StrToken(AppendProfiles,',');
      while profile<>'' do begin
        if pos(profile+',',Result+',')<=0 then 
          Result := Result+','+profile;
	    profile := StrToken(AppendProfiles,',');
      end;
    end
  end;
end;

function GetWaptauditTaskPeriod(param:String):String;
begin
  Result := ExpandConstant('{param:waptaudit_task_period|{#set_waptaudit_task_period}}');
end;

procedure PostClickNext();
begin
  PostMessage(WizardForm.NextButton.Handle, $BD11 , 0, 0);
end;  


#if edition != "waptserversetup"
procedure CurPageChanged(CurPageID: Integer);



begin
  case CurPageID of
    wpWelcome:
      begin
      end;
     customPage.Id:
      begin
        edWaptRepoUrl.Text := GetRepoURL('');
        #if edition != "waptstarter"
        edWaptServerUrl.Text := GetWaptServerURL('');  
        #endif
        cbDontChangeConfig.Checked := not(GetRepoURL('') = '');
        cbStaticUrl.Checked := not(cbDontChangeConfig.Checked) or ((edWaptRepoUrl.Text<>'') and (edWaptRepoUrl.Text<>'unknown'));
        //edWaptServerUrl.Visible := WizardIsTaskSelected('use_waptserver');
        //labServer.Visible := edWaptServerUrl.Visible;
      end;

    wpFinished:
      begin
        //#if edition == "waptsetup"
        //i := WizardForm.RunList.Items.Count 
        //if i = 0 then
        //  exit;
        //i := i - 1;        
        //WizardForm.RunList.Checked[i] := not LocalWaptServiceIsConfigured(); 
        //exit;
        //#endif
              end;
  end;
end;
#endif


procedure killtask(name:String);
var
  errorcode:integer;
begin
  if TransitionMode() then Exit;
  shellexec('','taskkill','/t /im "'+name+'" /f','',sw_Hide,ewWaitUntilTerminated,Errorcode);
end;
