unit uVisSettings;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, StdCtrls,
  Buttons, ExtCtrls, Menus, ActnList, ComCtrls;

function GetWaptSelfLanguage: string;

type

  { TVisSettings }

  TVisSettings = class(TForm)
    ButCancel: TBitBtn;
    ButOk: TBitBtn;
    ComboBoxLang: TComboBox;
    Language: TLabel;
    PanelSettings: TPanel;
    PanelBtn: TPanel;
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
  private

  public

  end;

var
  VisSettings: TVisSettings;

implementation

uses IniFiles, GetText, waptcommon;

{$R *.lfm}

function GetWaptSelfLanguage: string;
var
  Ini: TIniFile;
  Lang, Fallback: string;
begin
  Ini := TIniFile.Create(AppIniFilename);
  try
    Result := LowerCase(Trim(Ini.ReadString('global', 'language', '')));
  finally
    Ini.Free;
  end;

  if Result = '' then
  begin
    GetLanguageIDs(Lang, Fallback);
    if Copy(LowerCase(Lang), 1, 2) = 'fr' then
      Result := 'fr'
    else
      Result := 'en';
  end;
end;

procedure TVisSettings.FormCreate(Sender: TObject);
begin
  if (GetWaptSelfLanguage='fr') then
    ComboBoxLang.ItemIndex:=ComboBoxLang.Items.IndexOf('Français')
  else
    ComboBoxLang.ItemIndex:=ComboBoxLang.Items.IndexOf('English');
end;

procedure TVisSettings.FormShow(Sender: TObject);
begin
  MakeFullyVisible();
  ComboBoxLang.SetFocus;
end;

end.

