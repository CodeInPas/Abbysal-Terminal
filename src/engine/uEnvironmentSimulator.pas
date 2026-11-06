unit uEnvironmentSimulator;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Generics.Collections, uConstants, uTypes;

const
  MAX_TERRAIN_BLIPS  = 20;
  MAX_MINERAL_BLIPS  = 6;
  MAX_ANOMALY_BLIPS  = 2;
  MAX_BLACKBOX_BLIPS = 1;    // New: Lore blackbox per sector
  MINERAL_LOCK_RANGE = 85.0; // Maximum distance (meters) to initiate laser drill

type
  { TEnvironmentSimulator - Manages spatial topography, mineral nodes, and Leviathan AI }
  TEnvironmentSimulator = class
  private
    FBlips: TBlipList;
    FNextBlipID: Integer;
    FLastSweepAngle: Single;
    FAnomalyWarned: Boolean;
    FAnomalyCritWarned: Boolean;
    FOnLog: TLogEvent;

    procedure DoLog(const AMsg: string; ALevel: TAlertLevel = alNormal);
    function CreateRandomBlip(ABlipType: TBlipType; const ACenter: TVector3D;
      AMinDist, AMaxDist: Double): TSonarBlip;
    procedure MaintainSectorPopulation(const AVesselPos: TVector3D);
    function IsAngleInSweep(AAngle, AStartAngle, AEndAngle: Single): Boolean; inline;
  public
    constructor Create;
    destructor Destroy; override;

    { Clears and regenerates the initial abyssal sector }
    procedure ResetEnvironment(const AStartPos: TVector3D);

    { Advances entity AI, sonar sweep intersections, and proximity collisions }
    procedure UpdateEnvironment(ADeltaTime: Double; const ATelemetry: TTelemetryData;
      out AActiveAnomalies: Integer; out ANearestAnomalyDist: Double;
      out ANearestAnomalyPan: Single; out AStrikeDamage: Double;
      out APingContact: Boolean);

    { Locates the closest unextracted mineral node for drilling validation }
    function GetNearestMineralDistance(const AVesselPos: TVector3D): Double;

    { Marks the closest mineral node (or blackbox) within drilling range as extracted }
    function ExtractNearestTarget(const AVesselPos: TVector3D; out AIsBlackbox: Boolean): Boolean;

    { Spawns an acoustic decoy at the vessel's current position }
    procedure SpawnDecoy(const AVesselPos: TVector3D);

    property Blips: TBlipList read FBlips;
    property OnLogMessage: TLogEvent read FOnLog write FOnLog;
  end;

implementation

{ TEnvironmentSimulator }

constructor TEnvironmentSimulator.Create;
begin
  inherited Create;
  Randomize;
  FBlips := TBlipList.Create;
  FNextBlipID := 1;
  FLastSweepAngle := 0.0;
  FAnomalyWarned := False;
  FAnomalyCritWarned := False;
end;

destructor TEnvironmentSimulator.Destroy;
begin
  FBlips.Free;
  inherited Destroy;
end;

procedure TEnvironmentSimulator.DoLog(const AMsg: string; ALevel: TAlertLevel);
begin
  if Assigned(FOnLog) then
    FOnLog(AMsg, ALevel);
end;

function TEnvironmentSimulator.CreateRandomBlip(ABlipType: TBlipType;
  const ACenter: TVector3D; AMinDist, AMaxDist: Double): TSonarBlip;
var
  Angle, Dist, ZOffset, DriftAngle: Double;
begin
  FillChar(Result, SizeOf(TSonarBlip), 0);
  Result.ID := FNextBlipID;
  Inc(FNextBlipID);

  Angle := Random * 2.0 * Pi;
  Dist := AMinDist + (Random * (AMaxDist - AMinDist));
  ZOffset := (Random - 0.35) * 160.0; // Slightly biased toward deeper coordinates

  Result.Position.X := ACenter.X + (Sin(Angle) * Dist);
  Result.Position.Y := ACenter.Y + (Cos(Angle) * Dist);
  Result.Position.Z := EnsureRange(ACenter.Z + ZOffset, 50.0, MAX_TRENCH_DEPTH);

  Result.BlipType := ABlipType;
  Result.Intensity := 0.0;
  Result.IsExtracted := False;
  Result.IsAggressive := False;
  Result.Lifetime := 0.0;

  case ABlipType of
    btTerrain:
      begin
        Result.Radius := 2.5 + (Random * 3.0);
        Result.Velocity := TVector3D.Create(0.0, 0.0, 0.0);
      end;
    btMineral:
      begin
        Result.Radius := 4.0;
        Result.Velocity := TVector3D.Create(0.0, 0.0, 0.0);
      end;
    btAnomaly:
      begin
        Result.Radius := 7.5;
        DriftAngle := Random * 2.0 * Pi;
        Result.Velocity := TVector3D.Create(
          Sin(DriftAngle) * (ANOMALY_BASE_SPEED * 0.4),
          Cos(DriftAngle) * (ANOMALY_BASE_SPEED * 0.4),
          0.0
        );
      end;
    btDecoy:
      begin
        Result.Radius := 3.5;
        // Decoy is stationary relative to water column (sinks slowly)
        Result.Position := ACenter; // Spawn exactly at vessel
        Result.Velocity := TVector3D.Create(0.0, 0.0, BASE_DESCENT_RATE * 0.5);
        Result.Intensity := 1.0; // Instantly visible
        Result.Lifetime := DECOY_LIFETIME;
      end;
    btBlackbox:
      begin
        Result.Radius := 2.5; // Smaller, harder to find
        Result.Velocity := TVector3D.Create(0.0, 0.0, 0.0);
      end;
  end;
end;

procedure TEnvironmentSimulator.SpawnDecoy(const AVesselPos: TVector3D);
begin
  FBlips.Add(CreateRandomBlip(btDecoy, AVesselPos, 0.0, 0.0));
end;

procedure TEnvironmentSimulator.ResetEnvironment(const AStartPos: TVector3D);
var
  i: Integer;
  B: TSonarBlip;
begin
  FBlips.Clear;
  FNextBlipID := 1;
  FLastSweepAngle := 0.0;
  FAnomalyWarned := False;
  FAnomalyCritWarned := False;

  // Populate initial surrounding trench topography
  for i := 1 to MAX_TERRAIN_BLIPS do
    FBlips.Add(CreateRandomBlip(btTerrain, AStartPos, 60.0, SONAR_MAX_RANGE * 0.95));

  // Populate initial mineral veins
  for i := 1 to MAX_MINERAL_BLIPS do
    FBlips.Add(CreateRandomBlip(btMineral, AStartPos, 90.0, SONAR_MAX_RANGE * 0.85));

  // Spawn initial deep-sea biological anomalies at outer perimeter
  for i := 1 to MAX_ANOMALY_BLIPS do
    FBlips.Add(CreateRandomBlip(btAnomaly, AStartPos, ANOMALY_AGGRO_RANGE * 1.2, SONAR_MAX_RANGE));

  // [QA Fix] Always allocate 1 Blackbox slot so it can be recycled.
  // Use depth offset to create rarity instead of random omission.
  B := CreateRandomBlip(btBlackbox, AStartPos, 120.0, SONAR_MAX_RANGE * 0.75);
  if Random(100) > 65 then
    B.Position.Z := AStartPos.Z + 350.0 + (Random * 150.0); // Spawns far below if unlucky
  FBlips.Add(B);
end;

procedure TEnvironmentSimulator.MaintainSectorPopulation(const AVesselPos: TVector3D);
var
  i: Integer;
  B: TSonarBlip;
  Dist2D, DistZ: Double;
begin
  for i := FBlips.Count - 1 downto 0 do
  begin
    B := FBlips[i];

    // Remove expired decoys
    if (B.BlipType = btDecoy) and (B.Lifetime <= 0.0) then
    begin
      FBlips.Delete(i);
      Continue;
    end;

    Dist2D := B.Position.Distance2D(AVesselPos);
    DistZ := Abs(B.Position.Z - AVesselPos.Z);

    // Recycle objects that fall outside the active sensor bubble as vessel moves
    if (Dist2D > SONAR_MAX_RANGE * 1.15) or (DistZ > 260.0) or
       ((B.BlipType in [btMineral, btBlackbox]) and B.IsExtracted and (Dist2D > 120.0)) then
    begin
      case B.BlipType of
        btTerrain:
          B := CreateRandomBlip(btTerrain, AVesselPos, SONAR_MAX_RANGE * 0.5, SONAR_MAX_RANGE);
        btMineral:
          B := CreateRandomBlip(btMineral, AVesselPos, 110.0, SONAR_MAX_RANGE * 0.9);
        btAnomaly:
          B := CreateRandomBlip(btAnomaly, AVesselPos, ANOMALY_AGGRO_RANGE * 1.1, SONAR_MAX_RANGE);
        btBlackbox:
          begin
            B := CreateRandomBlip(btBlackbox, AVesselPos, 150.0, SONAR_MAX_RANGE * 0.85);
            // [QA Fix] 60% chance to spawn deep below so it's not instantly found when recycled
            if Random(100) < 60 then
              B.Position.Z := AVesselPos.Z + 300.0 + (Random * 250.0);
          end;
      end;
      FBlips[i] := B;
    end;
  end;
end;

function TEnvironmentSimulator.IsAngleInSweep(AAngle, AStartAngle, AEndAngle: Single): Boolean;
begin
  if AStartAngle <= AEndAngle then
    Result := (AAngle >= AStartAngle) and (AAngle <= AEndAngle)
  else
    // Handle 360 -> 0 degree wrap-around
    Result := (AAngle >= AStartAngle) or (AAngle <= AEndAngle);
end;

procedure TEnvironmentSimulator.UpdateEnvironment(ADeltaTime: Double;
  const ATelemetry: TTelemetryData; out AActiveAnomalies: Integer;
  out ANearestAnomalyDist: Double; out ANearestAnomalyPan: Single;
  out AStrikeDamage: Double; out APingContact: Boolean);
var
  i, j: Integer;
  B, TargetB: TSonarBlip;
  Dist2D, Dist3D, dX, dY, dZ, BlipAngle, SpeedMultiplier, AggroRadius, PanVal, DriftAngle: Double;
  SonarActive, HasActiveDecoy: Boolean;
  TargetPos: TVector3D;
begin
  AActiveAnomalies := 0;
  ANearestAnomalyDist := 9999.0;
  ANearestAnomalyPan := 0.0;
  AStrikeDamage := 0.0;
  APingContact := False;

  MaintainSectorPopulation(ATelemetry.Position);

  SonarActive := (ATelemetry.SonarMode = smActive) and
                 (ATelemetry.Power.Sonar > 0) and
                 (ATelemetry.BatteryReserve > 0.0);

  // Depth scaling: anomalies move faster and sense further in deeper zones
  SpeedMultiplier := 1.0 + ((ATelemetry.Position.Z / MAX_TRENCH_DEPTH) * 0.55);
  AggroRadius := ANOMALY_AGGRO_RANGE * (1.0 + ((ATelemetry.Position.Z / MAX_TRENCH_DEPTH) * 0.25));

  // Check if any decoy is currently active to hijack anomaly AI
  HasActiveDecoy := False;
  TargetPos := ATelemetry.Position;
  for j := 0 to FBlips.Count - 1 do
  begin
    if FBlips[j].BlipType = btDecoy then
    begin
      HasActiveDecoy := True;
      TargetPos := FBlips[j].Position;
      Break;
    end;
  end;

  for i := 0 to FBlips.Count - 1 do
  begin
    B := FBlips[i];

    // 1. Decoy Lifetime decay
    if B.BlipType = btDecoy then
    begin
      B.Lifetime := Max(0.0, B.Lifetime - ADeltaTime);
      B.Intensity := (B.Lifetime / DECOY_LIFETIME); // Fade out as it dies

      // Sink decoy slowly
      B.Position.Z := B.Position.Z + (B.Velocity.Z * ADeltaTime);
    end;

    // 2. Phosphor persistence decay (for radar blips)
    if (B.Intensity > 0.0) and (B.BlipType <> btDecoy) then
      B.Intensity := Max(0.0, B.Intensity - (SONAR_BLIP_FADE_RATE * ADeltaTime));

    // 3. Biological Anomaly AI & Kinematics
    if B.BlipType = btAnomaly then
    begin
      Dist3D := B.Position.Distance3D(ATelemetry.Position);

      if Dist3D < ANOMALY_DETECT_RANGE then
        Inc(AActiveAnomalies);

      if Dist3D < ANearestAnomalyDist then
      begin
        ANearestAnomalyDist := Dist3D;

        // Calculate Audio Panning based on relative X position
        // -1.0 = Full Left (West), 1.0 = Full Right (East)
        dX := B.Position.X - ATelemetry.Position.X;
        if Dist3D > 0.1 then
        begin
          PanVal := EnsureRange(dX / (ANOMALY_AGGRO_RANGE * 0.8), -1.0, 1.0);
          ANearestAnomalyPan := PanVal;
        end;
      end;

      // Acoustic aggro check: Active Sonar, Laser Drilling, OR Active Decoy attracts the Leviathan
      if HasActiveDecoy or ((SonarActive or ATelemetry.IsDrilling) and (Dist3D <= AggroRadius)) then
      begin
        B.IsAggressive := True;

        // Target is either the Decoy or the Vessel
        dX := TargetPos.X - B.Position.X;
        dY := TargetPos.Y - B.Position.Y;
        dZ := TargetPos.Z - B.Position.Z;

        Dist3D := B.Position.Distance3D(TargetPos);

        if Dist3D > 0.001 then
        begin
          B.Velocity.X := (dX / Dist3D) * ANOMALY_BASE_SPEED * SpeedMultiplier;
          B.Velocity.Y := (dY / Dist3D) * ANOMALY_BASE_SPEED * SpeedMultiplier;
          B.Velocity.Z := (dZ / Dist3D) * ANOMALY_BASE_SPEED * SpeedMultiplier;
        end;
      end
      else
      begin
        // Passive sonar allows the vessel to hide; entity loses lock and wanders off
        if B.IsAggressive and (not SonarActive) and (not ATelemetry.IsDrilling) then
        begin
          B.IsAggressive := False;

          // [QA Fix] Assign new random patrol drift instead of instantly freezing (statue exploit)
          DriftAngle := Random * 2.0 * Pi;
          B.Velocity.X := Sin(DriftAngle) * (ANOMALY_BASE_SPEED * 0.4);
          B.Velocity.Y := Cos(DriftAngle) * (ANOMALY_BASE_SPEED * 0.4);
          B.Velocity.Z := (Random - 0.5) * (ANOMALY_BASE_SPEED * 0.3); // Slight vertical drift
        end;
      end;

      // Advance anomaly position
      B.Position.X := B.Position.X + (B.Velocity.X * ADeltaTime);
      B.Position.Y := B.Position.Y + (B.Velocity.Y * ADeltaTime);
      B.Position.Z := EnsureRange(B.Position.Z + (B.Velocity.Z * ADeltaTime), 50.0, MAX_TRENCH_DEPTH);

      // Evaluate physical hull collision / Leviathan strike ONLY with the Vessel
      Dist3D := B.Position.Distance3D(ATelemetry.Position);
      if Dist3D <= ANOMALY_STRIKE_RANGE then
      begin
        AStrikeDamage := 24.0 + (Random * 10.0);
        // Reposition anomaly to outer perimeter after strike impact
        B := CreateRandomBlip(btAnomaly, ATelemetry.Position, ANOMALY_AGGRO_RANGE * 1.15, SONAR_MAX_RANGE * 0.95);
        ANearestAnomalyDist := B.Position.Distance3D(ATelemetry.Position);
        ANearestAnomalyPan := 0.0;
      end;
    end;

    // 4. Active Sonar Sweep Detection
    if SonarActive and (not B.IsExtracted) and (B.BlipType <> btDecoy) then
    begin
      Dist2D := B.Position.Distance2D(ATelemetry.Position);
      if (Dist2D <= SONAR_MAX_RANGE) and (Abs(B.Position.Z - ATelemetry.Position.Z) <= 200.0) then
      begin
        dX := B.Position.X - ATelemetry.Position.X;
        dY := B.Position.Y - ATelemetry.Position.Y;

        // Calculate radar bearing in degrees (0 = North/+Y, 90 = East/+X)
        BlipAngle := RadToDeg(ArcTan2(dX, dY));
        if BlipAngle < 0.0 then
          BlipAngle := BlipAngle + 360.0;

        if IsAngleInSweep(BlipAngle, FLastSweepAngle, ATelemetry.SweepAngle) then
        begin
          B.Intensity := 1.0;
          if B.BlipType in [btMineral, btAnomaly, btBlackbox] then
            APingContact := True;
        end;
      end;
    end;

    FBlips[i] := B;
  end;

  FLastSweepAngle := ATelemetry.SweepAngle;

  // 5. Dispatch proximity warning logs with hysteresis (supressed if decoy is active)
  if not HasActiveDecoy then
  begin
    if (ANearestAnomalyDist < ANOMALY_AGGRO_RANGE * 0.65) and (not FAnomalyCritWarned) then
    begin
      FAnomalyCritWarned := True;
      DoLog(MSG_ENTITY_PROXIMITY, alCritical);
    end
    else if (ANearestAnomalyDist < ANOMALY_DETECT_RANGE * 0.85) and (not FAnomalyWarned) then
    begin
      FAnomalyWarned := True;
      DoLog(MSG_ENTITY_DETECT, alWarning);
    end
    else if ANearestAnomalyDist > ANOMALY_DETECT_RANGE then
    begin
      FAnomalyWarned := False;
      FAnomalyCritWarned := False;
    end;
  end;
end;

function TEnvironmentSimulator.GetNearestMineralDistance(const AVesselPos: TVector3D): Double;
var
  i: Integer;
  B: TSonarBlip;
  Dist: Double;
begin
  Result := 9999.0;
  for i := 0 to FBlips.Count - 1 do
  begin
    B := FBlips[i];
    if (B.BlipType in [btMineral, btBlackbox]) and (not B.IsExtracted) then
    begin
      Dist := B.Position.Distance2D(AVesselPos);
      if Dist < Result then
        Result := Dist;
    end;
  end;
end;

function TEnvironmentSimulator.ExtractNearestTarget(const AVesselPos: TVector3D; out AIsBlackbox: Boolean): Boolean;
var
  i, BestIdx: Integer;
  B: TSonarBlip;
  Dist, BestDist: Double;
begin
  Result := False;
  AIsBlackbox := False;
  BestIdx := -1;
  BestDist := 9999.0;

  for i := 0 to FBlips.Count - 1 do
  begin
    B := FBlips[i];
    if (B.BlipType in [btMineral, btBlackbox]) and (not B.IsExtracted) then
    begin
      Dist := B.Position.Distance2D(AVesselPos);
      if Dist < BestDist then
      begin
        BestDist := Dist;
        BestIdx := i;
      end;
    end;
  end;

  if (BestIdx >= 0) and (BestDist <= MINERAL_LOCK_RANGE * 1.5) then
  begin
    B := FBlips[BestIdx];
    B.IsExtracted := True;
    B.Intensity := 0.0;

    if B.BlipType = btBlackbox then
      AIsBlackbox := True;

    FBlips[BestIdx] := B;
    Result := True;
  end;
end;

end.
