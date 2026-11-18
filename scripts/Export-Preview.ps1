# Render the real WPF controls with fictional fixtures. No screen capture,
# user settings, credentials, network request or private history is involved.
param([string]$OutputDirectory = '', [switch]$ShowTransparency)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
$root=Split-Path $PSScriptRoot
$output=if ($OutputDirectory) { $OutputDirectory } else { Join-Path $root 'docs\images' }
[void][IO.Directory]::CreateDirectory($output)
$source=[IO.File]::ReadAllText((Join-Path $root 'src\PowerBalance.ps1'))
$alerts=[IO.File]::ReadAllText((Join-Path $root 'src\Alerts.ps1'))
$Demo=$true
. (Join-Path $root 'src\SchoolClient.ps1')
. (Join-Path $root 'src\Alerts.ps1')
# Intentionally do not initialize the query client or load local settings.
$script:ReminderSettings=Get-DefaultReminderSettings
$script:ReminderState=New-ReminderState 10
[xml]$xaml=[regex]::Match($source,'(?s)\[xml\]\$xaml = @''\r?\n(.*?)\r?\n''@').Groups[1].Value
$start=$source.IndexOf('$reader = New-Object System.Xml.XmlNodeReader $xaml')
$end=$source.IndexOf('function Set-PublicLabels',$start)
. ([scriptblock]::Create($source.Substring($start,$end-$start)))
$needed=@('Set-SectionPlacement','Initialize-ResponsiveMetrics','Update-ResponsiveTypography',
    'Set-ResponsiveLayout','Get-RangeStart','Get-PeriodCaption','Draw-BalanceChart',
    'Update-BalanceStatistics','Update-CompactBalance','Reset-CompactTypography')
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$null)
foreach($node in $ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]},$false)){
    if($node.Name-in $needed){. ([scriptblock]::Create($node.Extent.Text))}
}
$fixtureStart=[datetime]'2026-10-17 08:00:00'
$script:PreviewHistory=@(for($index=0;$index-le 480;$index++){
    [pscustomobject]@{Timestamp=$fixtureStart.AddMinutes($index);Balance=(15.60-[Math]::Floor($index/30.0)*0.45)}
})
function Get-ChartHistory {param($Range)return $script:PreviewHistory}
function Get-RangeHistory {param($Range)return $script:PreviewHistory}
function Get-BalanceHistory {return $script:PreviewHistory}
$script:RoomDisplayName='NUIST Demo - Room ***'
$window.FindName('MainRoomText').Text=$script:RoomDisplayName
$compactRoomText.Text=$script:RoomDisplayName
$script:LastBalance=8.40
$balanceText.Text='8.40'
$balanceText.Foreground=$brushConverter.ConvertFromString('#FBBF24')
$script:LowBalanceActive=$true
$statusText.Text='DEMO - fictional data | Updated 16:00:00'
$allRangeButton.Background=$brushConverter.ConvertFromString('#2A5EEAD4')
$allRangeButton.Foreground=$brushConverter.ConvertFromString('#E7FFFB')
$minuteScaleButton.Background=$brushConverter.ConvertFromString('#2A5EEAD4')
$minuteScaleButton.Foreground=$brushConverter.ConvertFromString('#E7FFFB')
$window.Left=-20000;$window.Top=0
function Save-PreviewPng($Visual,[int]$Width,[int]$Height,[string]$Name){
    if ($ShowTransparency -and $Name -ne 'reminder-settings.png') {
        # Use synthetic color bands to make the widget's translucency visible.
        $margin=32
        $bounds=[Windows.Rect]::new(0,0,$Width+2*$margin,$Height+2*$margin)
        $sceneBrush=[Windows.Media.LinearGradientBrush]::new()
        $sceneBrush.StartPoint=[Windows.Point]::new(0,0.10)
        $sceneBrush.EndPoint=[Windows.Point]::new(0.92,1)
        $sceneBrush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color]::FromRgb(23,57,80),0))
        $sceneBrush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color]::FromRgb(50,129,132),0.34))
        $sceneBrush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color]::FromRgb(18,34,56),0.65))
        $sceneBrush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color]::FromRgb(109,83,145),1))
        $composite=[Windows.Media.DrawingVisual]::new()
        $drawing=$composite.RenderOpen()
        try {
            $drawing.DrawRectangle($sceneBrush,$null,$bounds)
            $drawing.DrawRectangle([Windows.Media.VisualBrush]::new($Visual),$null,[Windows.Rect]::new($margin,$margin,$Width,$Height))
        }
        finally { $drawing.Close() }
        $Visual=$composite
        $Width=[int]$bounds.Width
        $Height=[int]$bounds.Height
    }
    $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap($Width,$Height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Visual)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $output $Name))
    try{$encoder.Save($stream)}finally{$stream.Dispose()}
    'Generated masked, fictional WPF preview: '+$Name
}
try{
    $window.Show();$window.UpdateLayout()
    Initialize-ResponsiveMetrics
    foreach($size in @(@(460,760,'desktop-portrait.png'),@(960,500,'desktop-landscape.png'))){
        $window.Width=$size[0];$window.Height=$size[1]
        $window.UpdateLayout();Set-ResponsiveLayout;$window.UpdateLayout()
        Draw-BalanceChart
        Update-BalanceStatistics -CurrentBalance $script:LastBalance
        Update-ReminderSummary
        $window.UpdateLayout()
        Save-PreviewPng $window.Content $size[0] $size[1] $size[2]
    }
    $window.MinWidth=258;$window.MinHeight=72
    $window.Width=286;$window.Height=78
    $layoutViewport.Visibility='Collapsed';$compactSection.Visibility='Visible'
    Reset-CompactTypography;Update-CompactBalance
    $compactBalanceText.Foreground=$balanceText.Foreground
    $compactStatusDot.Fill=$brushConverter.ConvertFromString('#FBBF24')
    $window.UpdateLayout()
    Save-PreviewPng $window.Content 286 78 'desktop-compact.png'
}
finally{$window.Close()}
[xml]$settingsXml=[regex]::Match($alerts,'(?s)\[xml\]\$xaml=@''\r?\n(.*?)\r?\n''@').Groups[1].Value
$reader=New-Object Xml.XmlNodeReader $settingsXml
$dialog=[Windows.Markup.XamlReader]::Load($reader)
$dialog.WindowStartupLocation='Manual';$dialog.Left=-20000;$dialog.Top=0
$dialog.FindName('Enabled').IsChecked=$true
$dialog.FindName('Threshold').Text='10'
$dialog.FindName('Repeat').Text='60'
try{
    $dialog.Show();$dialog.UpdateLayout()
    $content=$dialog.Content
    $dialog.Content=$null
    $frame=New-Object Windows.Controls.Border
    $frame.Background=$dialog.Background
    $frame.Child=$content
    [Windows.Documents.TextElement]::SetForeground($frame,$dialog.Foreground)
    [Windows.Documents.TextElement]::SetFontFamily($frame,$dialog.FontFamily)
    $size=[Windows.Size]::new(450,420)
    $frame.Measure($size);$frame.Arrange([Windows.Rect]::new($size));$frame.UpdateLayout()
    Save-PreviewPng $frame 450 420 'reminder-settings.png'
}
finally{$dialog.Close()}
