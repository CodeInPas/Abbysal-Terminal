unit uAudioDSP;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, DynLibs, uConstants, uTypes;

type
  { Dynamic BASS Audio API types and constants for fault-tolerant loading }
  HSTREAM = Cardinal;
  BASS_BOOL = LongBool;

const
  BASS_SAMPLE_LOOP = 4;
  BASS_ATTRIB_FREQ = 1;
  BASS_ATTRIB_VOL  = 2;
  BASS_ATTRIB_PAN  = 3; // New: Pan control for spatial audio
  BASS_DATA_FFT256 = $80000000;

type
  TBASS_Init = function(device: LongInt; freq, flags: Cardinal; win: THandle; clsid: Pointer): BASS_BOOL; {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TBASS_Free = function: BASS_BOOL; {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TBASS_StreamCreateFile = function(mem: BASS_BOOL; f: Pointer; offset, length: QWord; flags: Cardinal): HSTREAM; {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TBASS_ChannelPlay = function(handle: Cardinal; restart: BASS_BOOL): BASS_BOOL; {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TBASS_ChannelStop = function(handle: Cardinal): BASS_BOOL; {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TBASS_ChannelSetAttribute = function(handle, attrib: Cardinal; value: Single): BASS_BOOL; {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TBASS_ChannelGetData = function(handle: Cardinal; buffer: Pointer; length: Cardinal): Cardinal; {$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF};

  { TAudioDSP - Manages BASS audio streams, pitch modulation, and real-time FFT spectrum synthesis }
  TAudioDSP = class
  private
    FBassDLL: TLibHandle;
    FAudioReady: Boolean;

    // Dynamic function pointers
    FBASS_Init: TBASS_Init;
    FBASS_Free: TBASS_Free;
    FBASS_StreamCreateFile: TBASS_StreamCreateFile;
    FBASS_ChannelPlay: TBASS_ChannelPlay;
    FBASS_ChannelStop: TBASS_ChannelStop;
    FBASS_ChannelSetAttribute: TBASS_ChannelSetAttribute;
    FBASS_ChannelGetData: TBASS_ChannelGetData;

    // Audio channel handles
    FStreamPing: HSTREAM;
    FStreamRumble: HSTREAM;
    FStreamAlarm: HSTREAM;
    FStreamMonster: HSTREAM;

    // Real-time DSP & procedural telemetry spectrum state
    FFFTData: TFFTDataArray;
    FLastSweepAngle: Single;
    FPingEnvelope: Single;
    FContactEnvelope: Single;
    FImpactEnvelope: Single;
    FPhaseTime: Double;
    FAlarmPlaying: Boolean;

    function LoadBassLibrary: Boolean;
    function LoadSampleStream(const ARelativePath: string; ALoop: Boolean): HSTREAM;
    procedure UpdateHardwareStreams(const ATelemetry: TTelemetryData);
    procedure SynthesizeSpectrumFFT(ADeltaTime: Double; const ATelemetry: TTelemetryData);
  public
    constructor Create;
    destructor Destroy; override;

    { Dynamically loads bass.dll and initializes audio streams; falls back to procedural DSP if missing }
    function Initialize(AWindowHandle: THandle = 0): Boolean;

    { Updates spatial audio modulation and computes 128-bin FFT array for TAChart }
    procedure UpdateAudioDSP(ADeltaTime: Double; const ATelemetry: TTelemetryData);

    { Acoustic transient triggers }
    procedure TriggerSonarPing(APitchShift: Single = 1.0);
    procedure TriggerContactEcho(ADistance: Double);
    procedure TriggerHullImpact;
    procedure StopAllAudio;

    { Modulates Panning for spatial clues. APanValue: -1.0(Left) to 1.0(Right) }
    procedure SetAudioPan(ASourceType: Integer; APanValue: Single);

    property FFTData: TFFTDataArray read FFFTData;
    property AudioHardwareReady: Boolean read FAudioReady;
  end;

implementation

{ TAudioDSP }

constructor TAudioDSP.Create;
var
  i: Integer;
begin
  inherited Create;
  FBassDLL := NilHandle;
  FAudioReady := False;

  FStreamPing := 0;
  FStreamRumble := 0;
  FStreamAlarm := 0;
  FStreamMonster := 0;

  FLastSweepAngle := 0.0;
  FPingEnvelope := 0.0;
  FContactEnvelope := 0.0;
  FImpactEnvelope := 0.0;
  FPhaseTime := 0.0;
  FAlarmPlaying := False;

  for i := 0 to High(FFFTData) do
    FFFTData[i] := 0.0;
end;

destructor TAudioDSP.Destroy;
begin
  StopAllAudio;
  if FAudioReady and Assigned(FBASS_Free) then
    FBASS_Free();

  if FBassDLL <> NilHandle then
    UnloadLibrary(FBassDLL);

  inherited Destroy;
end;

function TAudioDSP.LoadBassLibrary: Boolean;
var
  LibPath: string;
begin
  Result := False;
  LibPath := ExtractFilePath(ParamStr(0)) + 'bass.dll';
  if not FileExists(LibPath) then
    Exit;

  FBassDLL := LoadLibrary(LibPath);
  if FBassDLL = NilHandle then
    Exit;

  Pointer(FBASS_Init) := GetProcedureAddress(FBassDLL, 'BASS_Init');
  Pointer(FBASS_Free) := GetProcedureAddress(FBassDLL, 'BASS_Free');
  Pointer(FBASS_StreamCreateFile) := GetProcedureAddress(FBassDLL, 'BASS_StreamCreateFile');
  Pointer(FBASS_ChannelPlay) := GetProcedureAddress(FBassDLL, 'BASS_ChannelPlay');
  Pointer(FBASS_ChannelStop) := GetProcedureAddress(FBassDLL, 'BASS_ChannelStop');
  Pointer(FBASS_ChannelSetAttribute) := GetProcedureAddress(FBassDLL, 'BASS_ChannelSetAttribute');
  Pointer(FBASS_ChannelGetData) := GetProcedureAddress(FBassDLL, 'BASS_ChannelGetData');

  Result := Assigned(FBASS_Init) and Assigned(FBASS_Free) and
            Assigned(FBASS_StreamCreateFile) and Assigned(FBASS_ChannelPlay) and
            Assigned(FBASS_ChannelStop) and Assigned(FBASS_ChannelSetAttribute) and
            Assigned(FBASS_ChannelGetData);
end;

function TAudioDSP.LoadSampleStream(const ARelativePath: string; ALoop: Boolean): HSTREAM;
var
  FullPath: AnsiString;
  Flags: Cardinal;
begin
  Result := 0;
  if not FAudioReady then
    Exit;

  FullPath := ExpandFileName(ExtractFilePath(ParamStr(0)) + ARelativePath);
  if not FileExists(FullPath) then
    Exit;

  Flags := 0;
  if ALoop then
    Flags := BASS_SAMPLE_LOOP;

  Result := FBASS_StreamCreateFile(False, PAnsiChar(FullPath), 0, 0, Flags);
end;

function TAudioDSP.Initialize(AWindowHandle: THandle): Boolean;
begin
  Result := False;
  if LoadBassLibrary then
  begin
    if FBASS_Init(-1, 44100, 0, AWindowHandle, nil) then
    begin
      FAudioReady := True;

      FStreamPing    := LoadSampleStream(PATH_SND_PING, False);
      FStreamRumble  := LoadSampleStream(PATH_SND_RUMBLE, True);
      FStreamAlarm   := LoadSampleStream(PATH_SND_ALARM, True);
      FStreamMonster := LoadSampleStream(PATH_SND_MONSTER, True);

      // Start continuous background hydrophone loops
      if FStreamRumble <> 0 then
      begin
        FBASS_ChannelSetAttribute(FStreamRumble, BASS_ATTRIB_VOL, 0.35);
        FBASS_ChannelPlay(FStreamRumble, True);
      end;

      if FStreamMonster <> 0 then
      begin
        FBASS_ChannelSetAttribute(FStreamMonster, BASS_ATTRIB_VOL, 0.0);
        FBASS_ChannelPlay(FStreamMonster, True);
      end;

      Result := True;
    end;
  end;
end;

procedure TAudioDSP.UpdateHardwareStreams(const ATelemetry: TTelemetryData);
var
  DepthRatio, MonsterVol, RumbleFreq: Single;
begin
  if not FAudioReady then
    Exit;

  DepthRatio := EnsureRange(ATelemetry.Position.Z / MAX_TRENCH_DEPTH, 0.0, 1.0);

  // Modulate ambient rumble pitch & volume by hydrostatic depth
  if FStreamRumble <> 0 then
  begin
    RumbleFreq := 44100.0 * (0.65 + (DepthRatio * 0.55));
    FBASS_ChannelSetAttribute(FStreamRumble, BASS_ATTRIB_FREQ, RumbleFreq);
    FBASS_ChannelSetAttribute(FStreamRumble, BASS_ATTRIB_VOL, 0.25 + (DepthRatio * 0.45));
  end;

  // Modulate biological anomaly low-frequency drone by proximity
  if FStreamMonster <> 0 then
  begin
    if ATelemetry.NearestAnomalyDist < ANOMALY_DETECT_RANGE then
      MonsterVol := EnsureRange(1.0 - (ATelemetry.NearestAnomalyDist / ANOMALY_DETECT_RANGE), 0.0, 1.0)
    else
      MonsterVol := 0.0;

    FBASS_ChannelSetAttribute(FStreamMonster, BASS_ATTRIB_VOL, MonsterVol);
  end;

  // Toggle critical pressure/proximity alarm loop
  if FStreamAlarm <> 0 then
  begin
    if (ATelemetry.AlertLevel = alCritical) and (not FAlarmPlaying) then
    begin
      FBASS_ChannelSetAttribute(FStreamAlarm, BASS_ATTRIB_VOL, 0.70);
      FBASS_ChannelPlay(FStreamAlarm, True);
      FAlarmPlaying := True;
    end
    else if (ATelemetry.AlertLevel <> alCritical) and FAlarmPlaying then
    begin
      FBASS_ChannelStop(FStreamAlarm);
      FAlarmPlaying := False;
    end;
  end;
end;

procedure TAudioDSP.SynthesizeSpectrumFFT(ADeltaTime: Double; const ATelemetry: TTelemetryData);
var
  RawBASSFFT: array[0..127] of Single;
  i: Integer;
  HasHardwareData: Boolean;
  FreqNorm, AmbientFloor, AnomalyGain, PingBand, ContactBand, DrillBand, CombinedVal: Single;
begin
  HasHardwareData := False;

  // 1. Poll real hardware FFT data from active BASS channel if playing valid audio
  if FAudioReady and (FStreamRumble <> 0) then
  begin
    FillChar(RawBASSFFT, SizeOf(RawBASSFFT), 0);
    if FBASS_ChannelGetData(FStreamRumble, @RawBASSFFT[0], BASS_DATA_FFT256) > 0 then
      HasHardwareData := True;
  end;

  // 2. Synthesize real-time hydrophone acoustic signatures (guarantees rich TAChart telemetry)
  AmbientFloor := 4.0 + ((ATelemetry.Position.Z / MAX_TRENCH_DEPTH) * 14.0);

  if ATelemetry.NearestAnomalyDist < ANOMALY_DETECT_RANGE then
    AnomalyGain := Sqr(1.0 - EnsureRange(ATelemetry.NearestAnomalyDist / ANOMALY_DETECT_RANGE, 0.0, 1.0)) * 78.0
  else
    AnomalyGain := 0.0;

  for i := 0 to High(FFFTData) do
  begin
    FreqNorm := i / Length(FFFTData);

    // Sub-bass & Low Frequency (Bins 0..24): Trench hydrostatic rumble & Leviathan bio-signature
    if i <= 24 then
    begin
      CombinedVal := AmbientFloor * Exp(-i * 0.06) +
                     (Sin((FPhaseTime * 6.5) + (i * 0.4)) * 3.5);

      if AnomalyGain > 0.0 then
        CombinedVal := CombinedVal +
          (AnomalyGain * Exp(-Sqr((i - 9) / 5.5)) * (0.65 + 0.35 * Sin(FPhaseTime * 19.0 + i)));
    end
    else
      CombinedVal := AmbientFloor * 0.25 * (1.0 - FreqNorm);

    // Mid-High Frequency (Bins 46..64): Active Sonar Transducer Ping (1.5 kHz - 3.5 kHz equivalent)
    if FPingEnvelope > 0.01 then
    begin
      PingBand := Exp(-Sqr((i - 54) / 4.2)) * FPingEnvelope * 85.0;
      CombinedVal := CombinedVal + PingBand;
    end;

    // Upper-Mid Frequency (Bins 68..84): Acoustic Target Return Echo
    if FContactEnvelope > 0.01 then
    begin
      ContactBand := Exp(-Sqr((i - 75) / 3.5)) * FContactEnvelope * 68.0;
      CombinedVal := CombinedVal + ContactBand;
    end;

    // High Frequency (Bins 90..120): Laser Drill Harmonic & Critical Alarm Carrier
    if ATelemetry.IsDrilling then
    begin
      if ATelemetry.IsDrillJammed then
        DrillBand := Exp(-Sqr((i - 100) / 4.0)) * (75.0 + Random * 30.0) // Harsher, erratic frequency when jammed
      else
        DrillBand := Exp(-Sqr((i - 104) / 7.0)) * (42.0 + Random * 22.0);

      CombinedVal := CombinedVal + DrillBand;
    end;

    if ATelemetry.AlertLevel = alCritical then
      CombinedVal := CombinedVal + (Exp(-Sqr((i - 92) / 3.0)) * Abs(Sin(FPhaseTime * 12.0)) * 55.0);

    // Broadband transient spike during physical hull impact
    if FImpactEnvelope > 0.01 then
      CombinedVal := CombinedVal + (FImpactEnvelope * (35.0 + Random * 45.0));

    // Blend hardware FFT reading if valid WAV assets are loaded
    if HasHardwareData then
      CombinedVal := Max(CombinedVal, Sqrt(Max(0.0, RawBASSFFT[i])) * 180.0);

    // Add subtle thermal hydrophone noise & smooth temporal interpolation
    CombinedVal := CombinedVal + (Random * 3.2);
    FFFTData[i] := (FFFTData[i] * 0.55) + (EnsureRange(CombinedVal, 0.0, 100.0) * 0.45);
  end;
end;

procedure TAudioDSP.UpdateAudioDSP(ADeltaTime: Double; const ATelemetry: TTelemetryData);
var
  DepthPitchShift: Single;
begin
  FPhaseTime := FPhaseTime + ADeltaTime;

  // Decay acoustic transient envelopes
  FPingEnvelope := Max(0.0, FPingEnvelope - (ADeltaTime * 2.2));
  FContactEnvelope := Max(0.0, FContactEnvelope - (ADeltaTime * 1.8));
  FImpactEnvelope := Max(0.0, FImpactEnvelope - (ADeltaTime * 1.4));

  // Automatically trigger sonar ping sound every full 360-degree sweep rotation
  if (ATelemetry.SonarMode = smActive) and (ATelemetry.Power.Sonar > 0) and
     (ATelemetry.BatteryReserve > 0.0) then
  begin
    if ATelemetry.SweepAngle < FLastSweepAngle then
    begin
      DepthPitchShift := 1.0 - ((ATelemetry.Position.Z / MAX_TRENCH_DEPTH) * 0.18);
      TriggerSonarPing(DepthPitchShift);
    end;
  end;
  FLastSweepAngle := ATelemetry.SweepAngle;

  UpdateHardwareStreams(ATelemetry);
  SynthesizeSpectrumFFT(ADeltaTime, ATelemetry);
end;

procedure TAudioDSP.TriggerSonarPing(APitchShift: Single);
begin
  FPingEnvelope := 1.0;

  if FAudioReady and (FStreamPing <> 0) then
  begin
    FBASS_ChannelSetAttribute(FStreamPing, BASS_ATTRIB_FREQ, 44100.0 * EnsureRange(APitchShift, 0.5, 1.5));
    FBASS_ChannelSetAttribute(FStreamPing, BASS_ATTRIB_PAN, 0.0); // Center ping
    FBASS_ChannelSetAttribute(FStreamPing, BASS_ATTRIB_VOL, 0.80);
    FBASS_ChannelPlay(FStreamPing, True);
  end;
end;

procedure TAudioDSP.TriggerContactEcho(ADistance: Double);
var
  Attenuation: Single;
begin
  Attenuation := EnsureRange(1.0 - (ADistance / SONAR_MAX_RANGE), 0.25, 1.0);
  FContactEnvelope := Max(FContactEnvelope, Attenuation);

  if FAudioReady and (FStreamPing <> 0) then
  begin
    FBASS_ChannelSetAttribute(FStreamPing, BASS_ATTRIB_FREQ, 44100.0 * 1.25);
    FBASS_ChannelSetAttribute(FStreamPing, BASS_ATTRIB_VOL, 0.45 * Attenuation);
    FBASS_ChannelPlay(FStreamPing, True);
  end;
end;

procedure TAudioDSP.TriggerHullImpact;
begin
  FImpactEnvelope := 1.0;
end;

procedure TAudioDSP.StopAllAudio;
begin
  if not FAudioReady then
    Exit;

  if FStreamPing <> 0 then FBASS_ChannelStop(FStreamPing);
  if FStreamRumble <> 0 then FBASS_ChannelStop(FStreamRumble);
  if FStreamAlarm <> 0 then FBASS_ChannelStop(FStreamAlarm);
  if FStreamMonster <> 0 then FBASS_ChannelStop(FStreamMonster);
  FAlarmPlaying := False;
end;

procedure TAudioDSP.SetAudioPan(ASourceType: Integer; APanValue: Single);
begin
  if not FAudioReady then
    Exit;

  // ASourceType: 1 = Monster stream
  if (ASourceType = 1) and (FStreamMonster <> 0) then
  begin
    FBASS_ChannelSetAttribute(FStreamMonster, BASS_ATTRIB_PAN, EnsureRange(APanValue, -1.0, 1.0));
  end;
end;

end.
