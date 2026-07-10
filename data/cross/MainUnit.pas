unit MainUnit;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, RegExpr, Math;

type
  TMainForm = class(TForm)
    btnCalculate: TButton;
    txtTarget: TEdit;
    lblInstructions: TLabel;
    lblTarget: TLabel;
    lblTotal: TLabel;
    lblDiff: TLabel;
    txtHoursList: TMemo;
    procedure btnCalculateClick(Sender: TObject);
  private
    function ToHoursMinutes(Hours: Double): string;
  public
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

function TMainForm.ToHoursMinutes(Hours: Double): string;
var
  Sign: string;
  AbsHours: Double;
  H, M: Integer;
begin
  if Hours < 0 then Sign := '-' else Sign := '';
  AbsHours := Abs(Hours);
  H := Floor(AbsHours);
  M := Round((AbsHours - H) * 60.0);
  if M = 60 then
  begin
    H := H + 1;
    M := 0;
  end;
  Result := Format('%s%dh %02dm', [Sign, H, M]);
end;

procedure TMainForm.btnCalculateClick(Sender: TObject);
var
  TargetVal, TotalVal, DiffVal: Double;
  TargetStr, LineStr: string;
  I: Integer;
  Regex: TRegExpr;
begin
  // 1. Process and evaluate the target hours input string safely
  TargetStr := StringReplace(Trim(txtTarget.Text), ',', '.', [rfReplaceAll]);
  if not TryStrToFloat(TargetStr, TargetVal) then
  begin
    lblTotal.Caption := 'Error: Invalid target value.';
    lblDiff.Caption := '';
    Exit;
  end;

  TotalVal := 0.0;
  Regex := TRegExpr.Create('^-?(\d+([.,]\d*)?|[.,]\d+)$');
  try
    // 2. Loop through individual input rows line-by-line
    for I := 0 to txtHoursList.Lines.Count - 1 do
    begin
      LineStr := Trim(txtHoursList.Lines[I]);
      if LineStr = '' then Continue;
      LineStr := StringReplace(LineStr, ',', '.', [rfReplaceAll]);
      if Regex.Exec(LineStr) then
      begin
        TotalVal := TotalVal + StrToFloat(LineStr);
      end;
    end;
  finally
    Regex.Free;
  end;

  // 3. Complete the time difference math and write to UI labels
  DiffVal := TargetVal - TotalVal;
  lblTotal.Caption := Format('Total: %.2f hours (%s)', [TotalVal, ToHoursMinutes(TotalVal)]);
  lblDiff.Caption := Format('Difference: %.2f hours (%s)', [DiffVal, ToHoursMinutes(DiffVal)]);
end;

end.
