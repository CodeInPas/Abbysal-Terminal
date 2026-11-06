{ src\ui\fMain.pas }
unit fMain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls,
  ComCtrls, TAGraph, TASeries, LCLType, Menus,
  uConstants, uTypes, uGameEngine, uTerminalRenderer, uAudioDSP, uDataVisualizer;

type
  { TfrmMain }
  TfrmMain = class(TForm)
    btnStartMission: TButton;
    chartAudio: TChart;
    chartHull: TChart;
    chkScanlines: TCheckBox;
    edtCLI: TEdit;
    gbCharts: TGroupBox;
    gbData: TGroupBox;
    gbPower: TGroupBox;
    lblCLI: TLabel;
    lblCor: TLabel;
    lblDrl: TLabel;
    lblEng: TLabel;
    lblMinerals: TLabel;
    lblSnr: TLabel;
    MainMenu1: TMainMenu;
    memLog: TMemo;
    MenuItem1: TMenuItem;
    mnTutorialIND: TMenuItem;
    mnTutorialENG: TMenuItem;
    mnAbout: TMenuItem;
    mnHelp: TMenuItem;
    mnExit: TMenuItem;
    Panel1: TPanel;
    pbTerminal: TPaintBox;
    pnlControl: TPanel;
    pnlTerminal: TPanel;
    rgTheme: TRadioGroup;
    Separator1: TMenuItem;
    serAudio: TLineSeries;
    serHull: TLineSeries;
    tbCore: TTrackBar;
    tbDrill: TTrackBar;
    tbEngine: TTrackBar;
    tbSonar: TTrackBar;
    tmrEngine: TTimer;
    procedure btnStartMissionClick(Sender: TObject);
    procedure chkScanlinesChange(Sender: TObject);
    procedure edtCLIKeyPress(Sender: TObject; var Key: char);
    procedure edtCLIKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure mnExitClick(Sender: TObject);
    procedure pbTerminalPaint(Sender: TObject);
    procedure rgThemeClick(Sender: TObject);
    procedure tbPowerChange(Sender: TObject);
    procedure tmrEngineTimer(Sender: TObject);
  private
    FEngine: TGameEngine;
    FRenderer: TTerminalRenderer;
    FAudio: TAudioDSP;

    FCommandHistory: TCommandHistory;
    FHistoryIndex: Integer;

    procedure EngineLogMessage(const AMsg: string; ALevel: TAlertLevel);
    procedure EngineClearTerminal(Sender: TObject);
    procedure EngineStateChange(ANewState: TGameState; AReason: TGameOverReason);
    procedure EngineAudioPan(APanSource: Integer; APanValue: Single);
    procedure ApplyUITheme;
  public
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.lfm}

{ TfrmMain }

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  Caption := APP_TITLE + ' ' + APP_VERSION;
  DoubleBuffered := True;

  FCommandHistory := TCommandHistory.Create;
  FHistoryIndex := -1;

  FAudio := TAudioDSP.Create;
  FAudio.Initialize(Self.Handle);

  FEngine := TGameEngine.Create;
  FEngine.OnLogMessage := @EngineLogMessage;
  FEngine.OnClearTerminal := @EngineClearTerminal;
  FEngine.OnStateChange := @EngineStateChange;
  FEngine.OnAudioPan := @EngineAudioPan; // Hooking up spatial audio events

  FRenderer := TTerminalRenderer.Create;

  ApplyUITheme;

  FEngine.InitializeEngine;
  tmrEngine.Enabled := True;
end;

procedure TfrmMain.FormShow(Sender: TObject);
begin
  edtCLI.SetFocus;
  WindowState:=wsMaximized;
end;

procedure TfrmMain.mnExitClick(Sender: TObject);
begin
  FormDestroy(sender);
  Application.Terminate;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  tmrEngine.Enabled := False;
  FreeAndNil(FCommandHistory);
  FreeAndNil(FAudio);
  FreeAndNil(FRenderer);
  FreeAndNil(FEngine);
end;

procedure TfrmMain.ApplyUITheme;
begin
  TDataVisualizer.ApplyChartTheme(chartAudio, FRenderer.CRTTheme);
  TDataVisualizer.ApplyChartTheme(chartHull, FRenderer.CRTTheme);

  if FRenderer.CRTTheme = ctGreen then
  begin
    memLog.Font.Color := GetThemePalette(ctGreen).Primary;
    edtCLI.Font.Color := GetThemePalette(ctGreen).Primary;
  end
  else
  begin
    memLog.Font.Color := GetThemePalette(ctAmber).Primary;
    edtCLI.Font.Color := GetThemePalette(ctAmber).Primary;
  end;
end;

procedure TfrmMain.EngineLogMessage(const AMsg: string; ALevel: TAlertLevel);
begin
  memLog.Lines.Add(AMsg);
  if memLog.Lines.Count > 100 then
    memLog.Lines.Delete(0);
  memLog.SelStart := Length(memLog.Text);
end;

procedure TfrmMain.EngineClearTerminal(Sender: TObject);
begin
  memLog.Clear;
end;

procedure TfrmMain.EngineStateChange(ANewState: TGameState; AReason: TGameOverReason);
begin
  if ANewState in [gsBooting, gsVictory, gsGameOver] then
  begin
    btnStartMission.Enabled := (ANewState <> gsBooting);
    edtCLI.Enabled := False;
    if Assigned(FAudio) and (ANewState <> gsBooting) then FAudio.StopAllAudio;
  end
  else
  begin
    btnStartMission.Enabled := False;
    edtCLI.Enabled := True;
    if Self.Visible then edtCLI.SetFocus;
  end;
end;

procedure TfrmMain.EngineAudioPan(APanSource: Integer; APanValue: Single);
begin
  if Assigned(FAudio) then
    FAudio.SetAudioPan(APanSource, APanValue);
end;

procedure TfrmMain.pbTerminalPaint(Sender: TObject);
begin
  if not Assigned(FRenderer) then Exit;
  FRenderer.RenderTerminal(
    pbTerminal.Canvas, pbTerminal.Width, pbTerminal.Height,
    FEngine.Telemetry.Data, FEngine.Environment.Blips,
    FEngine.GameState, FEngine.GameOverReason
  );
end;

procedure TfrmMain.tmrEngineTimer(Sender: TObject);
begin
  if not Assigned(FEngine) then Exit;

  if FEngine.IsRunning or (FEngine.GameState = gsBooting) then
  begin
    FEngine.UpdateEngineTick;

    if Assigned(FAudio) then
      FAudio.UpdateAudioDSP(tmrEngine.Interval / 1000.0, FEngine.Telemetry.Data);

    if (GetTickCount64 mod 100) < tmrEngine.Interval then
    begin
      TDataVisualizer.UpdateAudioSpectrum(serAudio, FAudio.FFTData, FRenderer.CRTTheme);
      TDataVisualizer.UpdateHullStressCurve(serHull, FEngine.Telemetry.HullStressHistory, FRenderer.CRTTheme);
      lblMinerals.Caption := Format('MINERAL SAMPLES : [%.2d]', [FEngine.Telemetry.Data.MineralsCollected]);
    end;
  end;

  pbTerminal.Invalidate;
end;

procedure TfrmMain.edtCLIKeyPress(Sender: TObject; var Key: char);
var
  InputText: string;
begin
  if Key = #13 then
  begin
    Key := #0;
    InputText := Trim(edtCLI.Text);
    if (InputText <> '') and Assigned(FEngine) and FEngine.IsRunning then
    begin
      FEngine.SubmitCLICommand(InputText);

      // Simpan command ke history
      if (FCommandHistory.Count = 0) or (FCommandHistory.Last <> InputText) then
      begin
        FCommandHistory.Add(InputText);
        if FCommandHistory.Count > CLI_HISTORY_LIMIT then
          FCommandHistory.Delete(0);
      end;
      FHistoryIndex := FCommandHistory.Count;

      edtCLI.Clear;
    end;
  end;
end;

procedure TfrmMain.edtCLIKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if FCommandHistory.Count = 0 then Exit;

  if Key = VK_UP then
  begin
    Key := 0; // Cegah propagasi default input
    if FHistoryIndex > 0 then
      Dec(FHistoryIndex);

    if (FHistoryIndex >= 0) and (FHistoryIndex < FCommandHistory.Count) then
    begin
      edtCLI.Text := FCommandHistory[FHistoryIndex];
      edtCLI.SelStart := Length(edtCLI.Text);
    end;
  end
  else if Key = VK_DOWN then
  begin
    Key := 0; // Cegah propagasi default input
    if FHistoryIndex < FCommandHistory.Count - 1 then
    begin
      Inc(FHistoryIndex);
      edtCLI.Text := FCommandHistory[FHistoryIndex];
      edtCLI.SelStart := Length(edtCLI.Text);
    end
    else
    begin
      FHistoryIndex := FCommandHistory.Count;
      edtCLI.Clear;
    end;
  end;
end;

procedure TfrmMain.tbPowerChange(Sender: TObject);
begin
  if not Assigned(FEngine) then Exit;

  if Sender = tbEngine then FEngine.SetSubsystemPower(sysEngine, tbEngine.Position)
  else if Sender = tbSonar then FEngine.SetSubsystemPower(sysSonar, tbSonar.Position)
  else if Sender = tbDrill then FEngine.SetSubsystemPower(sysDrill, tbDrill.Position)
  else if Sender = tbCore then FEngine.SetSubsystemPower(sysCoreOS, tbCore.Position);
end;

procedure TfrmMain.rgThemeClick(Sender: TObject);
begin
  if not Assigned(FRenderer) then Exit;
  if rgTheme.ItemIndex = 0 then
    FRenderer.CRTTheme := ctGreen
  else
    FRenderer.CRTTheme := ctAmber;
  ApplyUITheme;
end;

procedure TfrmMain.chkScanlinesChange(Sender: TObject);
begin
  if Assigned(FRenderer) then
    FRenderer.ScanlinesEnabled := chkScanlines.Checked;
end;

procedure TfrmMain.btnStartMissionClick(Sender: TObject);
begin
  if Assigned(FEngine) then
  begin
    memLog.Clear;
    FEngine.StartNewMission;

    // Sync UI with Engine defaults
    tbEngine.Position := FEngine.Telemetry.Data.Power.Engine;
    tbSonar.Position := FEngine.Telemetry.Data.Power.Sonar;
    tbDrill.Position := FEngine.Telemetry.Data.Power.Drill;
    tbCore.Position := FEngine.Telemetry.Data.Power.CoreOS;
  end;
end;

end.
