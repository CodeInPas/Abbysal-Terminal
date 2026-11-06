unit uGameEngine;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, uConstants, uTypes, uGameDatabase,
  uTelemetryManager, uEnvironmentSimulator, uCommandParser;

type
  { TGameEngine - Master simulation coordinator managing state, physics, CLI, and persistence }
  TGameEngine = class
  private
    FDatabase: TGameDatabase;
    FTelemetry: TTelemetryManager;
    FEnvironment: TEnvironmentSimulator;
    FCommandParser: TCommandParser;

    FGameState: TGameState;
    FGameOverReason: TGameOverReason;
    FLastTick: QWord;
    FBootTimer: QWord;
    FBootStep: Integer;
    FIsRunning: Boolean;
    FTargetDepthReached: Boolean;

    // External UI & Audio event hooks
    FOnLog: TLogEvent;
    FOnClearTerminal: TNotifyEvent;
    FOnStateChange: TStateChangeEvent;
    FOnTelemetryUpdate: TTelemetryUpdateEvent;
    FOnSonarPingContact: TNotifyEvent;
    FOnEntityStrike: TNotifyEvent;
    FOnAudioPan: TAudioPanEvent;

    procedure HandleInternalLog(const AMsg: string; ALevel: TAlertLevel = alNormal);
    procedure HandleTelemetryUpdate(const AData: TTelemetryData);
    procedure SetGameState(ANewState: TGameState; AReason: TGameOverReason = gorNone);

    procedure AdvanceBootSequence;
    procedure ProcessCommandQueue(ACurrentTick: QWord);
    procedure ExecuteQueuedCommand(const ACmd: TQueuedCommand);
    procedure CompleteTargetExtraction;
    procedure PrintStatusReport;
    procedure EvaluateStateAndConditions;
  public
    constructor Create;
    destructor Destroy; override;

    { Initializes subsystems, SQLite connection, and starts a new dive mission }
    procedure InitializeEngine;

    { Resets all simulation state for a fresh mission dive }
    procedure StartNewMission;

    { Main 60Hz simulation loop tick called by UI master timer }
    procedure UpdateEngineTick;

    { Dispatches raw CLI string from Terminal UI into the command parser }
    procedure SubmitCLICommand(const ACommandText: string);

    { Direct UI Panel 2 Control Board mutators }
    procedure SetSubsystemPower(ASubsystem: TSubsystem; APower: Integer);
    procedure SetAutoValve(AEnabled: Boolean);
    procedure TriggerManualPurge;

    { Subsystem accessors }
    property Database: TGameDatabase read FDatabase;
    property Telemetry: TTelemetryManager read FTelemetry;
    property Environment: TEnvironmentSimulator read FEnvironment;
    property CommandParser: TCommandParser read FCommandParser;

    property GameState: TGameState read FGameState;
    property GameOverReason: TGameOverReason read FGameOverReason;
    property IsRunning: Boolean read FIsRunning write FIsRunning;
    property BootStep: Integer read FBootStep;

    { Events }
    property OnLogMessage: TLogEvent read FOnLog write FOnLog;
    property OnClearTerminal: TNotifyEvent read FOnClearTerminal write FOnClearTerminal;
    property OnStateChange: TStateChangeEvent read FOnStateChange write FOnStateChange;
    property OnTelemetryUpdate: TTelemetryUpdateEvent read FOnTelemetryUpdate write FOnTelemetryUpdate;
    property OnSonarPingContact: TNotifyEvent read FOnSonarPingContact write FOnSonarPingContact;
    property OnEntityStrike: TNotifyEvent read FOnEntityStrike write FOnEntityStrike;
    property OnAudioPan: TAudioPanEvent read FOnAudioPan write FOnAudioPan;
  end;

implementation

{ TGameEngine }

constructor TGameEngine.Create;
begin
  inherited Create;
  FDatabase := TGameDatabase.Create;
  FTelemetry := TTelemetryManager.Create;
  FEnvironment := TEnvironmentSimulator.Create;
  FCommandParser := TCommandParser.Create;

  // Wire internal observer callbacks
  FTelemetry.OnLogMessage := @HandleInternalLog;
  FTelemetry.OnTelemetryUpdate := @HandleTelemetryUpdate;
  FEnvironment.OnLogMessage := @HandleInternalLog;
  FCommandParser.OnLogMessage := @HandleInternalLog;

  FGameState := gsBooting;
  FGameOverReason := gorNone;
  FIsRunning := False;
  FTargetDepthReached := False;
  FLastTick := GetTickCount64;
  FBootTimer := 0;
  FBootStep := 0;
end;

destructor TGameEngine.Destroy;
begin
  FIsRunning := False;
  FCommandParser.Free;
  FEnvironment.Free;
  FTelemetry.Free;
  FDatabase.Free;
  inherited Destroy;
end;

procedure TGameEngine.HandleInternalLog(const AMsg: string; ALevel: TAlertLevel);
begin
  if Assigned(FOnLog) then
    FOnLog(AMsg, ALevel);
end;

procedure TGameEngine.HandleTelemetryUpdate(const AData: TTelemetryData);
begin
  if Assigned(FOnTelemetryUpdate) then
    FOnTelemetryUpdate(AData);
end;

procedure TGameEngine.SetGameState(ANewState: TGameState; AReason: TGameOverReason);
begin
  if (FGameState = ANewState) and (FGameOverReason = AReason) then
    Exit;

  FGameState := ANewState;
  FGameOverReason := AReason;

  if Assigned(FOnStateChange) then
    FOnStateChange(FGameState, FGameOverReason);
end;

procedure TGameEngine.InitializeEngine;
begin
  if FDatabase.Initialize then
    HandleInternalLog('[SYS] SQLITE TELEMETRY DATABASE MOUNTED.', alNormal)
  else
    HandleInternalLog('[WARN] DATABASE DISK I/O FAILED. VOLATILE RAM MODE ACTIVE.', alWarning);

  StartNewMission;
end;

procedure TGameEngine.StartNewMission;
begin
  FCommandParser.ClearQueue;
  FTelemetry.ResetTelemetry;
  FEnvironment.ResetEnvironment(FTelemetry.Data.Position);

  FTargetDepthReached := False;
  FLastTick := GetTickCount64;
  FBootTimer := FLastTick;
  FBootStep := 0; // [QA Fix] Ensure boot step is completely reset for new missions
  FIsRunning := True;

  // Trigger boot sequence instead of immediate start
  SetGameState(gsBooting, gorNone);
end;

procedure TGameEngine.AdvanceBootSequence;
begin
  case FBootStep of
    0: HandleInternalLog('MARIANA OS BIOS ' + APP_VERSION + ' INIT...', alNormal);
    1: HandleInternalLog('MOUNTING VIRTUAL FILE SYSTEM... [OK]', alNormal);
    2: HandleInternalLog('LOADING HYDROACOUSTIC DRIVERS... [OK]', alNormal);
    3: HandleInternalLog('CHECKING SENSOR TELEMETRY... [OK]', alNormal);
    4: HandleInternalLog('CALIBRATING LASER DRILL... [OK]', alNormal);
    5: HandleInternalLog('ESTABLISHING UMBILICAL LINK... [OK]', alNormal);
    6: HandleInternalLog(MSG_BOOT_SEQ, alNormal);
    7: HandleInternalLog('SYSTEM READY.', alNormal);
    8: begin
         HandleInternalLog(Format('[SYS] MISSION OBJECTIVE: EXTRACT %d MINERAL SAMPLES & REACH %.0fM.',
           [REQUIRED_MINERALS, TARGET_MISSION_DEPTH]), alNormal);
         FDatabase.LogEvent('MISSION_START', 'Bathyscaphe launched into Mariana Trench', FTelemetry.Data.Position.Z);
         SetGameState(gsDescent, gorNone);
       end;
  end;
  Inc(FBootStep);
end;

procedure TGameEngine.UpdateEngineTick;
var
  CurrentTick: QWord;
  DeltaTime: Double;
  DrillFinished, PingContact: Boolean;
  ActiveAnomalies: Integer;
  NearestAnomaly, StrikeDmg: Double;
  NearestPan: Single;
begin
  if (not FIsRunning) or (FGameState in [gsVictory, gsGameOver]) then
    Exit;

  CurrentTick := GetTickCount64;

  // 1. Handle Boot-up Sequence Animation delay
  if FGameState = gsBooting then
  begin
    if (CurrentTick - FBootTimer) >= BOOT_SEQ_DELAY_MS then
    begin
      FBootTimer := CurrentTick;
      AdvanceBootSequence;
    end;
    FLastTick := CurrentTick; // Prevent large delta time accumulation during boot
    Exit;
  end;

  DeltaTime := (CurrentTick - FLastTick) / 1000.0;
  FLastTick := CurrentTick;

  // Clamp delta time to prevent physics jumps if window is dragged/paused
  if DeltaTime <= 0.0 then
    Exit;
  if DeltaTime > 0.15 then
    DeltaTime := 0.15;

  // 2. Process delayed umbilical CLI commands
  ProcessCommandQueue(CurrentTick);

  // 3. Update internal bathyscaphe physics, battery, and hydrostatics
  FTelemetry.UpdateTick(DeltaTime, DrillFinished);
  if DrillFinished then
    CompleteTargetExtraction;

  // 4. Update external abyssal environment, sonar blips, and Leviathan AI
  FEnvironment.UpdateEnvironment(
    DeltaTime,
    FTelemetry.Data,
    ActiveAnomalies,
    NearestAnomaly,
    NearestPan,
    StrikeDmg,
    PingContact
  );

  FTelemetry.UpdateAnomalyMetrics(ActiveAnomalies, NearestAnomaly, NearestPan);

  if PingContact and Assigned(FOnSonarPingContact) then
    FOnSonarPingContact(Self);

  if Assigned(FOnAudioPan) then
  begin
    // Pass Pan info to Audio system for Leviathan roar (source 1 = Monster)
    FOnAudioPan(1, NearestPan);
  end;

  // 5. Handle physical Leviathan impact if collision occurred (Triggers EMP)
  if StrikeDmg > 0.0 then
  begin
    FTelemetry.ApplyExternalDamage(
      StrikeDmg,
      Format('[CRIT] LEVIATHAN IMPACT DETECTED! HULL BREACH: -%.1f%%!', [StrikeDmg])
    );
    FTelemetry.CancelDrillSequence('[ERR] LASER DRILL DISLODGED BY EXTERNAL IMPACT!');

    // TRIGGER EMP BLACKOUT KERNEL PANIC
    FTelemetry.TriggerEMPBlackout;

    FDatabase.LogEvent('ENTITY_STRIKE', 'Hull impact by biological anomaly causing EMP surge', FTelemetry.Data.Position.Z);

    if Assigned(FOnEntityStrike) then
      FOnEntityStrike(Self);
  end;

  // 6. Buffer telemetry to SQLite database
  FDatabase.RecordTelemetryTick(FTelemetry.Data);

  // 7. Check state transitions and win/loss conditions
  EvaluateStateAndConditions;
end;

procedure TGameEngine.ProcessCommandQueue(ACurrentTick: QWord);
var
  Cmd: TQueuedCommand;
begin
  while FCommandParser.PopReadyCommand(ACurrentTick, Cmd) do
    ExecuteQueuedCommand(Cmd);
end;

procedure TGameEngine.ExecuteQueuedCommand(const ACmd: TQueuedCommand);
var
  NearestMineralDist: Double;
  LogText: string;
begin
  case ACmd.CommandType of
    ctHelp:
      HandleInternalLog(FCommandParser.GetHelpText, alNormal);

    ctStatus:
      PrintStatusReport;

    ctClear:
      if Assigned(FOnClearTerminal) then
        FOnClearTerminal(Self);

    ctSonar:
      if ACmd.StringParam = 'active' then
        FTelemetry.SetSonarMode(smActive)
      else
        FTelemetry.SetSonarMode(smPassive);

    ctThruster:
      begin
        if ACmd.TargetDir = tdNone then
        begin
          // Equivalent to thruster_stop if parsed as "none"
          FTelemetry.StopThrusters;
          HandleInternalLog('[SYS] PROPULSION CUT. RETURNING TO PASSIVE DESCENT.', alNormal);
        end
        else
        begin
          FTelemetry.SetThrusterCommand(ACmd.TargetDir, ACmd.NumericParam);
          HandleInternalLog(Format('[SYS] THRUSTERS ENGAGED. VECTOR OUTPUT: %.0f%%.',
            [ACmd.NumericParam]), alNormal);
        end;
      end;

    ctThrusterStop:
      begin
        FTelemetry.StopThrusters;
        HandleInternalLog('[SYS] PROPULSION CUT. RETURNING TO PASSIVE DESCENT.', alNormal);
      end;

    ctPurgeValve:
      begin
        if ACmd.StringParam = 'auto' then
        begin
          FTelemetry.ToggleAutoValve(True);
          HandleInternalLog('[SYS] PRESSURE EQUALIZATION VALVE SET TO AUTO.', alNormal);
        end
        else if ACmd.StringParam = 'manual' then
        begin
          FTelemetry.ToggleAutoValve(False);
          HandleInternalLog('[SYS] PRESSURE EQUALIZATION VALVE SET TO MANUAL.', alNormal);
        end
        else
          FTelemetry.TriggerValvePurge;
      end;

    ctRoutePower:
      begin
        FTelemetry.SetPowerAllocation(ACmd.TargetSubsys, Round(ACmd.NumericParam));
        HandleInternalLog(Format('[SYS] POWER ROUTING UPDATED: %.0f%% ALLOCATED.',
          [ACmd.NumericParam]), alNormal);
      end;

    ctRunDrill:
      begin
        NearestMineralDist := FEnvironment.GetNearestMineralDistance(FTelemetry.Data.Position);
        if NearestMineralDist <= MINERAL_LOCK_RANGE then
        begin
          if FTelemetry.StartDrillSequence then
            FDatabase.LogEvent('DRILL_START', 'Laser extraction started', FTelemetry.Data.Position.Z);
        end
        else
          HandleInternalLog(Format('[ERR] NO TARGET IN LOCK RANGE (NEAREST: %.1fM / REQ: <%.0fM).',
            [NearestMineralDist, MINERAL_LOCK_RANGE]), alWarning);
      end;

    ctRunDrillRev:
      begin
        FTelemetry.ReverseDrillSequence;
      end;

    ctRunDiag:
      FTelemetry.RunSystemDiagnostic;

    ctRunSysReboot:
      begin
        FTelemetry.InitiateReboot;
      end;

    ctDeployDecoy:
      begin
        if FTelemetry.TryDeployDecoy then
        begin
          FEnvironment.SpawnDecoy(FTelemetry.Data.Position);
          FDatabase.LogEvent('DECOY_DEPLOYED', 'Acoustic decoy ejected', FTelemetry.Data.Position.Z);
        end;
      end;

    ctReadLog:
      begin
        LogText := FDatabase.ReadBlackboxLore(Round(ACmd.NumericParam));
        if LogText = '[ERR] LOG NOT FOUND OR ACCESS DENIED.' then
          HandleInternalLog(LogText, alWarning)
        else
          HandleInternalLog(Format('[LOG #%.0f] %s', [ACmd.NumericParam, LogText]), alNormal);
      end;
  end;
end;

procedure TGameEngine.CompleteTargetExtraction;
var
  Sample: TMineralSampleItem;
  IsBlackbox: Boolean;
  NewLogID: Integer;
begin
  if FEnvironment.ExtractNearestTarget(FTelemetry.Data.Position, IsBlackbox) then
  begin
    if IsBlackbox then
    begin
      NewLogID := FDatabase.RegisterBlackboxRecovery(FTelemetry.Data.Position.Z);
      FTelemetry.NotifyBlackboxRecovered;
      HandleInternalLog(Format('[SYS] NEW ENCRYPTED LOG ID: %.0f', [NewLogID * 1.0]), alNormal);
    end
    else
    begin
      FTelemetry.IncrementMinerals;
      Sample := FDatabase.RegisterMineralExtraction(FTelemetry.Data.Position.Z);
      HandleInternalLog(Format('[SYS] CATALOGED: %s [%s] (PURITY: %.1f%%)',
        [Sample.MineralName, Sample.SampleCode, Sample.PurityPercent]), alNormal);
    end;
  end
  else
    HandleInternalLog('[WARN] EXTRACTION CYCLE FINISHED BUT TARGET WAS LOST.', alWarning);
end;

procedure TGameEngine.PrintStatusReport;
var
  D: TTelemetryData;
begin
  D := FTelemetry.Data;
  HandleInternalLog(
    Format('--- VESSEL TELEMETRY STATUS ---' + LineEnding +
           '  COORDINATES : X:%.1f  Y:%.1f  DEPTH:%.1fM' + LineEnding +
           '  HULL / BATT : %.1f%% / %.1f%%' + LineEnding +
           '  PRESSURE    : EXT %.0f PSI | DIFF %.0f PSI' + LineEnding +
           '  MINERALS    : %d / %d EXTRACTED' + LineEnding +
           '  LATENCY     : %d ms',
           [D.Position.X, D.Position.Y, D.Position.Z,
            D.HullIntegrity, D.BatteryReserve,
            D.ExternalPSI, D.PSIDifferential,
            D.MineralsCollected, REQUIRED_MINERALS,
            FCommandParser.CalculateLatencyMS(D.Position.Z)]),
    alNormal
  );
end;

procedure TGameEngine.EvaluateStateAndConditions;
var
  D: TTelemetryData;
begin
  D := FTelemetry.Data;

  // 1. Evaluate Loss Conditions (Fatal checks must exit immediately to prevent Zombie Wins)
  if D.HullIntegrity <= 0.0 then
  begin
    FIsRunning := False;
    FDatabase.FlushBufferToDisk;
    if D.PSIDifferential >= IMPLOSION_PSI_DIFF * 0.85 then
    begin
      HandleInternalLog('[FATAL] CATASTROPHIC HULL IMPLOSION AT ' +
        Format('%.0fM. SIGNAL LOST.', [D.Position.Z]), alCritical);
      FDatabase.LogEvent('GAME_OVER', 'Vessel destroyed by hydrostatic implosion', D.Position.Z);
      SetGameState(gsGameOver, gorImplosion);
    end
    else
    begin
      HandleInternalLog('[FATAL] HULL STRUCTURAL COLLAPSE FROM ENTITY STRIKE. SIGNAL LOST.', alCritical);
      FDatabase.LogEvent('GAME_OVER', 'Vessel destroyed by biological anomaly', D.Position.Z);
      SetGameState(gsGameOver, gorEntityStrike);
    end;
    Exit; // [QA Fix] Prevent evaluating victory if we just died this exact frame
  end;

  if D.BatteryReserve <= 0.0 then
  begin
    FIsRunning := False;
    FDatabase.FlushBufferToDisk;
    HandleInternalLog('[FATAL] TOTAL POWER DEPLETION. LIFE SUPPORT & TERMINAL OFFLINE.', alCritical);
    FDatabase.LogEvent('GAME_OVER', 'Total battery reserve depletion', D.Position.Z);
    SetGameState(gsGameOver, gorPowerDepleted);
    Exit; // [QA Fix]
  end;

  // 2. Check Target Depth Milestone
  if (not FTargetDepthReached) and (D.Position.Z >= TARGET_MISSION_DEPTH) then
  begin
    FTargetDepthReached := True;
    HandleInternalLog(Format('[SYS] TARGET TRENCH DEPTH (%.0fM) REACHED.', [TARGET_MISSION_DEPTH]), alNormal);
  end;

  // 3. Evaluate Victory Condition (Required minerals secured + Target depth reached)
  if (D.MineralsCollected >= REQUIRED_MINERALS) and FTargetDepthReached then
  begin
    FIsRunning := False;
    FDatabase.FlushBufferToDisk;
    HandleInternalLog('[SYS] ALL OBJECTIVES COMPLETED! TELEMETRY & SAMPLES TRANSMITTED TO SURFACE!', alNormal);
    FDatabase.LogEvent('MISSION_VICTORY', 'All abyssal samples secured and transmitted', D.Position.Z);
    SetGameState(gsVictory, gorNone);
    Exit;
  end;

  // 4. Update Dynamic Operational State
  if D.IsEMPBlackout then
    SetGameState(gsEMPBlackout, gorNone)
  else if D.AlertLevel = alCritical then
    SetGameState(gsCrisis, gorNone)
  else if D.IsDrilling then
    SetGameState(gsDrilling, gorNone)
  else if D.Velocity.Z < -0.1 then
    SetGameState(gsAscent, gorNone)
  else
    SetGameState(gsDescent, gorNone);
end;

procedure TGameEngine.SubmitCLICommand(const ACommandText: string);
begin
  if not FIsRunning then
    Exit;

  FCommandParser.SubmitCommand(ACommandText, FTelemetry.Data);
end;

procedure TGameEngine.SetSubsystemPower(ASubsystem: TSubsystem; APower: Integer);
begin
  FTelemetry.SetPowerAllocation(ASubsystem, APower);
end;

procedure TGameEngine.SetAutoValve(AEnabled: Boolean);
begin
  FTelemetry.ToggleAutoValve(AEnabled);
end;

procedure TGameEngine.TriggerManualPurge;
begin
  FTelemetry.TriggerValvePurge;
end;

end.
