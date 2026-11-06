unit uTelemetryManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, uConstants, uTypes;

type
  { TTelemetryManager - Central state container and vessel systems calculator }
  TTelemetryManager = class
  private
    FData: TTelemetryData;
    FHullStressHistory: TFFTDataArray;
    FStressSampleTimer: Double;
    FLastPressureAlert: TAlertLevel;
    FTargetVelocity: TVector3D;

    FOnUpdate: TTelemetryUpdateEvent;
    FOnLog: TLogEvent;

    procedure DoLog(const AMsg: string; ALevel: TAlertLevel = alNormal);
    procedure UpdatePowerAndBattery(ADeltaTime: Double);
    procedure UpdateKinematics(ADeltaTime: Double);
    procedure UpdateHydrostatics(ADeltaTime: Double);
    procedure UpdateSubsystems(ADeltaTime: Double);
    procedure UpdateAlertAndGlitchState(ADeltaTime: Double);
    procedure PushHullStressSample(AStressValue: Single);
  public
    constructor Create;
    destructor Destroy; override;

    { Resets all vessel metrics to initial surface/launch conditions }
    procedure ResetTelemetry;

    { Advances internal vessel systems, battery drain, and pressure physics }
    procedure UpdateTick(ADeltaTime: Double; out ADrillCompleted: Boolean);

    { Subsystem & CLI Control Mutators }
    procedure SetSonarMode(AMode: TSonarMode);
    procedure SetPowerAllocation(ASubsystem: TSubsystem; AValue: Integer);
    procedure SetThrusterCommand(ADir: TThrusterDir; APowerPercent: Double);
    procedure StopThrusters;
    procedure TriggerValvePurge;
    procedure ToggleAutoValve(AEnabled: Boolean);

    { Operations & Diagnostics }
    function StartDrillSequence: Boolean;
    procedure ReverseDrillSequence;
    procedure CancelDrillSequence(const AReason: string);
    procedure RunSystemDiagnostic;
    procedure IncrementMinerals;
    procedure NotifyBlackboxRecovered;
    function TryDeployDecoy: Boolean;

    { EMP Crisis Mechanics }
    procedure TriggerEMPBlackout;
    procedure InitiateReboot;

    { External Environment Feedback Injectors }
    procedure ApplyExternalDamage(AAmount: Double; const AReasonMsg: string);
    procedure UpdateAnomalyMetrics(ACount: Integer; ANearestDist: Double; ANearestPan: Single);

    { Properties & Event Delegates }
    property Data: TTelemetryData read FData;
    property HullStressHistory: TFFTDataArray read FHullStressHistory;
    property OnTelemetryUpdate: TTelemetryUpdateEvent read FOnUpdate write FOnUpdate;
    property OnLogMessage: TLogEvent read FOnLog write FOnLog;
  end;

implementation

{ TTelemetryManager }

constructor TTelemetryManager.Create;
begin
  inherited Create;
  ResetTelemetry;
end;

destructor TTelemetryManager.Destroy;
begin
  inherited Destroy;
end;

procedure TTelemetryManager.DoLog(const AMsg: string; ALevel: TAlertLevel);
begin
  if Assigned(FOnLog) then
    FOnLog(AMsg, ALevel);
end;

procedure TTelemetryManager.ResetTelemetry;
var
  i: Integer;
begin
  FillChar(FData, SizeOf(TTelemetryData), 0);

  // Initial spatial coordinates (Starting descent at 250m depth)
  FData.Position := TVector3D.Create(0.0, 0.0, 250.0);
  FData.Velocity := TVector3D.Create(0.0, 0.0, BASE_DESCENT_RATE);
  FTargetVelocity := FData.Velocity;

  // Initial vessel integrity & resources
  FData.HullIntegrity := MAX_HULL_INTEGRITY;
  FData.BatteryReserve := MAX_BATTERY_RESERVE;
  FData.ExternalPSI := SURFACE_PSI + (FData.Position.Z * PSI_PER_METER);
  FData.InternalPSI := FData.ExternalPSI;
  FData.PSIDifferential := 0.0;

  // Default subsystem states
  FData.SonarMode := smActive;
  FData.SweepAngle := 0.0;
  FData.ValveAuto := False;
  FData.IsPurging := False;
  FData.IsDrilling := False;
  FData.DrillProgress := 0.0;
  FData.IsDrillJammed := False;

  FData.MineralsCollected := 0;
  FData.EntitiesDetected := 0;
  FData.NearestAnomalyDist := 9999.0;
  FData.NearestAnomalyPan := 0.0;

  FData.AlertLevel := alNormal;
  FData.GlitchIntensity := 0.0;
  FData.SyntaxCorrupted := False;

  FData.IsEMPBlackout := False;
  FData.RebootProgress := 0.0;

  // Default power distribution (%)
  FData.Power.Engine := 80;
  FData.Power.Sonar  := 100;
  FData.Power.Drill  := 0;
  FData.Power.CoreOS := 100;

  FLastPressureAlert := alNormal;
  FStressSampleTimer := 0.0;

  for i := 0 to High(FHullStressHistory) do
    FHullStressHistory[i] := 0.0;
end;

procedure TTelemetryManager.UpdateTick(ADeltaTime: Double; out ADrillCompleted: Boolean);
begin
  ADrillCompleted := False;

  UpdatePowerAndBattery(ADeltaTime);
  UpdateKinematics(ADeltaTime);
  UpdateHydrostatics(ADeltaTime);
  UpdateSubsystems(ADeltaTime);
  UpdateAlertAndGlitchState(ADeltaTime);

  // Check if drill cycle finished during this tick
  if FData.IsDrilling and (not FData.IsDrillJammed) and (FData.DrillProgress >= 100.0) then
  begin
    FData.IsDrilling := False;
    FData.DrillProgress := 0.0;
    FData.Power.Drill := 0;
    ADrillCompleted := True;
  end;

  if Assigned(FOnUpdate) then
    FOnUpdate(FData);
end;

procedure TTelemetryManager.UpdatePowerAndBattery(ADeltaTime: Double);
var
  TotalDrain, ThrusterLoad: Double;
begin
  if FData.BatteryReserve <= 0.0 then
  begin
    FData.BatteryReserve := 0.0;
    FData.SonarMode := smPassive;
    FData.IsDrilling := False;
    FData.IsDrillJammed := False;
    FTargetVelocity := TVector3D.Create(0.0, 0.0, BASE_DESCENT_RATE);
    Exit;
  end;

  // Base OS consumption
  TotalDrain := DRAIN_CORE_OS * (FData.Power.CoreOS / 100.0);

  // Sonar consumption
  if (FData.SonarMode = smActive) and (FData.Power.Sonar > 0) then
    TotalDrain := TotalDrain + (DRAIN_SONAR_ACTIVE * (FData.Power.Sonar / 100.0))
  else
    TotalDrain := TotalDrain + DRAIN_SONAR_PASSIVE;

  // Thruster consumption based on active movement vector vs passive sinking
  ThrusterLoad := Hypot(FData.Velocity.X, FData.Velocity.Y) +
                  Abs(FData.Velocity.Z - BASE_DESCENT_RATE);
  if ThrusterLoad > 0.1 then
    TotalDrain := TotalDrain + (DRAIN_THRUSTERS * (FData.Power.Engine / 100.0) *
                  (ThrusterLoad / MAX_THRUSTER_SPEED));

  // Laser Drill consumption
  if FData.IsDrilling then
  begin
    if FData.IsDrillJammed then
      TotalDrain := TotalDrain + DRAIN_DRILL_JAM // Huge penalty when jammed
    else
      TotalDrain := TotalDrain + (DRAIN_DRILL_SYSTEM * (Max(50, FData.Power.Drill) / 100.0));
  end;

  FData.BatteryReserve := Max(0.0, FData.BatteryReserve - (TotalDrain * ADeltaTime));
end;

procedure TTelemetryManager.UpdateKinematics(ADeltaTime: Double);
var
  HydroDrag, InterpRate: Double;
begin
  // Deeper hydrostatic density reduces thruster responsiveness
  HydroDrag := 1.0 - ((FData.Position.Z / MAX_TRENCH_DEPTH) * 0.45);
  InterpRate := Min(1.0, ADeltaTime * 2.5 * HydroDrag);

  // Smoothly interpolate current velocity toward target velocity
  FData.Velocity.X := FData.Velocity.X + (FTargetVelocity.X - FData.Velocity.X) * InterpRate;
  FData.Velocity.Y := FData.Velocity.Y + (FTargetVelocity.Y - FData.Velocity.Y) * InterpRate;
  FData.Velocity.Z := FData.Velocity.Z + (FTargetVelocity.Z - FData.Velocity.Z) * InterpRate;

  // Integrate position
  FData.Position.X := FData.Position.X + (FData.Velocity.X * ADeltaTime);
  FData.Position.Y := FData.Position.Y + (FData.Velocity.Y * ADeltaTime);
  FData.Position.Z := EnsureRange(
    FData.Position.Z + (FData.Velocity.Z * ADeltaTime),
    0.0,
    MAX_TRENCH_DEPTH
  );

  // Cancel active drilling if vessel moves laterally too fast
  if FData.IsDrilling and (Hypot(FData.Velocity.X, FData.Velocity.Y) > 1.2) then
    CancelDrillSequence('[ERR] DRILL SEQUENCE ABORTED: EXCESSIVE VESSEL DRIFT.');
end;

procedure TTelemetryManager.UpdateHydrostatics(ADeltaTime: Double);
var
  PurgeStep, StressFactor: Double;
begin
  // Calculate external water pressure at current depth
  FData.ExternalPSI := SURFACE_PSI + (FData.Position.Z * PSI_PER_METER);

  // Handle Manual Burst Purge vs Auto Equalization
  if FData.IsPurging then
  begin
    PurgeStep := VALVE_PURGE_RATE * ADeltaTime;
    if Abs(FData.ExternalPSI - FData.InternalPSI) <= PurgeStep then
    begin
      FData.InternalPSI := FData.ExternalPSI;
      FData.IsPurging := False;
      DoLog('[SYS] PRESSURE EQUALIZATION COMPLETE. VALVE CLOSED.', alNormal);
    end
    else
      FData.InternalPSI := FData.InternalPSI +
        Sign(FData.ExternalPSI - FData.InternalPSI) * PurgeStep;
  end
  else if FData.ValveAuto and (FData.BatteryReserve > 5.0) then
  begin
    // Auto-valve equalizes slowly (30% efficiency), struggling during rapid descent
    PurgeStep := (VALVE_PURGE_RATE * 0.30) * ADeltaTime;
    if Abs(FData.ExternalPSI - FData.InternalPSI) > 1.0 then
      FData.InternalPSI := FData.InternalPSI +
        Sign(FData.ExternalPSI - FData.InternalPSI) * Min(PurgeStep, Abs(FData.ExternalPSI - FData.InternalPSI));
  end;

  FData.PSIDifferential := Abs(FData.ExternalPSI - FData.InternalPSI);

  // Evaluate Hull Stress Damage from Pressure Differential
  if FData.PSIDifferential >= IMPLOSION_PSI_DIFF then
  begin
    FData.HullIntegrity := 0.0;
  end
  else if FData.PSIDifferential > SAFE_PSI_DIFF then
  begin
    StressFactor := (FData.PSIDifferential - SAFE_PSI_DIFF) / (IMPLOSION_PSI_DIFF - SAFE_PSI_DIFF);
    FData.HullIntegrity := Max(0.0, FData.HullIntegrity - (Sqr(StressFactor) * 14.0 * ADeltaTime));

    // Trigger CLI syntax corruption if hull falls below threshold
    if (FData.HullIntegrity < GLITCH_SYNTAX_THRESH) and (not FData.SyntaxCorrupted) then
    begin
      FData.SyntaxCorrupted := True;
      DoLog(MSG_BUFFER_CORRUPT, alWarning);
    end;
  end;

  // Sample Hull Stress for TAChart visualization every 100ms
  FStressSampleTimer := FStressSampleTimer + (ADeltaTime * 1000.0);
  if FStressSampleTimer >= CHART_UPDATE_MS then
  begin
    FStressSampleTimer := FStressSampleTimer - CHART_UPDATE_MS;
    StressFactor := EnsureRange(FData.PSIDifferential / IMPLOSION_PSI_DIFF, 0.0, 1.0);
    PushHullStressSample( (StressFactor * 100.0) + (Random * 3.5) );
  end;
end;

procedure TTelemetryManager.UpdateSubsystems(ADeltaTime: Double);
var
  EffectiveSweepSpeed, DrillRate: Double;
begin
  // Process Manual Reboot during EMP Blackout
  if FData.IsEMPBlackout then
  begin
    if FData.RebootProgress > 0.0 then
    begin
      FData.RebootProgress := Min(100.0, FData.RebootProgress + ((100.0 / EMP_REBOOT_TIME) * ADeltaTime));
      if FData.RebootProgress >= 100.0 then
      begin
        FData.IsEMPBlackout := False;
        FData.RebootProgress := 0.0;
        FData.SyntaxCorrupted := False; // Clear buffer corruption upon successful reboot
        DoLog('[SYS] KERNEL REBOOT SUCCESSFUL. SYSTEM RESTORED.', alNormal);
      end;
    end;
    Exit; // Suspend all other subsystem operations while blackout is active
  end;

  // Rotate Radar Sweep Line if Active Sonar is powered
  if (FData.SonarMode = smActive) and (FData.Power.Sonar > 0) and (FData.BatteryReserve > 0.0) then
  begin
    EffectiveSweepSpeed := SONAR_SWEEP_SPEED * (0.5 + (FData.Power.Sonar / 200.0));
    FData.SweepAngle := FData.SweepAngle + (EffectiveSweepSpeed * ADeltaTime);
    if FData.SweepAngle >= 360.0 then
      FData.SweepAngle := FData.SweepAngle - 360.0;
  end;

  // Advance Laser Drill Progress
  if FData.IsDrilling then
  begin
    if not FData.IsDrillJammed then
    begin
      DrillRate := (100.0 / DRILL_CYCLE_SECONDS) * (Max(50, FData.Power.Drill) / 100.0);
      FData.DrillProgress := Min(100.0, FData.DrillProgress + (DrillRate * ADeltaTime));

      // [QA Fix] Menggunakan probabilitas float berbasis waktu untuk memastikan peluang macet akurat ~15% per siklus
      if (FData.DrillProgress > 10.0) and (FData.DrillProgress < 90.0) and
         (Random < ((DRILL_JAM_PROB / 100.0) * (ADeltaTime / DRILL_CYCLE_SECONDS))) then
      begin
        FData.IsDrillJammed := True;
        DoLog(MSG_DRILL_JAM, alCritical);
      end;
    end;
  end;
end;

procedure TTelemetryManager.UpdateAlertAndGlitchState(ADeltaTime: Double);
var
  PressureGlitch, AnomalyGlitch, HullGlitch: Single;
  CurrentPressureAlert: TAlertLevel;
begin
  // Determine Pressure Alert Level and dispatch one-shot warning logs
  if FData.PSIDifferential >= CRITICAL_PSI_DIFF then
    CurrentPressureAlert := alCritical
  else if FData.PSIDifferential >= SAFE_PSI_DIFF then
    CurrentPressureAlert := alWarning
  else
    CurrentPressureAlert := alNormal;

  if CurrentPressureAlert <> FLastPressureAlert then
  begin
    if CurrentPressureAlert = alWarning then
      DoLog(MSG_PRESSURE_WARN, alWarning)
    else if CurrentPressureAlert = alCritical then
      DoLog(MSG_PRESSURE_CRIT, alCritical);
    FLastPressureAlert := CurrentPressureAlert;
  end;

  // Combine Pressure, Hull Integrity, Drill state, and Anomaly Proximity into Overall Alert Level
  if (CurrentPressureAlert = alCritical) or (FData.HullIntegrity < 25.0) or
     (FData.NearestAnomalyDist < ANOMALY_AGGRO_RANGE * 0.6) or FData.IsDrillJammed then
    FData.AlertLevel := alCritical
  else if (CurrentPressureAlert = alWarning) or (FData.BatteryReserve < 20.0) or
          (FData.NearestAnomalyDist < ANOMALY_AGGRO_RANGE) then
    FData.AlertLevel := alWarning
  else
    FData.AlertLevel := alNormal;

  // Compute CRT Visual Glitch Intensity (0.0 to 1.0)
  PressureGlitch := EnsureRange((FData.PSIDifferential - SAFE_PSI_DIFF) /
                    (IMPLOSION_PSI_DIFF - SAFE_PSI_DIFF), 0.0, 1.0);

  if FData.NearestAnomalyDist < GLITCH_EM_RANGE then
    AnomalyGlitch := EnsureRange(1.0 - (FData.NearestAnomalyDist / GLITCH_EM_RANGE), 0.0, 1.0)
  else
    AnomalyGlitch := 0.0;

  HullGlitch := EnsureRange((50.0 - FData.HullIntegrity) / 50.0, 0.0, 0.6);

  FData.GlitchIntensity := EnsureRange(Max(Max(PressureGlitch, AnomalyGlitch), HullGlitch), 0.0, 1.0);

  // Overwrite visual effects if experiencing complete EMP Blackout
  if FData.IsEMPBlackout then
    FData.GlitchIntensity := 1.0;
end;

procedure TTelemetryManager.PushHullStressSample(AStressValue: Single);
var
  i: Integer;
begin
  for i := 0 to High(FHullStressHistory) - 1 do
    FHullStressHistory[i] := FHullStressHistory[i + 1];
  FHullStressHistory[High(FHullStressHistory)] := EnsureRange(AStressValue, 0.0, 100.0);
end;

procedure TTelemetryManager.SetSonarMode(AMode: TSonarMode);
begin
  if FData.IsEMPBlackout then Exit;

  if FData.SonarMode = AMode then
    Exit;

  FData.SonarMode := AMode;
  if AMode = smActive then
    DoLog(MSG_SONAR_ACTIVE, alNormal)
  else
    DoLog(MSG_SONAR_PASSIVE, alNormal);
end;

procedure TTelemetryManager.SetPowerAllocation(ASubsystem: TSubsystem; AValue: Integer);
var
  ClampedVal: Integer;
begin
  if FData.IsEMPBlackout then Exit;

  ClampedVal := EnsureRange(AValue, 0, 100);
  case ASubsystem of
    sysEngine: FData.Power.Engine := ClampedVal;
    sysSonar:  FData.Power.Sonar  := ClampedVal;
    sysDrill:  FData.Power.Drill  := ClampedVal;
    sysCoreOS: FData.Power.CoreOS := Max(25, ClampedVal); // Prevent total OS shutdown
  end;
end;

procedure TTelemetryManager.SetThrusterCommand(ADir: TThrusterDir; APowerPercent: Double);
var
  EffectivePower, SpeedMag: Double;
begin
  if FData.IsEMPBlackout then Exit;

  if FData.BatteryReserve <= 0.0 then
    Exit;

  EffectivePower := (EnsureRange(APowerPercent, 0.0, 100.0) / 100.0) * (FData.Power.Engine / 100.0);
  SpeedMag := MAX_THRUSTER_SPEED * EffectivePower;

  case ADir of
    tdNorth: FTargetVelocity.Y := SpeedMag;
    tdSouth: FTargetVelocity.Y := -SpeedMag;
    tdEast:  FTargetVelocity.X := SpeedMag;
    tdWest:  FTargetVelocity.X := -SpeedMag;
    tdUp:    FTargetVelocity.Z := -SpeedMag; // Negative Z ascends toward surface
    tdDown:  FTargetVelocity.Z := BASE_DESCENT_RATE + SpeedMag;
    tdNone:  StopThrusters;
  end;
end;

procedure TTelemetryManager.StopThrusters;
begin
  FTargetVelocity.X := 0.0;
  FTargetVelocity.Y := 0.0;
  FTargetVelocity.Z := BASE_DESCENT_RATE; // Return to natural ballast sinking rate
end;

procedure TTelemetryManager.TriggerValvePurge;
begin
  if FData.IsEMPBlackout then Exit;

  if not FData.IsPurging then
  begin
    FData.IsPurging := True;
    DoLog('[SYS] MANUAL BALLAST & PRESSURE VALVE OPENED. EQUALIZING...', alNormal);
  end;
end;

procedure TTelemetryManager.ToggleAutoValve(AEnabled: Boolean);
begin
  if FData.IsEMPBlackout then Exit;
  FData.ValveAuto := AEnabled;
end;

function TTelemetryManager.StartDrillSequence: Boolean;
begin
  Result := False;
  if FData.IsEMPBlackout then Exit;

  if FData.IsDrilling then
    Exit;

  // [QA Fix] Cegah pemain memulai ekstraksi jika kapal masih meluncur akibat inersia.
  // Mencegah pembatalan ekstraksi secara instan sedetik setelah tombol ditekan.
  if Hypot(FData.Velocity.X, FData.Velocity.Y) > 1.2 then
  begin
    DoLog('[ERR] VESSEL IN MOTION. HALT LATERAL DRIFT BEFORE DRILLING.', alWarning);
    Exit;
  end;

  if FData.Power.Drill < 20 then
    FData.Power.Drill := 80; // Auto-allocate drill power when triggered via CLI

  StopThrusters;
  FData.IsDrilling := True;
  FData.IsDrillJammed := False;
  FData.DrillProgress := 0.0;
  DoLog(MSG_DRILL_START, alNormal);
  Result := True;
end;

procedure TTelemetryManager.ReverseDrillSequence;
begin
  if FData.IsEMPBlackout then Exit;

  if FData.IsDrilling and FData.IsDrillJammed then
  begin
    FData.IsDrillJammed := False;
    // Penalize progress slightly when clearing jam
    FData.DrillProgress := Max(0.0, FData.DrillProgress - 5.0);
    DoLog(MSG_DRILL_REV, alNormal);
  end
  else if FData.IsDrilling then
  begin
     DoLog('[SYS] DRILL REVERSED. ABORTING EXTRACTION...', alNormal);
     CancelDrillSequence('');
  end;
end;

procedure TTelemetryManager.CancelDrillSequence(const AReason: string);
begin
  if not FData.IsDrilling then
    Exit;

  FData.IsDrilling := False;
  FData.IsDrillJammed := False;
  FData.DrillProgress := 0.0;
  FData.Power.Drill := 0;
  if AReason <> '' then
    DoLog(AReason, alWarning);
end;

procedure TTelemetryManager.RunSystemDiagnostic;
begin
  if FData.IsEMPBlackout then Exit;

  FData.SyntaxCorrupted := False;
  DoLog(MSG_DIAG_COMPLETE, alNormal);
end;

procedure TTelemetryManager.IncrementMinerals;
begin
  Inc(FData.MineralsCollected);
  DoLog(Format('%s (%d/%d)', [MSG_DRILL_SUCCESS, FData.MineralsCollected, REQUIRED_MINERALS]), alNormal);
end;

procedure TTelemetryManager.NotifyBlackboxRecovered;
begin
  DoLog(MSG_BLACKBOX_SUCCESS, alNormal);
end;

function TTelemetryManager.TryDeployDecoy: Boolean;
begin
  if FData.IsEMPBlackout then Exit(False);

  if FData.BatteryReserve >= COST_DEPLOY_DECOY then
  begin
    FData.BatteryReserve := FData.BatteryReserve - COST_DEPLOY_DECOY;
    DoLog(MSG_DECOY_DEPLOY, alNormal);
    Result := True;
  end
  else
  begin
    DoLog('[ERR] INSUFFICIENT BATTERY RESERVE TO DEPLOY DECOY.', alWarning);
    Result := False;
  end;
end;

procedure TTelemetryManager.TriggerEMPBlackout;
begin
  if FData.IsEMPBlackout then Exit;

  StopThrusters;
  CancelDrillSequence('[SYS] DRILL ABORTED DUE TO KERNEL PANIC.');

  FData.IsEMPBlackout := True;
  FData.RebootProgress := 0.0;
  FData.SyntaxCorrupted := True;

  // Power drains and system cuts
  FData.Power.Engine := 0;
  FData.Power.Sonar := 0;
  FData.Power.Drill := 0;

  FData.SonarMode := smPassive;
  FData.ValveAuto := False;
  FData.IsPurging := False;

  DoLog(MSG_EMP_STRIKE, alCritical);
end;

procedure TTelemetryManager.InitiateReboot;
begin
  if FData.IsEMPBlackout and (FData.RebootProgress <= 0.0) then
  begin
    FData.RebootProgress := 0.01; // Kickstart the reboot timer in UpdateSubsystems
    DoLog(MSG_REBOOT_INIT, alNormal);
  end;
end;

procedure TTelemetryManager.ApplyExternalDamage(AAmount: Double; const AReasonMsg: string);
begin
  FData.HullIntegrity := Max(0.0, FData.HullIntegrity - AAmount);
  PushHullStressSample(100.0);

  if (FData.HullIntegrity < GLITCH_SYNTAX_THRESH) or (AAmount >= 15.0) then
    FData.SyntaxCorrupted := True;

  if AReasonMsg <> '' then
    DoLog(AReasonMsg, alCritical);
end;

procedure TTelemetryManager.UpdateAnomalyMetrics(ACount: Integer; ANearestDist: Double; ANearestPan: Single);
begin
  FData.EntitiesDetected := ACount;
  FData.NearestAnomalyDist := ANearestDist;
  FData.NearestAnomalyPan := ANearestPan;
end;

end.
