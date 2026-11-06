unit uTypes;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, Graphics, Math, Generics.Collections, uConstants;

type
  // ===========================================================================
  // CORE ENUMERATIONS
  // ===========================================================================

  { Game state machine states }
  TGameState = (
    gsBooting,
    gsDescent,
    gsDrilling,
    gsCrisis,
    gsAscent,
    gsEMPBlackout,
    gsVictory,
    gsGameOver
  );

  { Specific cause of mission failure }
  TGameOverReason = (
    gorNone,
    gorImplosion,
    gorPowerDepleted,
    gorEntityStrike
  );

  { Acoustic transducer operation modes }
  TSonarMode = (
    smPassive,
    smActive
  );

  { Monochromatic CRT monitor phosphor themes }
  TCRTTheme = (
    ctGreen,
    ctAmber
  );

  { System warning levels for logs and HUD indicators }
  TAlertLevel = (
    alNormal,
    alWarning,
    alCritical
  );

  { Classification of acoustic signatures on radar }
  TBlipType = (
    btTerrain,
    btMineral,
    btAnomaly,
    btDecoy,
    btBlackbox    // New: Recoverable flight recorder
  );

  { Parsed CLI command tokens }
  TCommandType = (
    ctUnknown,
    ctHelp,
    ctStatus,
    ctClear,
    ctSonar,
    ctThruster,
    ctThrusterStop,
    ctPurgeValve,
    ctRoutePower,
    ctRunDrill,
    ctRunDiag,
    ctRunDrillRev,
    ctRunSysReboot,
    ctDeployDecoy,
    ctReadLog       // New: Command to read recovered lore logs
  );

  { Propulsion vector directions }
  TThrusterDir = (
    tdNone,
    tdUp,
    tdDown,
    tdNorth,
    tdSouth,
    tdEast,
    tdWest
  );

  { Bathyscaphe power distribution targets }
  TSubsystem = (
    sysEngine,
    sysSonar,
    sysDrill,
    sysCoreOS
  );

  // ===========================================================================
  // SPATIAL & MATHEMATICAL STRUCTURES
  // ===========================================================================

  { 3D coordinate and velocity vector (Z represents Depth in meters) }
  TVector3D = record
    X: Double;
    Y: Double;
    Z: Double;
    class function Create(const AX, AY, AZ: Double): TVector3D; static; inline;
    function Distance2D(const AOther: TVector3D): Double; inline;
    function Distance3D(const AOther: TVector3D): Double; inline;
  end;

  { Fixed-size array for real-time audio spectrum & hull stress plotting }
  TFFTDataArray = array[0..FFT_SAMPLE_COUNT - 1] of Single;

  // ===========================================================================
  // SIMULATION & TELEMETRY STRUCTURES
  // ===========================================================================

  { Represents an object or entity detected by sonar }
  TSonarBlip = record
    ID: Integer;
    Position: TVector3D;
    Velocity: TVector3D;
    BlipType: TBlipType;
    Intensity: Single;     // 0.0 (invisible) to 1.0 (freshly pinged phosphor glow)
    Radius: Single;        // Blip visual size on radar
    IsExtracted: Boolean;  // Used for mineral nodes & blackboxes
    IsAggressive: Boolean; // Used for biological anomalies
    Lifetime: Single;      // Used for tracking decoy expiration time
  end;

  { Percentage power routing across vessel subsystems (0..100) }
  TPowerAllocation = record
    Engine: Integer;
    Sonar: Integer;
    Drill: Integer;
    CoreOS: Integer;
  end;

  { Master snapshot of all vessel telemetry metrics }
  TTelemetryData = record
    BootStep: Integer;           // Tracker untuk animasi Boot-up sequence (0..BOOT_SEQ_LINES)

    Position: TVector3D;
    Velocity: TVector3D;
    HullIntegrity: Double;
    BatteryReserve: Double;
    ExternalPSI: Double;
    InternalPSI: Double;
    PSIDifferential: Double;

    SonarMode: TSonarMode;
    SweepAngle: Single;          // Current radar sweep line angle (0..360)

    ValveAuto: Boolean;          // Automatic vs Manual pressure equalization
    IsPurging: Boolean;          // Active pressure valve purge state
    IsDrilling: Boolean;         // Active laser drill state
    DrillProgress: Single;       // 0.0 to 100.0%
    IsDrillJammed: Boolean;      // Mechanical failure state for drill

    MineralsCollected: Integer;
    EntitiesDetected: Integer;
    NearestAnomalyDist: Double;
    NearestAnomalyPan: Single;   // Panning -1.0 (Left) to 1.0 (Right) for spatial audio

    AlertLevel: TAlertLevel;
    GlitchIntensity: Single;     // 0.0 (clean) to 1.0 (heavy EM/pressure distortion)
    SyntaxCorrupted: Boolean;    // True when CLI buffer suffers EM interference
    IsEMPBlackout: Boolean;      // True when screen goes completely black
    RebootProgress: Single;      // Progress of system reboot (0.0 to 100.0%)

    Power: TPowerAllocation;
  end;

  { Delayed CLI instruction waiting in the umbilical latency queue }
  TQueuedCommand = record
    CommandType: TCommandType;
    RawText: string;
    StringParam: string;
    NumericParam: Double;
    TargetSubsys: TSubsystem;
    TargetDir: TThrusterDir;
    ExecuteTick: QWord;          // GetTickCount64 target timestamp for execution
  end;

  { Active color scheme mapped to the selected CRT Theme }
  TColorPalette = record
    Background: TColor;
    PanelBg: TColor;
    Primary: TColor;
    Dim: TColor;
    Glow: TColor;
    AlertWarn: TColor;
    AlertCrit: TColor;
  end;

  // ===========================================================================
  // GENERIC COLLECTIONS & EVENT DELEGATES
  // ===========================================================================

  { Dynamic list for managing active radar blips and world objects }
  TBlipList = specialize TList<TSonarBlip>;

  { FIFO-style list for handling signal latency command queuing }
  TCommandQueue = specialize TList<TQueuedCommand>;

  { Ring-buffer list for CLI Command History (Up/Down arrow recall) }
  TCommandHistory = specialize TList<string>;

  { Observer pattern delegates for decoupling Engine from LCL UI }
  TLogEvent = procedure(const AMsg: string; ALevel: TAlertLevel = alNormal) of object;
  TTelemetryUpdateEvent = procedure(const AData: TTelemetryData) of object;
  TStateChangeEvent = procedure(ANewState: TGameState; AReason: TGameOverReason) of object;
  TAudioPanEvent = procedure(APanSource: Integer; APanValue: Single) of object;

  // ===========================================================================
  // HELPER FUNCTIONS
  // ===========================================================================

  { Returns the color structure corresponding to the active CRT monitor theme }
  function GetThemePalette(ATheme: TCRTTheme): TColorPalette; inline;

implementation

{ TVector3D }

class function TVector3D.Create(const AX, AY, AZ: Double): TVector3D;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.Z := AZ;
end;

function TVector3D.Distance2D(const AOther: TVector3D): Double;
begin
  Result := Hypot(X - AOther.X, Y - AOther.Y);
end;

function TVector3D.Distance3D(const AOther: TVector3D): Double;
var
  dX, dY, dZ: Double;
begin
  dX := X - AOther.X;
  dY := Y - AOther.Y;
  dZ := Z - AOther.Z;
  Result := Sqrt((dX * dX) + (dY * dY) + (dZ * dZ));
end;

{ Helper Functions }

function GetThemePalette(ATheme: TCRTTheme): TColorPalette;
begin
  Result.Background := CLR_BG_TERMINAL;
  Result.PanelBg    := CLR_BG_PANEL;
  Result.AlertWarn  := CLR_ALERT_WARN;
  Result.AlertCrit  := CLR_ALERT_CRITICAL;

  case ATheme of
    ctGreen:
      begin
        Result.Primary := CLR_GREEN_PRIMARY;
        Result.Dim     := CLR_GREEN_DIM;
        Result.Glow    := CLR_GREEN_GLOW;
      end;
    ctAmber:
      begin
        Result.Primary := CLR_AMBER_PRIMARY;
        Result.Dim     := CLR_AMBER_DIM;
        Result.Glow    := CLR_AMBER_GLOW;
      end;
  end;
end;

end.
