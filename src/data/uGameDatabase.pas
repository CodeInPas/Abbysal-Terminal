unit uGameDatabase;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SQLDB, SQLite3Conn, Generics.Collections,
  uConstants, uTypes;

type
  { In-memory structure for zero-stutter telemetry buffering }
  TTelemetryLogItem = record
    Timestamp: TDateTime;
    Depth: Double;
    HullIntegrity: Double;
    BatteryReserve: Double;
    ExternalPSI: Double;
    PSIDiff: Double;
    AlertLevel: Integer;
  end;

  { Structure representing an extracted deep-sea mineral record }
  TMineralSampleItem = record
    SampleID: Integer;
    SampleCode: string;
    MineralName: string;
    ExtractionDepth: Double;
    PurityPercent: Double;
    Timestamp: TDateTime;
  end;

  TTelemetryBuffer = specialize TList<TTelemetryLogItem>;
  TMineralList = specialize TList<TMineralSampleItem>;

  { TGameDatabase - Manages SQLite persistence via TSQLite3Connection with RAM buffering }
  TGameDatabase = class
  private
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    FQuery: TSQLQuery;
    FTelemetryBuffer: TTelemetryBuffer;
    FMineralCache: TMineralList;
    FIsConnected: Boolean;
    FLastLogTick: QWord;
    FBlackboxCount: Integer;

    procedure CreateTables;
    function GenerateMineralName(ADepth: Double; out APurity: Double): string;
  public
    constructor Create;
    destructor Destroy; override;

    { Initializes SQLite connection; falls back to :memory: if disk I/O fails }
    function Initialize: Boolean;

    { Buffers telemetry in RAM to prevent disk I/O micro-stutters during 60Hz loop }
    procedure RecordTelemetryTick(const AData: TTelemetryData);

    { Logs a discrete mission or anomaly event }
    procedure LogEvent(const AEventType, ADescription: string; ADepth: Double);

    { Registers a newly drilled mineral sample into cache and database }
    function RegisterMineralExtraction(ADepth: Double): TMineralSampleItem;

    { Registers a recovered blackbox and inserts its lore text into SQLite }
    function RegisterBlackboxRecovery(ADepth: Double): Integer;

    { Reads decrypted lore text from a recovered blackbox by ID }
    function ReadBlackboxLore(ALogID: Integer): string;

    { Commits all buffered RAM records to SQLite in a single atomic transaction }
    procedure FlushBufferToDisk;

    { Retrieves cached mineral list for Panel 2 UI without querying disk }
    property MineralSamples: TMineralList read FMineralCache;
    property IsConnected: Boolean read FIsConnected;
  end;

implementation

const
  BUFFER_FLUSH_LIMIT = 60; // Auto-flush every 60 seconds of buffered telemetry

{ TGameDatabase }

constructor TGameDatabase.Create;
begin
  inherited Create;
  FTelemetryBuffer := TTelemetryBuffer.Create;
  FMineralCache := TMineralList.Create;
  FConnection := TSQLite3Connection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);
  FQuery := TSQLQuery.Create(nil);

  FConnection.Transaction := FTransaction;
  FQuery.DataBase := FConnection;
  FQuery.Transaction := FTransaction;

  FIsConnected := False;
  FLastLogTick := 0;
  FBlackboxCount := 0;
end;

destructor TGameDatabase.Destroy;
begin
  if FIsConnected then
  begin
    FlushBufferToDisk;
    FConnection.Close(True);
  end;

  FQuery.Free;
  FTransaction.Free;
  FConnection.Free;
  FMineralCache.Free;
  FTelemetryBuffer.Free;
  inherited Destroy;
end;

function TGameDatabase.Initialize: Boolean;
var
  DBFilePath: string;
  DBDir: string;
begin
  Result := False;
  try
    DBFilePath := ExpandFileName(ExtractFilePath(ParamStr(0)) + PATH_DB_FILE);
    DBDir := ExtractFileDir(DBFilePath);

    if (DBDir <> '') and (not DirectoryExists(DBDir)) then
      ForceDirectories(DBDir);

    FConnection.DatabaseName := DBFilePath;
    FConnection.Open;

    // Optimize SQLite for high-speed asynchronous simulation logging
    FTransaction.StartTransaction;
    FConnection.ExecuteDirect('PRAGMA synchronous = OFF;');
    FConnection.ExecuteDirect('PRAGMA journal_mode = MEMORY;');
    FTransaction.Commit;

    CreateTables;
    FIsConnected := True;
    Result := True;
  except
    on E: Exception do
    begin
      // Fallback to pure in-memory SQLite database if file access fails
      try
        FConnection.Close(True);
        FConnection.DatabaseName := PATH_DB_MEMORY;
        FConnection.Open;
        CreateTables;
        FIsConnected := True;
        Result := True;
      except
        FIsConnected := False;
      end;
    end;
  end;
end;

procedure TGameDatabase.CreateTables;
begin
  if not FTransaction.Active then
    FTransaction.StartTransaction;

  // Table 1: Continuous Telemetry Stream
  FConnection.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS telemetry_logs (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  log_time DATETIME,' +
    '  depth REAL,' +
    '  hull_integrity REAL,' +
    '  battery_reserve REAL,' +
    '  external_psi REAL,' +
    '  psi_diff REAL,' +
    '  alert_level INTEGER' +
    ');'
  );

  // Table 2: Mission & Anomaly Events
  FConnection.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS mission_events (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  event_time DATETIME,' +
    '  event_type VARCHAR(32),' +
    '  description TEXT,' +
    '  depth REAL' +
    ');'
  );

  // Table 3: Extracted Abyssal Mineral Samples
  FConnection.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS mineral_samples (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  sample_code VARCHAR(24),' +
    '  mineral_name VARCHAR(64),' +
    '  extraction_depth REAL,' +
    '  purity REAL,' +
    '  extracted_at DATETIME' +
    ');'
  );

  // Table 4: Recovered Blackbox Lore Logs
  FConnection.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS blackbox_lore (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  recovery_depth REAL,' +
    '  decrypted_text TEXT,' +
    '  recovered_at DATETIME' +
    ');'
  );

  FTransaction.Commit;
end;

procedure TGameDatabase.RecordTelemetryTick(const AData: TTelemetryData);
var
  CurrentTick: QWord;
  Item: TTelemetryLogItem;
begin
  CurrentTick := GetTickCount64;
  if (CurrentTick - FLastLogTick) < TELEMETRY_LOG_MS then
    Exit;

  FLastLogTick := CurrentTick;

  Item.Timestamp := Now;
  Item.Depth := AData.Position.Z;
  Item.HullIntegrity := AData.HullIntegrity;
  Item.BatteryReserve := AData.BatteryReserve;
  Item.ExternalPSI := AData.ExternalPSI;
  Item.PSIDiff := AData.PSIDifferential;
  Item.AlertLevel := Ord(AData.AlertLevel);

  FTelemetryBuffer.Add(Item);

  // Batch commit only when buffer threshold is reached
  if FTelemetryBuffer.Count >= BUFFER_FLUSH_LIMIT then
    FlushBufferToDisk;
end;

procedure TGameDatabase.LogEvent(const AEventType, ADescription: string; ADepth: Double);
begin
  if not FIsConnected then
    Exit;

  try
    if not FTransaction.Active then
      FTransaction.StartTransaction;

    FQuery.Close;
    FQuery.SQL.Text :=
      'INSERT INTO mission_events (event_time, event_type, description, depth) ' +
      'VALUES (:pTime, :pType, :pDesc, :pDepth);';
    FQuery.Params.ParamByName('pTime').AsDateTime := Now;
    FQuery.Params.ParamByName('pType').AsString := AEventType;
    FQuery.Params.ParamByName('pDesc').AsString := ADescription;
    FQuery.Params.ParamByName('pDepth').AsFloat := ADepth;
    FQuery.ExecSQL;

    FTransaction.Commit;
  except
    if FTransaction.Active then
      FTransaction.Rollback;
  end;
end;

function TGameDatabase.GenerateMineralName(ADepth: Double; out APurity: Double): string;
const
  MINERAL_NAMES: array[0..4] of string = (
    'Ferromanganese Nodule',
    'Hydrothermal Sulfide',
    'Cobalt-Rich Crust',
    'Abyssal Silicate Core',
    'Hadal Piezoelectric Quartz'
  );
var
  Idx: Integer;
begin
  // Deeper extractions yield rarer minerals and higher purity
  Idx := Round((ADepth / MAX_TRENCH_DEPTH) * High(MINERAL_NAMES));
  if Idx < 0 then Idx := 0;
  if Idx > High(MINERAL_NAMES) then Idx := High(MINERAL_NAMES);

  Result := MINERAL_NAMES[Idx];
  APurity := 55.0 + (ADepth / MAX_TRENCH_DEPTH) * 40.0 + (Random * 4.9);
  if APurity > 99.9 then
    APurity := 99.9;
end;

function TGameDatabase.RegisterMineralExtraction(ADepth: Double): TMineralSampleItem;
var
  PurityVal: Double;
begin
  Result.SampleID := FMineralCache.Count + 1;
  Result.SampleCode := Format('MRN-%.2d-%d', [Result.SampleID, Round(ADepth)]);
  Result.MineralName := GenerateMineralName(ADepth, PurityVal);
  Result.ExtractionDepth := ADepth;
  Result.PurityPercent := PurityVal;
  Result.Timestamp := Now;

  FMineralCache.Add(Result);

  if FIsConnected then
  begin
    try
      if not FTransaction.Active then
        FTransaction.StartTransaction;

      FQuery.Close;
      FQuery.SQL.Text :=
        'INSERT INTO mineral_samples (sample_code, mineral_name, extraction_depth, purity, extracted_at) ' +
        'VALUES (:pCode, :pName, :pDepth, :pPurity, :pTime);';
      FQuery.Params.ParamByName('pCode').AsString := Result.SampleCode;
      FQuery.Params.ParamByName('pName').AsString := Result.MineralName;
      FQuery.Params.ParamByName('pDepth').AsFloat := Result.ExtractionDepth;
      FQuery.Params.ParamByName('pPurity').AsFloat := Result.PurityPercent;
      FQuery.Params.ParamByName('pTime').AsDateTime := Result.Timestamp;
      FQuery.ExecSQL;

      FTransaction.Commit;
    except
      if FTransaction.Active then
        FTransaction.Rollback;
    end;
  end;
end;

function TGameDatabase.RegisterBlackboxRecovery(ADepth: Double): Integer;
var
  LoreText: string;
begin
  Inc(FBlackboxCount);
  Result := FBlackboxCount;

  // Pick a random lore text, or sequential if you prefer. We'll use sequential wrapping.
  LoreText := BLACKBOX_LORE[(FBlackboxCount - 1) mod Length(BLACKBOX_LORE)];

  if FIsConnected then
  begin
    try
      if not FTransaction.Active then
        FTransaction.StartTransaction;

      FQuery.Close;
      FQuery.SQL.Text :=
        'INSERT INTO blackbox_lore (recovery_depth, decrypted_text, recovered_at) ' +
        'VALUES (:pDepth, :pText, :pTime);';
      FQuery.Params.ParamByName('pDepth').AsFloat := ADepth;
      FQuery.Params.ParamByName('pText').AsString := LoreText;
      FQuery.Params.ParamByName('pTime').AsDateTime := Now;
      FQuery.ExecSQL;

      FTransaction.Commit;
    except
      if FTransaction.Active then
        FTransaction.Rollback;
    end;
  end;
end;

function TGameDatabase.ReadBlackboxLore(ALogID: Integer): string;
begin
  Result := '[ERR] LOG NOT FOUND OR ACCESS DENIED.';

  if not FIsConnected then
    Exit;

  try
    if FTransaction.Active then
      FTransaction.Commit; // Ensure no pending writes block the read

    FTransaction.StartTransaction;
    FQuery.Close;
    FQuery.SQL.Text := 'SELECT decrypted_text FROM blackbox_lore WHERE id = :pID LIMIT 1;';
    FQuery.Params.ParamByName('pID').AsInteger := ALogID;
    FQuery.Open;

    if not FQuery.EOF then
      Result := FQuery.FieldByName('decrypted_text').AsString;

    FQuery.Close;
    FTransaction.Commit;
  except
    if FTransaction.Active then
      FTransaction.Rollback;
  end;
end;

procedure TGameDatabase.FlushBufferToDisk;
var
  Item: TTelemetryLogItem;
begin
  if (not FIsConnected) or (FTelemetryBuffer.Count = 0) then
    Exit;

  try
    if not FTransaction.Active then
      FTransaction.StartTransaction;

    FQuery.Close;
    FQuery.SQL.Text :=
      'INSERT INTO telemetry_logs (log_time, depth, hull_integrity, battery_reserve, external_psi, psi_diff, alert_level) ' +
      'VALUES (:pTime, :pDepth, :pHull, :pBatt, :pExtPSI, :pDiff, :pAlert);';

    for Item in FTelemetryBuffer do
    begin
      FQuery.Params.ParamByName('pTime').AsDateTime := Item.Timestamp;
      FQuery.Params.ParamByName('pDepth').AsFloat := Item.Depth;
      FQuery.Params.ParamByName('pHull').AsFloat := Item.HullIntegrity;
      FQuery.Params.ParamByName('pBatt').AsFloat := Item.BatteryReserve;
      FQuery.Params.ParamByName('pExtPSI').AsFloat := Item.ExternalPSI;
      FQuery.Params.ParamByName('pDiff').AsFloat := Item.PSIDiff;
      FQuery.Params.ParamByName('pAlert').AsInteger := Item.AlertLevel;
      FQuery.ExecSQL;
    end;

    FTransaction.Commit;
    FTelemetryBuffer.Clear;
  except
    if FTransaction.Active then
      FTransaction.Rollback;
  end;
end;

end.
