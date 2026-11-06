unit uTerminalRenderer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Graphics, Math,
  BGRABitmap, BGRABitmapTypes, BGRATextFX,
  uConstants, uTypes;

type
  { TTerminalRenderer - High-speed off-screen BGRABitmap renderer for Panel 1 CRT Terminal }
  TTerminalRenderer = class
  private
    FBuffer: TBGRABitmap;
    FOverlay: TBGRABitmap;
    FTheme: TCRTTheme;
    FPalette: TColorPalette;
    FScanlinesEnabled: Boolean;
    FRenderFontName: string;

    // Cached BGRA colors for fast per-frame access
    FColBg: TBGRAPixel;
    FColPrimary: TBGRAPixel;
    FColDim: TBGRAPixel;
    FColGlow: TBGRAPixel;
    FColWarn: TBGRAPixel;
    FColCrit: TBGRAPixel;

    procedure UpdateCachedColors;
    procedure EnsureBufferSize(AWidth, AHeight: Integer);
    procedure GenerateCRTOverlay(AWidth, AHeight: Integer);
    procedure LoadCustomFont;

    procedure DrawSegmentedBar(AX, AY, AW, AH: Integer; const ATitle, ASubText: string;
      APercent: Double; const ABarColor: TBGRAPixel; AIsAlert: Boolean);
    procedure DrawLeftTelemetryColumn(const ARect: TRect; const AData: TTelemetryData);
    procedure DrawCenterSonarRadar(const ARect: TRect; const AData: TTelemetryData;
      ABlips: TBlipList);
    procedure DrawBottomStatusDeck(const ARect: TRect; const AData: TTelemetryData;
      AGameState: TGameState; AReason: TGameOverReason);
    procedure DrawBootSequence(const ARect: TRect; ABootStep: Integer);
    procedure DrawEMPBlackout(const ARect: TRect; const AData: TTelemetryData);
    procedure ApplyPostProcessing(AGlitchIntensity: Single);
  public
    constructor Create;
    destructor Destroy; override;

    { Renders the complete terminal HUD to an off-screen buffer and blits to ADestCanvas }
    procedure RenderTerminal(ADestCanvas: TCanvas; AWidth, AHeight: Integer;
      const AData: TTelemetryData; ABlips: TBlipList;
      AGameState: TGameState; AReason: TGameOverReason = gorNone);

    procedure SetCRTTheme(ATheme: TCRTTheme);

    property CRTTheme: TCRTTheme read FTheme write SetCRTTheme;
    property ScanlinesEnabled: Boolean read FScanlinesEnabled write FScanlinesEnabled;
    property RenderFontName: string read FRenderFontName;
  end;

implementation

{ TTerminalRenderer }

constructor TTerminalRenderer.Create;
begin
  inherited Create;
  FBuffer := TBGRABitmap.Create;
  FOverlay := TBGRABitmap.Create;
  FScanlinesEnabled := True;
  FRenderFontName := 'Consolas'; // Default fallback
  LoadCustomFont;
  SetCRTTheme(ctGreen);
end;

destructor TTerminalRenderer.Destroy;
begin
  FOverlay.Free;
  FBuffer.Free;
  inherited Destroy;
end;

procedure TTerminalRenderer.LoadCustomFont;
var
  FontPath: string;
begin
  FontPath := ExpandFileName(ExtractFilePath(ParamStr(0)) + PATH_FONT_RETRO);
  if FileExists(FontPath) then
  begin
    // Register the TTF font with BGRABitmap's internal font manager
   // FontManager.AddFontFile(FontPath);
    FRenderFontName := 'VT323'; // The internal family name of the TTF
  end;
end;

procedure TTerminalRenderer.SetCRTTheme(ATheme: TCRTTheme);
begin
  FTheme := ATheme;
  FPalette := GetThemePalette(FTheme);
  UpdateCachedColors;
end;

procedure TTerminalRenderer.UpdateCachedColors;
begin
  FColBg      := ColorToBGRA(ColorToRGB(FPalette.Background), 255);
  FColPrimary := ColorToBGRA(ColorToRGB(FPalette.Primary), 255);
  FColDim     := ColorToBGRA(ColorToRGB(FPalette.Dim), 255);
  FColGlow    := ColorToBGRA(ColorToRGB(FPalette.Glow), 255);
  FColWarn    := ColorToBGRA(ColorToRGB(FPalette.AlertWarn), 255);
  FColCrit    := ColorToBGRA(ColorToRGB(FPalette.AlertCrit), 255);
end;

procedure TTerminalRenderer.EnsureBufferSize(AWidth, AHeight: Integer);
begin
  if (FBuffer.Width <> AWidth) or (FBuffer.Height <> AHeight) then
  begin
    FBuffer.SetSize(AWidth, AHeight);
    GenerateCRTOverlay(AWidth, AHeight);
  end;
end;

procedure TTerminalRenderer.GenerateCRTOverlay(AWidth, AHeight: Integer);
var
  X, Y: Integer;
  P: PBGRAPixel;
  NormX, NormY, DistFromCenter, VignetteAlpha: Single;
  ScanAlpha: Byte;
begin
  FOverlay.SetSize(AWidth, AHeight);
  FOverlay.Fill(BGRAPixelTransparent);

  // Pre-compute scanlines and radial CRT vignette into a single fast overlay layer
  for Y := 0 to AHeight - 1 do
  begin
    P := FOverlay.ScanLine[Y];
    NormY := (Y / AHeight) - 0.5;

    for X := 0 to AWidth - 1 do
    begin
      NormX := (X / AWidth) - 0.5;
      DistFromCenter := Hypot(NormX * 1.35, NormY * 1.35);

      // Vignette darkened corners
      VignetteAlpha := EnsureRange((DistFromCenter - 0.42) * 320.0, 0.0, 210.0);

      // Horizontal CRT phosphor scanlines every odd row
      if Odd(Y) then
        ScanAlpha := 64
      else
        ScanAlpha := 0;

      P^.red   := 0;
      P^.green := 0;
      P^.blue  := 0;
      P^.alpha := EnsureRange(Round(Max(VignetteAlpha, ScanAlpha)), 0, 235);
      Inc(P);
    end;
  end;
  FOverlay.InvalidateBitmap;
end;

procedure TTerminalRenderer.DrawSegmentedBar(AX, AY, AW, AH: Integer;
  const ATitle, ASubText: string; APercent: Double;
  const ABarColor: TBGRAPixel; AIsAlert: Boolean);
const
  SEGMENT_COUNT = 16;
var
  i, SegH, SegGap, SegY, ActiveSegments, InnerTop, InnerH: Integer;
  FrameCol, FillCol: TBGRAPixel;
  TS: TSize;
begin
  if AIsAlert and Odd(GetTickCount64 div 250) then
    FrameCol := FColCrit
  else
    FrameCol := FColDim;

  // Outer gauge frame
  FBuffer.Rectangle(AX, AY, AX + AW, AY + AH, FrameCol, BGRA(8, 12, 8, 180), dmDrawWithTransparency);

  // Header label
  FBuffer.FontHeight := 16; // Increased for retro font
  FBuffer.FontStyle := [fsBold];
  TS := FBuffer.TextSize(ATitle);
  FBuffer.TextOut(AX + (AW - TS.cx) div 2, AY + 2, ATitle, FColPrimary);

  // Footer numeric readout
  FBuffer.FontHeight := 14;
  FBuffer.FontStyle := [];
  TS := FBuffer.TextSize(ASubText);
  FBuffer.TextOut(AX + (AW - TS.cx) div 2, AY + AH - 17, ASubText, FColGlow);

  // Segmented LED bar calculation
  InnerTop := AY + 24;
  InnerH := AH - 44;
  if InnerH < 20 then
    Exit;

  SegGap := 2;
  SegH := Max(2, (InnerH - (SEGMENT_COUNT * SegGap)) div SEGMENT_COUNT);
  ActiveSegments := Round((EnsureRange(APercent, 0.0, 100.0) / 100.0) * SEGMENT_COUNT);

  for i := 0 to SEGMENT_COUNT - 1 do
  begin
    SegY := (InnerTop + InnerH) - ((i + 1) * (SegH + SegGap));
    if i < ActiveSegments then
      FillCol := ABarColor
    else
      FillCol := BGRA(FColDim.red div 3, FColDim.green div 3, FColDim.blue div 3, 140);

    FBuffer.FillRect(AX + 6, SegY, AX + AW - 6, SegY + SegH, FillCol, dmDrawWithTransparency);
  end;
end;

procedure TTerminalRenderer.DrawLeftTelemetryColumn(const ARect: TRect;
  const AData: TTelemetryData);
var
  Pad, GaugeW, GaugeH, TopY, ValveBoxY: Integer;
  HullCol, BattCol, PSICol, ValveCol: TBGRAPixel;
  PSIPercent: Double;
  ValveStr: string;
  TS: TSize;
begin
  Pad := 8;
  GaugeW := (ARect.Width - (Pad * 2));
  GaugeH := Max(80, (ARect.Height - 90) div 3);
  TopY := ARect.Top + Pad;

  // Outer column border
  FBuffer.Rectangle(ARect.Left, ARect.Top, ARect.Right, ARect.Bottom, FColDim, dmSet);

  // 1. HULL INTEGRITY BAR
  if AData.HullIntegrity < 30.0 then
    HullCol := FColCrit
  else if AData.HullIntegrity < 60.0 then
    HullCol := FColWarn
  else
    HullCol := FColPrimary;

  DrawSegmentedBar(
    ARect.Left + Pad, TopY, GaugeW, GaugeH,
    '[HULL]', Format('%.0f%%', [AData.HullIntegrity]),
    AData.HullIntegrity, HullCol, AData.HullIntegrity < 30.0
  );

  // 2. BATTERY RESERVE BAR
  Inc(TopY, GaugeH + Pad);
  if AData.BatteryReserve < 20.0 then
    BattCol := FColCrit
  else if AData.BatteryReserve < 45.0 then
    BattCol := FColWarn
  else
    BattCol := FColPrimary;

  DrawSegmentedBar(
    ARect.Left + Pad, TopY, GaugeW, GaugeH,
    '[BATT]', Format('%.0f%%', [AData.BatteryReserve]),
    AData.BatteryReserve, BattCol, AData.BatteryReserve < 20.0
  );

  // 3. EXTERNAL PSI DIFFERENTIAL BAR
  Inc(TopY, GaugeH + Pad);
  PSIPercent := EnsureRange((AData.PSIDifferential / IMPLOSION_PSI_DIFF) * 100.0, 0.0, 100.0);
  if AData.PSIDifferential >= CRITICAL_PSI_DIFF then
    PSICol := FColCrit
  else if AData.PSIDifferential >= SAFE_PSI_DIFF then
    PSICol := FColWarn
  else
    PSICol := FColPrimary;

  DrawSegmentedBar(
    ARect.Left + Pad, TopY, GaugeW, GaugeH,
    '[PSI ]', Format('%.0f', [AData.PSIDifferential]),
    PSIPercent, PSICol, AData.PSIDifferential >= CRITICAL_PSI_DIFF
  );

  // 4. VALVE STATUS INDICATOR
  ValveBoxY := TopY + GaugeH + Pad;
  if ValveBoxY + 46 <= ARect.Bottom - Pad then
  begin
    if AData.IsPurging then
    begin
      ValveStr := 'PURGING';
      ValveCol := FColWarn;
    end
    else if AData.ValveAuto then
    begin
      ValveStr := '(AUTO)';
      ValveCol := FColPrimary;
    end
    else
    begin
      ValveStr := '(MANUAL)';
      ValveCol := FColGlow;
    end;

    FBuffer.Rectangle(ARect.Left + Pad, ValveBoxY, ARect.Right - Pad, ARect.Bottom - Pad, FColDim, dmSet);
    FBuffer.FontHeight := 14;
    FBuffer.FontStyle := [fsBold];
    TS := FBuffer.TextSize('[VALVE]');
    FBuffer.TextOut(ARect.Left + Pad + (GaugeW - TS.cx) div 2, ValveBoxY + 4, '[VALVE]', FColPrimary);

    FBuffer.FontHeight := 16;
    TS := FBuffer.TextSize(ValveStr);
    FBuffer.TextOut(ARect.Left + Pad + (GaugeW - TS.cx) div 2, ValveBoxY + 22, ValveStr, ValveCol);
  end;
end;

procedure TTerminalRenderer.DrawCenterSonarRadar(const ARect: TRect;
  const AData: TTelemetryData; ABlips: TBlipList);
var
  CenterX, CenterY, Radius, r, i: Integer;
  SweepRad, TrailRad, BlipX, BlipY, ScaleFactor: Single;
  EndX, EndY: Single;
  B: TSonarBlip;
  BlipCol, TrailCol: TBGRAPixel;
  AlphaByte: Byte;
  StatusText: string;
  TS: TSize;
begin
  FBuffer.Rectangle(ARect.Left, ARect.Top, ARect.Right, ARect.Bottom, FColDim, dmSet);

  CenterX := (ARect.Left + ARect.Right) div 2;
  CenterY := (ARect.Top + ARect.Bottom) div 2;
  Radius := Max(40, Min(ARect.Width, ARect.Height) div 2 - 26);

  // 1. Draw Concentric Range Rings & Crosshairs
  for r := 1 to 4 do
    FBuffer.EllipseAntialias(CenterX, CenterY, (Radius * r) / 4.0, (Radius * r) / 4.0, FColDim, 1.0);

  FBuffer.DrawLineAntialias(CenterX - Radius, CenterY, CenterX + Radius, CenterY, FColDim, 1.0);
  FBuffer.DrawLineAntialias(CenterX, CenterY - Radius, CenterX, CenterY + Radius, FColDim, 1.0);

  // Cardinal bearings
  FBuffer.FontHeight := 16;
  FBuffer.FontStyle := [fsBold];
  FBuffer.TextOut(CenterX - 5, CenterY - Radius - 18, 'N', FColPrimary);
  FBuffer.TextOut(CenterX - 5, CenterY + Radius + 3, 'S', FColPrimary);
  FBuffer.TextOut(CenterX + Radius + 8, CenterY - 8, 'E', FColPrimary);
  FBuffer.TextOut(CenterX - Radius - 18, CenterY - 8, 'W', FColPrimary);

  // 2. Render Blips with Phosphor Persistence
  if Assigned(ABlips) and (Radius > 0) then
  begin
    ScaleFactor := Radius / SONAR_MAX_RANGE;

    for i := 0 to ABlips.Count - 1 do
    begin
      B := ABlips[i];
      if B.IsExtracted or (B.Intensity <= 0.02) then
        Continue;

      // Map world X/Y to radar screen coordinates (North/+Y is Up)
      BlipX := CenterX + ((B.Position.X - AData.Position.X) * ScaleFactor);
      BlipY := CenterY - ((B.Position.Y - AData.Position.Y) * ScaleFactor);

      if Hypot(BlipX - CenterX, BlipY - CenterY) > Radius then
        Continue;

      AlphaByte := EnsureRange(Round(B.Intensity * 255.0), 0, 255);

      case B.BlipType of
        btTerrain:
          begin
            BlipCol := BGRA(FColPrimary.red, FColPrimary.green, FColPrimary.blue, AlphaByte);
            FBuffer.FillEllipseAntialias(BlipX, BlipY, B.Radius, B.Radius, BlipCol);
          end;

        btMineral:
          begin
            BlipCol := BGRA(FColGlow.red, FColGlow.green, FColGlow.blue, AlphaByte);
            // Draw target reticle [x] for mineral vein
            FBuffer.RectangleAntialias(BlipX - 5, BlipY - 5, BlipX + 5, BlipY + 5, BlipCol, 1.5);
            FBuffer.DrawLineAntialias(BlipX - 3, BlipY - 3, BlipX + 3, BlipY + 3, BlipCol, 1.0);
            FBuffer.DrawLineAntialias(BlipX - 3, BlipY + 3, BlipX + 3, BlipY - 3, BlipCol, 1.0);
          end;

        btAnomaly:
          begin
            BlipCol := BGRA(FColCrit.red, FColCrit.green, FColCrit.blue, AlphaByte);
            FBuffer.FillEllipseAntialias(BlipX, BlipY, B.Radius + (Random * 2.5), B.Radius + (Random * 2.5), BlipCol);
            FBuffer.EllipseAntialias(BlipX, BlipY, B.Radius + 5.0, B.Radius + 5.0, BlipCol, 1.5);
          end;

        btDecoy:
          begin
            BlipCol := BGRA(FColWarn.red, FColWarn.green, FColWarn.blue, AlphaByte);
            // Draw a diamond shape for decoy
            FBuffer.DrawLineAntialias(BlipX, BlipY - B.Radius - 3, BlipX + B.Radius + 3, BlipY, BlipCol, 1.5);
            FBuffer.DrawLineAntialias(BlipX + B.Radius + 3, BlipY, BlipX, BlipY + B.Radius + 3, BlipCol, 1.5);
            FBuffer.DrawLineAntialias(BlipX, BlipY + B.Radius + 3, BlipX - B.Radius - 3, BlipY, BlipCol, 1.5);
            FBuffer.DrawLineAntialias(BlipX - B.Radius - 3, BlipY, BlipX, BlipY - B.Radius - 3, BlipCol, 1.5);

            // Pulsing inner dot indicating active broadcast
            if Odd(GetTickCount64 div 200) then
              FBuffer.FillEllipseAntialias(BlipX, BlipY, 1.5, 1.5, BlipCol);
          end;

        btBlackbox: // Render the Blackbox Lore Item
          begin
            BlipCol := BGRA(FColGlow.red, FColGlow.green, FColGlow.blue, AlphaByte);

            // Draw a pulsing 8-point crosshair for blackbox
            FBuffer.DrawLineAntialias(BlipX - 6, BlipY, BlipX + 6, BlipY, BlipCol, 1.5);
            FBuffer.DrawLineAntialias(BlipX, BlipY - 6, BlipX, BlipY + 6, BlipCol, 1.5);
            FBuffer.DrawLineAntialias(BlipX - 4, BlipY - 4, BlipX + 4, BlipY + 4, BlipCol, 1.0);
            FBuffer.DrawLineAntialias(BlipX - 4, BlipY + 4, BlipX + 4, BlipY - 4, BlipCol, 1.0);

            if Odd(GetTickCount64 div 150) then
              FBuffer.FillEllipseAntialias(BlipX, BlipY, 2.5, 2.5, BGRA(FColWarn.red, FColWarn.green, FColWarn.blue, AlphaByte));
          end;
      end;
    end;
  end;

  // 3. Draw Active Sonar Sweep Line & Phosphor Afterglow Sector
  if (AData.SonarMode = smActive) and (AData.Power.Sonar > 0) and (AData.BatteryReserve > 0.0) then
  begin
    // Draw trailing phosphor fade rays
    for i := 1 to 18 do
    begin
      TrailRad := DegToRad(AData.SweepAngle - (i * 2.0));
      EndX := CenterX + (Sin(TrailRad) * Radius);
      EndY := CenterY - (Cos(TrailRad) * Radius);
      TrailCol := BGRA(FColPrimary.red, FColPrimary.green, FColPrimary.blue, Max(5, 95 - (i * 5)));
      FBuffer.DrawLineAntialias(CenterX, CenterY, EndX, EndY, TrailCol, 1.5);
    end;

    // Main bright sweep beam
    SweepRad := DegToRad(AData.SweepAngle);
    EndX := CenterX + (Sin(SweepRad) * Radius);
    EndY := CenterY - (Cos(SweepRad) * Radius);
    FBuffer.DrawLineAntialias(CenterX, CenterY, EndX, EndY, FColGlow, 2.2);
  end
  else
  begin
    // Passive Hydrophone Mode overlay banner
    StatusText := '[ PASSIVE HYDROPHONE MODE - ACTIVE PING SILENCED ]';
    FBuffer.FontHeight := 16;
    TS := FBuffer.TextSize(StatusText);
    FBuffer.FillRect(CenterX - (TS.cx div 2) - 8, CenterY - 12,
                     CenterX + (TS.cx div 2) + 8, CenterY + 14,
                     BGRA(0, 0, 0, 210), dmDrawWithTransparency);
    FBuffer.TextOut(CenterX - (TS.cx div 2), CenterY - 8, StatusText, FColWarn);
  end;

  // 4. Laser Drill Progress Overlay
  if AData.IsDrilling then
  begin
    if AData.IsDrillJammed then
    begin
      if Odd(GetTickCount64 div 250) then
        StatusText := '[CRIT] DRILL JAMMED! RUN "run drill_reverse"'
      else
        StatusText := ' ';

      FBuffer.FontHeight := 16;
      TS := FBuffer.TextSize('[CRIT] DRILL JAMMED! RUN "run drill_reverse"');
      FBuffer.FillRect(CenterX - 170, ARect.Bottom - 48, CenterX + 170, ARect.Bottom - 10,
                       BGRA(40, 0, 0, 225), dmDrawWithTransparency);
      FBuffer.Rectangle(CenterX - 170, ARect.Bottom - 48, CenterX + 170, ARect.Bottom - 10, FColCrit, dmSet);
      FBuffer.TextOut(CenterX - (TS.cx div 2), ARect.Bottom - 44, StatusText, FColCrit);

      FBuffer.FillRect(CenterX - 160, ARect.Bottom - 24,
                       CenterX - 160 + Round(3.2 * AData.DrillProgress), ARect.Bottom - 16,
                       FColCrit, dmSet);
    end
    else
    begin
      StatusText := Format('LASER DRILL EXTRACTION IN PROGRESS: %.0f%%', [AData.DrillProgress]);
      FBuffer.FontHeight := 16;
      TS := FBuffer.TextSize(StatusText);
      FBuffer.FillRect(CenterX - 140, ARect.Bottom - 48, CenterX + 140, ARect.Bottom - 10,
                       BGRA(10, 18, 10, 225), dmDrawWithTransparency);
      FBuffer.Rectangle(CenterX - 140, ARect.Bottom - 48, CenterX + 140, ARect.Bottom - 10, FColGlow, dmSet);
      FBuffer.TextOut(CenterX - (TS.cx div 2), ARect.Bottom - 44, StatusText, FColGlow);

      FBuffer.FillRect(CenterX - 130, ARect.Bottom - 24,
                       CenterX - 130 + Round(2.6 * AData.DrillProgress), ARect.Bottom - 16,
                       FColPrimary, dmSet);
    end;
  end;

  // Radar caption tag
  FBuffer.FontHeight := 14;
  FBuffer.TextOut(ARect.Left + 8, ARect.Top + 6, Format('[SONAR_ARRAY // RANGE: %.0fM]', [SONAR_MAX_RANGE]), FColPrimary);
  FBuffer.TextOut(ARect.Left + 8, ARect.Bottom - 20,
    Format('POS X:%.1f  Y:%.1f  VEL Z:%.1f m/s', [AData.Position.X, AData.Position.Y, AData.Velocity.Z]),
    FColGlow);
end;

procedure TTerminalRenderer.DrawBottomStatusDeck(const ARect: TRect;
  const AData: TTelemetryData; AGameState: TGameState; AReason: TGameOverReason);
var
  MidSplit: Integer;
  DepthRect, StatusRect: TRect;
  DepthStr, SubStr, AlertLine1, AlertLine2: string;
  AlertCol: TBGRAPixel;
  TS: TSize;
begin
  MidSplit := ARect.Left + Round(ARect.Width * 0.38);
  DepthRect := Rect(ARect.Left, ARect.Top, MidSplit - 4, ARect.Bottom);
  StatusRect := Rect(MidSplit + 4, ARect.Top, ARect.Right, ARect.Bottom);

  // 1. DIGITAL DEPTH READOUT BOX
  FBuffer.Rectangle(DepthRect.Left, DepthRect.Top, DepthRect.Right, DepthRect.Bottom, FColDim, dmSet);
  FBuffer.FontHeight := 14;
  FBuffer.FontStyle := [fsBold];
  TS := FBuffer.TextSize('[DEPTH]');
  FBuffer.TextOut(DepthRect.Left + (DepthRect.Width - TS.cx) div 2, DepthRect.Top + 4, '[DEPTH]', FColPrimary);

  DepthStr := Format('%.5d', [Round(AData.Position.Z)]);
  FBuffer.FontHeight := 36;
  TS := FBuffer.TextSize(DepthStr);
  FBuffer.TextOut(DepthRect.Left + (DepthRect.Width - TS.cx) div 2,
                  DepthRect.Top + (DepthRect.Height div 2) - 18, DepthStr, FColGlow);

  SubStr := Format('M E T E R S  (EXT: %.0f PSI)', [AData.ExternalPSI]);
  FBuffer.FontHeight := 14;
  TS := FBuffer.TextSize(SubStr);
  FBuffer.TextOut(DepthRect.Left + (DepthRect.Width - TS.cx) div 2,
                  DepthRect.Bottom - 20, SubStr, FColPrimary);

  // 2. SYSTEM STATUS & ALERT MONITOR BOX
  FBuffer.Rectangle(StatusRect.Left, StatusRect.Top, StatusRect.Right, StatusRect.Bottom, FColDim, dmSet);
  FBuffer.FontHeight := 14;
  FBuffer.TextOut(StatusRect.Left + 10, StatusRect.Top + 4, '[SYSTEM STATUS]', FColPrimary);

  AlertCol := FColPrimary;
  AlertLine1 := '[OK] HYDROSTATIC INTEGRITY NOMINAL';
  AlertLine2 := Format('[OK] SAMPLES EXTRACTED: %d / %d', [AData.MineralsCollected, REQUIRED_MINERALS]);

  if AGameState = gsGameOver then
  begin
    AlertCol := FColCrit;
    case AReason of
      gorImplosion:     AlertLine1 := '[FATAL] CATASTROPHIC HULL IMPLOSION - SIGNAL LOST';
      gorPowerDepleted: AlertLine1 := '[FATAL] BATTERY RESERVE DEPLETED - TERMINAL OFFLINE';
      gorEntityStrike:  AlertLine1 := '[FATAL] STRUCTURAL COLLAPSE BY BIOLOGICAL ENTITY';
    else
      AlertLine1 := '[FATAL] MISSION TERMINATED - SIGNAL LOST';
    end;
    AlertLine2 := '>>> PRESS "NEW MISSION" IN CONTROL BOARD TO REBOOT <<<';
  end
  else if AGameState = gsVictory then
  begin
    AlertCol := FColGlow;
    AlertLine1 := '[VICTORY] ALL ABYSSAL MINERAL SAMPLES TRANSMITTED!';
    AlertLine2 := '>>> MISSION COMPLETE - READY FOR SURFACE RECOVERY <<<';
  end
  else
  begin
    if AData.PSIDifferential >= CRITICAL_PSI_DIFF then
    begin
      AlertCol := FColCrit;
      AlertLine1 := '[!] CRITICAL HULL STRESS - EXECUTE "purge_valve" NOW!';
    end
    else if AData.PSIDifferential >= SAFE_PSI_DIFF then
    begin
      AlertCol := FColWarn;
      AlertLine1 := '[!] PRESSURE SPIKE DETECTED (DIFF: ' + Format('%.0f PSI)', [AData.PSIDifferential]);
    end;

    if AData.NearestAnomalyDist < ANOMALY_AGGRO_RANGE then
    begin
      AlertCol := FColCrit;
      AlertLine2 := Format('[!] LEVIATHAN APPROACHING (%.0fM) - SWITCH TO PASSIVE SONAR!', [AData.NearestAnomalyDist]);
    end
    else if AData.IsDrillJammed then
    begin
      if AlertCol = FColPrimary then
        AlertCol := FColWarn;
      AlertLine2 := '[!] MECHANICAL FAILURE: DRILL JAMMED - CLEAR DEBRIS!';
    end
    else if AData.EntitiesDetected > 0 then
    begin
      if AlertCol = FColPrimary then
        AlertCol := FColWarn;
      AlertLine2 := Format('[!] UNIDENTIFIED MASS IN SECTOR (RANGE: %.0fM)', [AData.NearestAnomalyDist]);
    end
    else if AData.SyntaxCorrupted then
    begin
      AlertLine2 := '[!] CLI BUFFER CORRUPTED - EXECUTE "run sys_diag"';
    end;
  end;

  FBuffer.FontHeight := 16;
  FBuffer.FontStyle := [fsBold];
  FBuffer.TextOut(StatusRect.Left + 12, StatusRect.Top + 26, AlertLine1, AlertCol);
  FBuffer.TextOut(StatusRect.Left + 12, StatusRect.Top + 48, AlertLine2, AlertCol);
end;

procedure TTerminalRenderer.DrawBootSequence(const ARect: TRect; ABootStep: Integer);
var
  i, CurrentY, CenterX: Integer;
  LineText: string;
  TS: TSize;
const
  BOOT_LINES: array[0..BOOT_SEQ_LINES-1] of string = (
    'MARIANA OS BIOS v1.4.0-LORE INIT...',
    'MOUNTING VIRTUAL FILE SYSTEM... [OK]',
    'LOADING HYDROACOUSTIC DRIVERS... [OK]',
    'CHECKING SENSOR TELEMETRY... [OK]',
    'CALIBRATING LASER DRILL... [OK]',
    'ESTABLISHING UMBILICAL LINK... [OK]',
    '[SYS] MARIANA OS KERNEL INITIALIZED. UMBILICAL LINK ESTABLISHED.',
    'SYSTEM READY.',
    '[SYS] MISSION OBJECTIVE: EXTRACT MINERAL SAMPLES.'
  );
begin
  FBuffer.Rectangle(ARect.Left, ARect.Top, ARect.Right, ARect.Bottom, FColDim, dmSet);

  CenterX := (ARect.Left + ARect.Right) div 2;
  CurrentY := ARect.Top + 40;

  FBuffer.FontHeight := 24;
  FBuffer.FontStyle := [fsBold];
  TS := FBuffer.TextSize(APP_TITLE);
  FBuffer.TextOut(CenterX - (TS.cx div 2), CurrentY, APP_TITLE, FColPrimary);

  Inc(CurrentY, 40);
  FBuffer.FontHeight := 18;
  FBuffer.FontStyle := [];

  for i := 0 to Min(ABootStep, BOOT_SEQ_LINES - 1) do
  begin
    LineText := BOOT_LINES[i];
    FBuffer.TextOut(ARect.Left + 40, CurrentY, LineText, FColPrimary);
    Inc(CurrentY, 24);
  end;

  // Blinking cursor on the last active line
  if (ABootStep < BOOT_SEQ_LINES) and Odd(GetTickCount64 div 250) then
  begin
    TS := FBuffer.TextSize(BOOT_LINES[Min(ABootStep, BOOT_SEQ_LINES - 1)]);
    FBuffer.FillRect(ARect.Left + 40 + TS.cx + 5, CurrentY - 24 + 4,
                     ARect.Left + 40 + TS.cx + 15, CurrentY - 24 + 18,
                     FColPrimary, dmSet);
  end;
end;

procedure TTerminalRenderer.DrawEMPBlackout(const ARect: TRect; const AData: TTelemetryData);
var
  CenterX, CenterY: Integer;
  TS: TSize;
  Blink: Boolean;
  WarnText: string;
begin
  // Fill background with dim/black to simulate dead CRT
  FBuffer.Rectangle(ARect.Left, ARect.Top, ARect.Right, ARect.Bottom, FColBg, dmSet);
  CenterX := (ARect.Left + ARect.Right) div 2;
  CenterY := (ARect.Top + ARect.Bottom) div 2;

  Blink := Odd(GetTickCount64 div 250);

  FBuffer.FontHeight := 36;
  FBuffer.FontStyle := [fsBold];
  TS := FBuffer.TextSize('KERNEL PANIC');
  FBuffer.TextOut(CenterX - (TS.cx div 2), CenterY - 60, 'KERNEL PANIC', FColCrit);

  FBuffer.FontHeight := 18;
  TS := FBuffer.TextSize('MASSIVE EMP SURGE DETECTED');
  FBuffer.TextOut(CenterX - (TS.cx div 2), CenterY - 20, 'MASSIVE EMP SURGE DETECTED', FColCrit);

  if AData.RebootProgress > 0.0 then
  begin
    WarnText := Format('COLD REBOOT IN PROGRESS... %.0f%%', [AData.RebootProgress]);
    TS := FBuffer.TextSize(WarnText);
    FBuffer.TextOut(CenterX - (TS.cx div 2), CenterY + 40, WarnText, FColWarn);

    // Progress bar for reboot
    FBuffer.Rectangle(CenterX - 150, CenterY + 70, CenterX + 150, CenterY + 85, FColDim, dmSet);
    FBuffer.FillRect(CenterX - 148, CenterY + 72, CenterX - 148 + Round(2.96 * AData.RebootProgress), CenterY + 83, FColWarn, dmSet);
  end
  else
  begin
    WarnText := '>>> ENTER "run sys_reboot" TO RESTORE TERMINAL <<<';
    TS := FBuffer.TextSize(WarnText);
    if Blink then
      FBuffer.TextOut(CenterX - (TS.cx div 2), CenterY + 40, WarnText, FColCrit);
  end;
end;

procedure TTerminalRenderer.ApplyPostProcessing(AGlitchIntensity: Single);
var
  Y, X, W, H, TearOffset, TearSliceH, StartY, ShiftPx: Integer;
  P: PBGRAPixel;
  NoiseChance: Integer;
  TempRow: array of TBGRAPixel;
begin
  W := FBuffer.Width;
  H := FBuffer.Height;

  // 1. Direct Scanline Memory Manipulation for EM Glitch, Chromatic Shift & Static Noise
  if (AGlitchIntensity > 0.02) and (W > 16) and (H > 16) then
  begin
    SetLength(TempRow, W);

    // Horizontal V-Sync Tear Slice
    if Random < (AGlitchIntensity * 0.75) then
    begin
      StartY := Random(H - 24);
      TearSliceH := 6 + Random(22);
      TearOffset := Round((Random - 0.5) * AGlitchIntensity * 38.0);

      if TearOffset <> 0 then
      begin
        for Y := StartY to Min(H - 1, StartY + TearSliceH) do
        begin
          P := FBuffer.ScanLine[Y];
          Move(P^, TempRow[0], W * SizeOf(TBGRAPixel));
          for X := 0 to W - 1 do
          begin
            ShiftPx := (X + TearOffset + W) mod W;
            P[X] := TempRow[ShiftPx];
            // Add subtle red-channel chromatic aberration on torn scanlines
            P[X].red := Min(255, P[X].red + Round(AGlitchIntensity * 90));
          end;
        end;
      end;
    end;

    // Random Phosphor Static Noise Sparks
    NoiseChance := Round(AGlitchIntensity * 35.0);
    for Y := 0 to H - 1 do
    begin
      if Random(100) < NoiseChance then
      begin
        P := FBuffer.ScanLine[Y];
        for X := 0 to (W div 8) do
        begin
          ShiftPx := Random(W);
          P[ShiftPx] := FColGlow;
        end;
      end;
    end;

    FBuffer.InvalidateBitmap;
  end;

  // 2. Blend Pre-Rendered Scanlines & CRT Vignette Overlay
  if FScanlinesEnabled then
    FBuffer.PutImage(0, 0, FOverlay, dmDrawWithTransparency);
end;

procedure TTerminalRenderer.RenderTerminal(ADestCanvas: TCanvas;
  AWidth, AHeight: Integer; const AData: TTelemetryData; ABlips: TBlipList;
  AGameState: TGameState; AReason: TGameOverReason);
var
  LeftColW, BottomDeckH: Integer;
  LeftRect, RadarRect, BottomRect: TRect;
begin
  if (AWidth <= 10) or (AHeight <= 10) or (not Assigned(ADestCanvas)) then
    Exit;

  EnsureBufferSize(AWidth, AHeight);

  // Clear off-screen buffer with CRT pitch-black background
  FBuffer.Fill(FColBg);
  FBuffer.FontName := FRenderFontName;
  FBuffer.FontAntialias := True;

  if AGameState = gsBooting then
  begin
    DrawBootSequence(Rect(6, 6, AWidth - 6, AHeight - 6), AData.BootStep);
  end
  else if AGameState = gsEMPBlackout then
  begin
    DrawEMPBlackout(Rect(6, 6, AWidth - 6, AHeight - 6), AData);
  end
  else
  begin
    // Partition layout regions (Left Gauges, Center Radar, Bottom Depth & Status)
    LeftColW := EnsureRange(Round(AWidth * 0.16), 78, 120); // slightly wider for retro font
    BottomDeckH := 82;

    LeftRect   := Rect(6, 6, LeftColW, AHeight - 6);
    RadarRect  := Rect(LeftColW + 6, 6, AWidth - 6, AHeight - BottomDeckH - 10);
    BottomRect := Rect(LeftColW + 6, AHeight - BottomDeckH - 4, AWidth - 6, AHeight - 6);

    // Render HUD components onto off-screen bitmap
    DrawLeftTelemetryColumn(LeftRect, AData);
    DrawCenterSonarRadar(RadarRect, AData, ABlips);
    DrawBottomStatusDeck(BottomRect, AData, AGameState, AReason);
  end;

  // Apply scanlines, vignette, and pressure/EM glitch effects
  ApplyPostProcessing(AData.GlitchIntensity);

  // Single atomic blit to target LCL Canvas (Zero Flicker)
  FBuffer.Draw(ADestCanvas, 0, 0, True);
end;

end.
