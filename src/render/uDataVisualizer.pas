unit uDataVisualizer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Math,
  TAGraph, TASeries, uConstants, uTypes;

type
  { TDataVisualizer - Efficiently bridges engine data arrays to UI TAChart components }
  TDataVisualizer = class
  public
    { Updates the Audio FFT Spectrum chart (Frequency vs Amplitude) }
    class procedure UpdateAudioSpectrum(ASeries: TLineSeries; const AFFTData: TFFTDataArray; ATheme: TCRTTheme);

    { Updates the Hull Stress history chart (Time vs Stress %) }
    class procedure UpdateHullStressCurve(ASeries: TLineSeries; const AStressHistory: TFFTDataArray; ATheme: TCRTTheme);

    { Applies the current CRT Theme colors to the chart backgrounds and grids }
    class procedure ApplyChartTheme(AChart: TChart; ATheme: TCRTTheme);
  end;

implementation

{ TDataVisualizer }

class procedure TDataVisualizer.UpdateAudioSpectrum(ASeries: TLineSeries; const AFFTData: TFFTDataArray; ATheme: TCRTTheme);
var
  i: Integer;
  Pal: TColorPalette;
begin
  if not Assigned(ASeries) then
    Exit;

  Pal := GetThemePalette(ATheme);
  ASeries.SeriesColor := Pal.Glow;

  ASeries.BeginUpdate;
  try
    ASeries.Clear;
    for i := 0 to High(AFFTData) do
    begin
      // Logarithmic X scaling visually represents audio frequencies better
      ASeries.AddXY(i, AFFTData[i]);
    end;
  finally
    ASeries.EndUpdate;
  end;
end;

class procedure TDataVisualizer.UpdateHullStressCurve(ASeries: TLineSeries; const AStressHistory: TFFTDataArray; ATheme: TCRTTheme);
var
  i: Integer;
  Pal: TColorPalette;
  CurrentStress: Double;
begin
  if not Assigned(ASeries) then
    Exit;

  Pal := GetThemePalette(ATheme);
  CurrentStress := AStressHistory[High(AStressHistory)];

  if CurrentStress > 80.0 then
    ASeries.SeriesColor := Pal.AlertCrit
  else if CurrentStress > 40.0 then
    ASeries.SeriesColor := Pal.AlertWarn
  else
    ASeries.SeriesColor := Pal.Primary;

  ASeries.BeginUpdate;
  try
    ASeries.Clear;
    for i := 0 to High(AStressHistory) do
    begin
      ASeries.AddXY(i, AStressHistory[i]);
    end;
  finally
    ASeries.EndUpdate;
  end;
end;

class procedure TDataVisualizer.ApplyChartTheme(AChart: TChart; ATheme: TCRTTheme);
var
  Pal: TColorPalette;
begin
  if not Assigned(AChart) then
    Exit;

  Pal := GetThemePalette(ATheme);

  AChart.Color := Pal.PanelBg;
  AChart.BackColor := Pal.Background;

  AChart.BottomAxis.Grid.Color := Pal.Dim;
  AChart.LeftAxis.Grid.Color := Pal.Dim;

  AChart.BottomAxis.Marks.LabelFont.Color := Pal.Dim;
  AChart.LeftAxis.Marks.LabelFont.Color := Pal.Dim;

  AChart.Title.Font.Color := Pal.Primary;
end;

end.

