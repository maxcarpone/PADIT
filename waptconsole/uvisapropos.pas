unit uVisAPropos;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, ExtCtrls,
  StdCtrls, DefaultTranslator, Buttons;

type

  { TVisApropos }

  TVisApropos = class(TForm)
    BitBtn1: TBitBtn;
    BitBtn2: TBitBtn;
    Image1: TImage;
    LabInfos: TLabel;
    LabLicencedTo: TLabel;
    LicenceLog: TMemo;
    Panel1: TPanel;
    Panel2: TPanel;
    Panel4: TPanel;
    procedure FormCreate(Sender: TObject);
    procedure Image1Click(Sender: TObject);
  private
    { private declarations }
  public
    { public declarations }
  end;

var
  VisApropos: TVisApropos;

implementation
uses uWaptConsoleRes,tiscommon,waptcommon,LCLIntf,tisstrings, uwaptconsole,dmwaptpython,LazFileUtils;
{$R *.lfm}

{ TVisApropos }

procedure TVisApropos.FormCreate(Sender: TObject);
var
  LicenceFiles:TStringList;
  SLicenceLog:String;
  Licence: Variant;
  TotalCount:Integer;
begin
  Image1.Picture.LoadFromResourceName(HINSTANCE,'WAPT_PNG',TPortableNetworkGraphic);

  {$IFDEF WINDOWS}
  LabInfos.Caption := ApplicationName+' '+GetApplicationVersion+' -'+LineEnding+
    'derived from WAPT Community'+LineEnding+
    'originally developed by Tranquil IT.';
  {$ELSE}
  LabInfos.Caption := ApplicationName+' - derived from WAPT Community, originally developed by Tranquil IT.'; // TODO change
  {$ENDIF}

  if FileExistsUTF8(ExtractFilePath(ParamStr(0))+'revision.txt') then
    LabInfos.Caption:=LabInfos.Caption+' rev '+FileToString(ExtractFilePath(ParamStr(0))+'revision.txt');

  LicenceLog.Clear;
  LicenceLog.Append('Configuration: '+AppIniFilename);
  SLicenceLog:='';
  {$ifndef ENTERPRISE}
  LabLicencedTo.Visible := False;
  {$endif}

  {$ifdef ENTERPRISE}
  TotalCount:=DMPython.CheckLicence('',SLicenceLog);
  LicenceLog.Lines.AddText(SLicenceLog);
  LabLicencedTo.Caption := Format(rsLicencedTo,[DMPython.LicensedTo]);
  {$endif}
end;

procedure TVisApropos.Image1Click(Sender: TObject);
begin
  OpenDocument('https://github.com/maxcarpone/WAPT');
end;

end.

