unit uCommandParser;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, Generics.Collections,
  uConstants, uTypes;

type
  { TCommandParser - Tokenizes CLI input, simulates EM buffer corruption, and manages signal latency }
  TCommandParser = class
  private
    FQueue: TCommandQueue;
    FOnLog: TLogEvent;

    procedure DoLog(const AMsg: string; ALevel: TAlertLevel = alNormal);
    procedure Tokenize(const AInput: string; AList: TStringList);
    function ApplyBufferCorruption(const AInput: string): string;
    function ParseDirection(const ADirStr: string; out ADir: TThrusterDir): Boolean;
    function ParseSubsystem(const ASysStr: string; out ASubsys: TSubsystem): Boolean;
    function BuildQueuedCommand(ATokens: TStringList; const ARaw: string;
      out ACmd: TQueuedCommand): Boolean;
    function GetPendingCount: SizeInt;
  public
    constructor Create;
    destructor Destroy; override;

    { Clears all pending commands in the umbilical transmission queue }
    procedure ClearQueue;

    { Computes umbilical signal delay in milliseconds based on current depth }
    function CalculateLatencyMS(ADepth: Double): QWord;

    { Parses raw CLI input and schedules it into the execution queue }
    procedure SubmitCommand(const ARawInput: string; const ATelemetry: TTelemetryData);

    { Extracts the next command whose latency timer has expired }
    function PopReadyCommand(ACurrentTick: QWord; out ACmd: TQueuedCommand): Boolean;

    { Generates the CLI help reference text }
    function GetHelpText: string;

    property PendingCount: SizeInt read GetPendingCount;
    property OnLogMessage: TLogEvent read FOnLog write FOnLog;
  end;

implementation

{ TCommandParser }

constructor TCommandParser.Create;
begin
  inherited Create;
  FQueue := TCommandQueue.Create;
end;

destructor TCommandParser.Destroy;
begin
  FQueue.Free;
  inherited Destroy;
end;

procedure TCommandParser.DoLog(const AMsg: string; ALevel: TAlertLevel);
begin
  if Assigned(FOnLog) then
    FOnLog(AMsg, ALevel);
end;

procedure TCommandParser.ClearQueue;
begin
  FQueue.Clear;
end;

function TCommandParser.GetPendingCount: SizeInt;
begin
  Result := FQueue.Count;
end;

function TCommandParser.CalculateLatencyMS(ADepth: Double): QWord;
var
  DepthFactor: Double;
begin
  if ADepth <= LATENCY_START_DEPTH then
    Exit(0);

  DepthFactor := (ADepth - LATENCY_START_DEPTH) / (MAX_TRENCH_DEPTH - LATENCY_START_DEPTH);
  DepthFactor := EnsureRange(DepthFactor, 0.0, 1.0);
  Result := Round(DepthFactor * MAX_SIGNAL_LATENCY);
end;

function TCommandParser.ApplyBufferCorruption(const AInput: string): string;
const
  GLITCH_CHARS: array[0..7] of Char = ('#', '@', '?', '$', '%', '&', '!', '*');
var
  i: Integer;
begin
  Result := AInput;
  if Length(Result) = 0 then
    Exit;

  // [QA Peningkatan Efek] Replace 1 to 2 characters randomly to simulate memory buffer bit-flips
  for i := 1 to Length(Result) do
  begin
    if (Result[i] <> ' ') and (Random(100) < 25) then
    begin
      // 50% chance to replace with a symbol (breaks the command), 50% chance to just flip case (adds visual horror but keeps command valid)
      if Random(2) = 0 then
        Result[i] := GLITCH_CHARS[Random(Length(GLITCH_CHARS))]
      else
      begin
        if Result[i] in ['a'..'z'] then
          Result[i] := UpCase(Result[i])
        else if Result[i] in ['A'..'Z'] then
          Result[i] := LowerCase(Result[i]);
      end;
    end;
  end;
end;

procedure TCommandParser.Tokenize(const AInput: string; AList: TStringList);
var
  S: string;
begin
  AList.Clear;
  AList.Delimiter := ' ';
  AList.StrictDelimiter := True;
  S := Trim(LowerCase(AInput));

  // Collapse multiple spaces into single spaces for clean parsing
  while Pos('  ', S) > 0 do
    S := StringReplace(S, '  ', ' ', [rfReplaceAll]);

  AList.DelimitedText := S;
end;

function TCommandParser.ParseDirection(const ADirStr: string; out ADir: TThrusterDir): Boolean;
begin
  Result := True;
  case ADirStr of
    'up', 'u', 'ascend':     ADir := tdUp;
    'down', 'd', 'descend':  ADir := tdDown;
    'north', 'n', 'fwd':     ADir := tdNorth;
    'south', 's', 'rev':     ADir := tdSouth;
    'east', 'e', 'right':    ADir := tdEast;
    'west', 'w', 'left':     ADir := tdWest;
  else
    begin
      ADir := tdNone;
      Result := False;
    end;
  end;
end;

function TCommandParser.ParseSubsystem(const ASysStr: string; out ASubsys: TSubsystem): Boolean;
begin
  Result := True;
  case ASysStr of
    'engine', 'thruster', 'eng': ASubsys := sysEngine;
    'sonar', 'snr':              ASubsys := sysSonar;
    'drill', 'drl':              ASubsys := sysDrill;
    'core', 'os', 'coreos':      ASubsys := sysCoreOS;
  else
    begin
      ASubsys := sysEngine;
      Result := False;
    end;
  end;
end;

function TCommandParser.BuildQueuedCommand(ATokens: TStringList;
  const ARaw: string; out ACmd: TQueuedCommand): Boolean;
var
  RootCmd, Arg1, Token: string;
  i, LogID: Integer;
  PwrVal: Double;
begin
  Result := False;
  FillChar(ACmd, SizeOf(TQueuedCommand), 0);
  ACmd.CommandType := ctUnknown;
  ACmd.RawText := ARaw;

  if ATokens.Count = 0 then
    Exit;

  RootCmd := ATokens[0];

  // 1. Single-token & utility commands
  if RootCmd = CMD_HELP then
  begin
    ACmd.CommandType := ctHelp;
    Exit(True);
  end
  else if RootCmd = CMD_STATUS then
  begin
    ACmd.CommandType := ctStatus;
    Exit(True);
  end
  else if RootCmd = CMD_CLEAR then
  begin
    ACmd.CommandType := ctClear;
    Exit(True);
  end
  else if RootCmd = CMD_STOP then
  begin
    ACmd.CommandType := ctThrusterStop;
    Exit(True);
  end
  else if RootCmd = CMD_DECOY then
  begin
    ACmd.CommandType := ctDeployDecoy;
    Exit(True);
  end
  else if RootCmd = CMD_PURGE then
  begin
    ACmd.CommandType := ctPurgeValve;
    if ATokens.Count > 1 then
      ACmd.StringParam := ATokens[1]; // Optional auto/manual argument
    Exit(True);
  end;

  // 2. SONAR command: "sonar -mode active|passive" or shorthand "sonar active"
  if RootCmd = CMD_SONAR then
  begin
    if ATokens.Count < 2 then
      Exit(False);

    Arg1 := ATokens[ATokens.Count - 1];
    if (Arg1 = 'active') or (Arg1 = 'passive') then
    begin
      ACmd.CommandType := ctSonar;
      ACmd.StringParam := Arg1;
      Exit(True);
    end;
    Exit(False);
  end;

  // 3. RUN command: "run drill_sequence" or "run sys_diag" or "run drill_reverse" or "run sys_reboot"
  if RootCmd = CMD_DRILL then
  begin
    if ATokens.Count < 2 then
      Exit(False);

    Arg1 := ATokens[1];
    if Arg1 = ARG_DRILL_SEQ then
    begin
      ACmd.CommandType := ctRunDrill;
      Exit(True);
    end
    else if Arg1 = ARG_DRILL_REV then
    begin
      ACmd.CommandType := ctRunDrillRev;
      Exit(True);
    end
    else if Arg1 = ARG_SYS_DIAG then
    begin
      ACmd.CommandType := ctRunDiag;
      Exit(True);
    end
    else if Arg1 = ARG_SYS_REBOOT then
    begin
      ACmd.CommandType := ctRunSysReboot;
      Exit(True);
    end;
    Exit(False);
  end;

  // 4. THRUSTER command: "thruster -dir <dir> -pwr <0..100>" or "thruster <dir> [pwr]"
  if RootCmd = CMD_THRUSTER then
  begin
    if ATokens.Count < 2 then
      Exit(False);

    ACmd.TargetDir := tdNone;
    ACmd.NumericParam := 80.0; // Default thruster power if omitted

    i := 1;
    while i < ATokens.Count do
    begin
      Token := ATokens[i];
      if (Token = '-dir') and (i + 1 < ATokens.Count) then
      begin
        if not ParseDirection(ATokens[i + 1], ACmd.TargetDir) then
          Exit(False);
        Inc(i, 2);
      end
      else if (Token = '-pwr') and (i + 1 < ATokens.Count) then
      begin
        if not TryStrToFloat(ATokens[i + 1], PwrVal) then
          Exit(False);
        ACmd.NumericParam := EnsureRange(PwrVal, 0.0, 100.0);
        Inc(i, 2);
      end
      else if ParseDirection(Token, ACmd.TargetDir) then
      begin
        Inc(i);
      end
      else if TryStrToFloat(Token, PwrVal) then
      begin
        ACmd.NumericParam := EnsureRange(PwrVal, 0.0, 100.0);
        Inc(i);
      end
      else
        Exit(False);
    end;

    if ACmd.TargetDir <> tdNone then
    begin
      ACmd.CommandType := ctThruster;
      Exit(True);
    end;
    Exit(False);
  end;

  // 5. ROUTE_POWER command: "route_power -sys <sys> -val <0..100>" or "route_power <sys> <val>"
  if RootCmd = CMD_ROUTE then
  begin
    if ATokens.Count < 3 then
      Exit(False);

    PwrVal := -1.0;
    i := 1;
    while i < ATokens.Count do
    begin
      Token := ATokens[i];
      if (Token = '-sys') and (i + 1 < ATokens.Count) then
      begin
        if not ParseSubsystem(ATokens[i + 1], ACmd.TargetSubsys) then
          Exit(False);
        Inc(i, 2);
      end
      else if (Token = '-val') and (i + 1 < ATokens.Count) then
      begin
        if not TryStrToFloat(ATokens[i + 1], PwrVal) then
          Exit(False);
        Inc(i, 2);
      end
      else if ParseSubsystem(Token, ACmd.TargetSubsys) then
      begin
        Inc(i);
      end
      else if TryStrToFloat(Token, PwrVal) then
      begin
        Inc(i);
      end
      else
        Exit(False);
    end;

    if PwrVal >= 0.0 then
    begin
      ACmd.CommandType := ctRoutePower;
      ACmd.NumericParam := EnsureRange(PwrVal, 0.0, 100.0);
      Exit(True);
    end;
    Exit(False);
  end;

  // 6. READ_LOG command: "read_log [id]"
  if RootCmd = CMD_READ_LOG then
  begin
    if ATokens.Count < 2 then
      Exit(False);

    // [QA Fix] Use TryStrToInt for strictly processing whole number IDs safely
    if TryStrToInt(ATokens[1], LogID) then
    begin
      ACmd.CommandType := ctReadLog;
      ACmd.NumericParam := LogID; // Implicitly casts Int to Double (which is fine)
      Exit(True);
    end;
    Exit(False);
  end;
end;

procedure TCommandParser.SubmitCommand(const ARawInput: string;
  const ATelemetry: TTelemetryData);
var
  Tokens: TStringList;
  ProcessedInput: string;
  Cmd: TQueuedCommand;
  LatencyMS: QWord;
  IsDiagCommand: Boolean;
begin
  ProcessedInput := Trim(ARawInput);
  if ProcessedInput = '' then
    Exit;

  // Check if player is attempting to run system diagnostics or emergencies to fix buffer corruption
  IsDiagCommand := SameText(ProcessedInput, 'run sys_diag') or
                   SameText(ProcessedInput, CMD_HELP) or
                   SameText(ProcessedInput, CMD_CLEAR) or
                   SameText(ProcessedInput, CMD_DECOY) or
                   SameText(ProcessedInput, 'run ' + ARG_DRILL_REV) or
                   SameText(ProcessedInput, 'run ' + ARG_SYS_REBOOT) or
                   (Pos(CMD_READ_LOG, LowerCase(ProcessedInput)) > 0);

  // If in EMP Blackout, ONLY the reboot command should work
  if ATelemetry.IsEMPBlackout then
  begin
    if not SameText(ProcessedInput, 'run ' + ARG_SYS_REBOOT) then
    begin
      DoLog('[FATAL] KERNEL PANIC. SYSTEM HALTED. RUN "run sys_reboot" TO RECOVER.', alCritical);
      Exit;
    end;
  end;

  // Feature 2: CLI Syntax Degradation when hull/EM corruption is active
  if ATelemetry.SyntaxCorrupted and (not IsDiagCommand) and (not ATelemetry.IsEMPBlackout) and (Random(100) < 45) then
    ProcessedInput := ApplyBufferCorruption(ProcessedInput);

  // Echo command to terminal log (unless in full blackout, where output might be garbled)
  if ATelemetry.IsEMPBlackout and (not SameText(ProcessedInput, 'run ' + ARG_SYS_REBOOT)) then
    DoLog(OS_PROMPT + ApplyBufferCorruption(ProcessedInput), alCritical)
  else
    DoLog(OS_PROMPT + UpperCase(ProcessedInput), alNormal); // Terminal usually displays everything in Uppercase for retro feel

  Tokens := TStringList.Create;
  try
    Tokenize(ProcessedInput, Tokens);

    if not BuildQueuedCommand(Tokens, ProcessedInput, Cmd) then
    begin
      if ATelemetry.IsEMPBlackout then
        DoLog('[FATAL] UNRECOGNIZED. RUN "run sys_reboot".', alCritical)
      else if ATelemetry.SyntaxCorrupted then
        DoLog('[ERR] SYNTAX PARSE FAILURE. RUN "run sys_diag" TO FLUSH BUFFER.', alWarning)
      else
        DoLog(MSG_ERR_SYNTAX, alWarning);
      Exit;
    end;

    // Immediate terminal UI commands bypass umbilical latency
    if Cmd.CommandType in [ctHelp, ctStatus, ctClear, ctDeployDecoy, ctRunDrillRev, ctRunSysReboot, ctReadLog] then
      LatencyMS := 0
    else
      LatencyMS := CalculateLatencyMS(ATelemetry.Position.Z);

    Cmd.ExecuteTick := GetTickCount64 + LatencyMS;
    FQueue.Add(Cmd);

    if (LatencyMS >= 250) and (not ATelemetry.IsEMPBlackout) then
      DoLog(Format('[SYS] UMBILICAL LATENCY: %d ms. TRANSMITTING...', [LatencyMS]), alNormal);
  finally
    Tokens.Free;
  end;
end;

function TCommandParser.PopReadyCommand(ACurrentTick: QWord;
  out ACmd: TQueuedCommand): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to FQueue.Count - 1 do
  begin
    if FQueue[i].ExecuteTick <= ACurrentTick then
    begin
      ACmd := FQueue[i];
      FQueue.Delete(i);
      Exit(True);
    end;
  end;
end;

function TCommandParser.GetHelpText: string;
begin
  Result :=
    '--- MARIANA OS CLI COMMAND REFERENCE ---' + LineEnding +
    '  sonar -mode [active|passive]       : Switch acoustic transducer mode' + LineEnding +
    '  thruster -dir [n|s|e|w|up|down] -pwr [0-100] : Engage propulsion' + LineEnding +
    '  thruster_stop                      : Cut all thruster propulsion' + LineEnding +
    '  purge_valve [auto|manual]          : Equalize hull PSI / toggle auto' + LineEnding +
    '  route_power -sys [engine|sonar|drill|core] -val [0-100]' + LineEnding +
    '  run drill_sequence                 : Deploy laser drill on nearby target' + LineEnding +
    '  run drill_reverse                  : Reverse drill bit to clear mechanical jams' + LineEnding +
    '  run sys_diag                       : Scrub EM corruption from CLI buffer' + LineEnding +
    '  run sys_reboot                     : Cold reboot terminal during EMP blackout' + LineEnding +
    '  deploy_decoy                       : Eject acoustic decoy (Cost: 15% Battery)' + LineEnding +
    '  read_log [id]                      : Decrypt and display a recovered blackbox log' + LineEnding +
    '  status / clear / help              : Terminal utility commands';
end;

end.
