param([switch]$Once,[switch]$Demo)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'SchoolClient.ps1')
. (Join-Path $PSScriptRoot 'Alerts.ps1')
Initialize-PublicQuery
Initialize-ReminderSettings
function Add-BalanceHistory {
    param(
        [Parameter(Mandatory = $true)][double]$Balance,
        [Parameter(Mandatory = $true)][datetime]$Timestamp
    )

    if ($Demo) {
        $script:DemoHistory += [pscustomobject]@{Timestamp=$Timestamp;Balance=$Balance}
        return
    }
    if (-not (Test-Path -LiteralPath $HistoryDirectory)) {
        [void](New-Item -ItemType Directory -Path $HistoryDirectory -Force)
    }

    [pscustomobject]@{
        Timestamp = $Timestamp.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Balance   = $Balance.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    } | Export-Csv -LiteralPath $HistoryPath -NoTypeInformation -Encoding UTF8 -Append
}

function Get-BalanceHistory {
    param([int]$Hours = 0)
    if ($Demo) { return $script:DemoHistory }

    if (-not (Test-Path -LiteralPath $HistoryPath)) {
        return @()
    }

    $cutoff = $null
    if ($Hours -gt 0) {
        $cutoff = (Get-Date).AddHours(-$Hours)
    }
    $history = New-Object System.Collections.Generic.List[object]
    foreach ($row in @(Import-Csv -LiteralPath $HistoryPath -ErrorAction SilentlyContinue)) {
        $timestamp = [datetime]::MinValue
        $balance = 0.0
        if (
            [datetime]::TryParse(
                [string]$row.Timestamp,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$timestamp
            ) -and
            [double]::TryParse(
                [string]$row.Balance,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$balance
            ) -and
            ($null -eq $cutoff -or $timestamp -ge $cutoff)
        ) {
            $history.Add([pscustomobject]@{
                Timestamp = $timestamp
                Balance   = $balance
            })
        }
    }

    return @($history | Sort-Object Timestamp)
}

if ($Once) {
    $result = Get-DormBalance
    [pscustomobject]@{
        room    = $script:RoomDisplayName
        balance = [Math]::Round($result.Balance, 4)
        updated = $result.Updated.ToString('yyyy-MM-dd HH:mm:ss')
    } | ConvertTo-Json
    exit 0
}

$createdNew = $false
$appMutex = [System.Threading.Mutex]::new(
    $true,
    $('Local\NuistElectricityQuery_Display' + $(if ($Demo) { '_Demo' } else { '' })),
    [ref]$createdNew
)
if (-not $createdNew) {
    $appMutex.Dispose()
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class DesktopWidgetNative
{
    private static readonly IntPtr HWND_TOP = IntPtr.Zero;
    private static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    private const int GWL_EXSTYLE = -20;
    private const int GWL_STYLE = -16;
    private const long WS_EX_TOOLWINDOW = 0x00000080L;
    private const long WS_EX_TRANSPARENT = 0x00000020L;
    private const long WS_CHILD = 0x40000000L;
    private const long WS_POPUP = 0x80000000L;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const int SW_SHOWNOACTIVATE = 4;
    private const uint GA_ROOT = 2;
    private const uint GW_OWNER = 4;
    private const int DWMWA_CLOAKED = 14;



    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static string ScriptFileArgument(string commandLine)
    {
        if (String.IsNullOrEmpty(commandLine)) return null;
        int count;
        IntPtr arguments = CommandLineToArgvW(commandLine, out count);
        if (arguments == IntPtr.Zero) return null;
        try
        {
            for (int index = 1; index < count; index++)
            {
                string argument = Marshal.PtrToStringUni(Marshal.ReadIntPtr(arguments, index * IntPtr.Size));
                if (String.Equals(argument, "-File", StringComparison.OrdinalIgnoreCase))
                    return index + 1 < count ? Marshal.PtrToStringUni(Marshal.ReadIntPtr(arguments, (index + 1) * IntPtr.Size)) : null;
                // -Command / -EncodedCommand may contain text resembling -File.
                if (argument != null && argument.Length > 1 &&
                    ("-Command".StartsWith(argument, StringComparison.OrdinalIgnoreCase) ||
                     "-EncodedCommand".StartsWith(argument, StringComparison.OrdinalIgnoreCase))) return null;
            }
            return null;
        }
        finally { LocalFree(arguments); }
    }

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder className, int maxCount);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [StructLayout(LayoutKind.Sequential)]
    private struct CursorPoint { public int X, Y; }

    [DllImport("user32.dll")]
    private static extern bool GetPhysicalCursorPos(out CursorPoint point);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int virtualKey);

    [DllImport("user32.dll")]
    public static extern IntPtr SetCapture(IntPtr window);

    [DllImport("user32.dll")]
    public static extern IntPtr GetCapture();

    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();

    public static int[] PhysicalCursorPosition()
    {
        CursorPoint point;
        return GetPhysicalCursorPos(out point) ? new int[] { point.X, point.Y } : null;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetParent(IntPtr child, IntPtr newParent);

    [DllImport("user32.dll")]
    private static extern IntPtr GetParent(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr window, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint relationship);

    [DllImport("user32.dll")]
    private static extern bool IsChild(IntPtr parent, IntPtr child);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder caption, int maxCount);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
    private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr newValue);

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out Rect rect);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(
        IntPtr window,
        int attribute,
        out int value,
        int valueSize
    );

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(
        IntPtr window,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags
    );

    public static bool SetWindowBounds(IntPtr window, int x, int y, int width, int height)
    {
        if (window == IntPtr.Zero || width < 1 || height < 1) return false;
        return SetWindowPos(window, IntPtr.Zero, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
    }

    private static string ClassNameOf(IntPtr window)
    {
        StringBuilder name = new StringBuilder(128);
        GetClassName(window, name, name.Capacity);
        return name.ToString();
    }

    private static bool IsDesktopClass(string className)
    {
        return className == "Progman" ||
               className == "WorkerW" ||
               className == "SHELLDLL_DefView" ||
               className == "SysListView32";
    }

    public static IntPtr FindDesktopView()
    {
        IntPtr desktopView = IntPtr.Zero;
        EnumWindows(delegate(IntPtr topLevel, IntPtr parameter)
        {
            string className = ClassNameOf(topLevel);
            // Host the widget directly on Progman.  Making it a child of
            // SHELLDLL_DefView works with a static wallpaper, but animated
            // wallpaper engines paint over that icon surface.  A Progman
            // child placed above DefView remains desktop-only and is still
            // covered normally by every application window.
            if (className == "Progman")
            {
                desktopView = topLevel;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return desktopView;
    }

    public static bool AttachToDesktop(IntPtr widget)
    {
        if (widget == IntPtr.Zero) return false;
        IntPtr desktopView = FindDesktopView();
        if (desktopView == IntPtr.Zero) return false;

        long style = GetWindowLongPtr(widget, GWL_STYLE).ToInt64();
        style = (style | WS_CHILD) & ~WS_POPUP;
        SetWindowLongPtr(widget, GWL_STYLE, new IntPtr(style));

        if (GetParent(widget) != desktopView)
        {
            SetParent(widget, desktopView);
            if (GetParent(widget) != desktopView) return false;
        }
        SetWindowPos(
            widget,
            HWND_TOP,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW
        );
        return true;
    }

    public static bool IsAttachedToDesktop(IntPtr widget)
    {
        IntPtr desktopView = FindDesktopView();
        return widget != IntPtr.Zero && desktopView != IntPtr.Zero && GetParent(widget) == desktopView;
    }

    private static bool HasOpenApplicationWindow(IntPtr widget)
    {
        bool found = false;
        uint ownProcessId = (uint)Process.GetCurrentProcess().Id;
        EnumWindows(delegate(IntPtr candidate, IntPtr parameter)
        {
            if (candidate == widget || !IsWindowVisible(candidate) || IsIconic(candidate)) return true;

            uint processId;
            GetWindowThreadProcessId(candidate, out processId);
            if (processId == ownProcessId) return true;

            string className = ClassNameOf(candidate);
            if (IsDesktopClass(className) ||
                className == "Shell_TrayWnd" ||
                className == "Shell_SecondaryTrayWnd") return true;

            int cloaked = 0;
            if (DwmGetWindowAttribute(candidate, DWMWA_CLOAKED, out cloaked, sizeof(int)) == 0 && cloaked != 0)
                return true;

            long exStyle = GetWindowLongPtr(candidate, GWL_EXSTYLE).ToInt64();
            if ((exStyle & WS_EX_TOOLWINDOW) != 0) return true;

            Rect rect;
            if (!GetWindowRect(candidate, out rect) || rect.Right - rect.Left < 80 || rect.Bottom - rect.Top < 80)
                return true;

            if (GetWindowTextLength(candidate) == 0) return true;
            found = true;
            return false;
        }, IntPtr.Zero);
        return found;
    }





    private static bool IsOwnedByWidget(IntPtr window, IntPtr widget)
    {
        uint windowProcessId, widgetProcessId;
        GetWindowThreadProcessId(window, out windowProcessId);
        GetWindowThreadProcessId(widget, out widgetProcessId);
        if (windowProcessId == 0 || windowProcessId != widgetProcessId) return false;
        IntPtr candidate = GetAncestor(window, GA_ROOT);
        for (int depth = 0; candidate != IntPtr.Zero && depth < 16; depth++)
        {
            uint candidateProcessId;
            GetWindowThreadProcessId(candidate, out candidateProcessId);
            if (candidateProcessId != widgetProcessId) return false;
            if (candidate == widget) return true;
            IntPtr next = GetWindow(candidate, GW_OWNER);
            if (next == candidate) return false;
            candidate = next;
        }
        return false;
    }

    public static string VisibilityReason(IntPtr widget)
    {
        if (widget == IntPtr.Zero) return "transient";
        IntPtr foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero) return "transient";

        IntPtr foregroundRoot = GetAncestor(foreground, GA_ROOT);
        bool widgetActive = foreground == widget || foregroundRoot == widget || IsChild(widget, foreground);
        if (!widgetActive) widgetActive = IsOwnedByWidget(foreground, widget);
        if (widgetActive) return "widget";
        string foregroundClass = ClassNameOf(foreground);
        string rootClass = ClassNameOf(foregroundRoot);
        bool taskbarActive = foregroundClass == "Shell_TrayWnd" || foregroundClass == "Shell_SecondaryTrayWnd" ||
                             rootClass == "Shell_TrayWnd" || rootClass == "Shell_SecondaryTrayWnd";
        if (taskbarActive) return HasOpenApplicationWindow(widget) ? "application" : "desktop";
        bool desktopActive = IsDesktopClass(foregroundClass) || IsDesktopClass(rootClass);
        return desktopActive ? "desktop" : "application";
    }

    public static bool ShouldShow(IntPtr widget)
    {
        string reason = VisibilityReason(widget);
        return reason == "widget" || reason == "companion" || reason == "desktop";
    }

    public static bool DetachFromDesktop(IntPtr widget)
    {
        if (widget == IntPtr.Zero) return false;
        if (GetParent(widget) != IntPtr.Zero) SetParent(widget, IntPtr.Zero);

        long style = GetWindowLongPtr(widget, GWL_STYLE).ToInt64();
        style = (style | WS_POPUP) & ~WS_CHILD;
        SetWindowLongPtr(widget, GWL_STYLE, new IntPtr(style));
        return GetParent(widget) == IntPtr.Zero;
    }



    public static void PrepareVisible(IntPtr widget)
    {
        if (widget == IntPtr.Zero) return;
        long exStyle = GetWindowLongPtr(widget, GWL_EXSTYLE).ToInt64();
        SetWindowLongPtr(widget, GWL_EXSTYLE, new IntPtr(exStyle & ~WS_EX_TRANSPARENT));
        ShowWindow(widget, SW_SHOWNOACTIVATE);
        SetWindowPos(
            widget,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW
        );
    }

    public static void PrepareHidden(IntPtr widget)
    {
        if (widget == IntPtr.Zero) return;
        long exStyle = GetWindowLongPtr(widget, GWL_EXSTYLE).ToInt64();
        SetWindowLongPtr(widget, GWL_EXSTYLE, new IntPtr(exStyle | WS_EX_TRANSPARENT));
        SetWindowPos(
            widget,
            HWND_NOTOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
        );
        // Leave it truly invisible while another application is active.
        ShowWindow(widget, 0);
    }
}
'@

$motionReferences = @(
    [Windows.Window].Assembly.Location,
    [Windows.Media.Visual].Assembly.Location,
    [Windows.Threading.Dispatcher].Assembly.Location,
    [System.Xaml.XamlReader].Assembly.Location
)
Add-Type -Path (Join-Path $PSScriptRoot 'PowerBalance.Motion.cs') -ReferencedAssemblies $motionReferences

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Width="384" Height="612" MinWidth="300" MinHeight="300"
        WindowStyle="None" ResizeMode="CanResizeWithGrip"
        AllowsTransparency="True" Background="Transparent" Topmost="False"
        ShowInTaskbar="False" Title="Power Balance" FontFamily="Segoe UI"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
    <Window.Resources>
        <Style x:Key="HeaderButtonStyle" TargetType="Button">
            <Setter Property="Width" Value="32"/>
            <Setter Property="Height" Value="32"/>
            <Setter Property="Foreground" Value="#B8C5D9"/>
            <Setter Property="Background" Value="#12FFFFFF"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="17"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="10" BorderBrush="#22FFFFFF" BorderThickness="1">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#28FFFFFF"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.72"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="RangeButtonStyle" TargetType="Button">
            <Setter Property="Height" Value="34"/>
            <Setter Property="Margin" Value="3,0"/>
            <Setter Property="Foreground" Value="#75849A"/>
            <Setter Property="Background" Value="#0DFFFFFF"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="RangeBorder" Background="{TemplateBinding Background}" CornerRadius="11" BorderBrush="#18FFFFFF" BorderThickness="1">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="RangeBorder" Property="Background" Value="#1AFFFFFF"/>
                                <Setter Property="Foreground" Value="#DCE7F5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScaleButtonStyle" TargetType="Button" BasedOn="{StaticResource RangeButtonStyle}">
            <Setter Property="Width" Value="38"/>
            <Setter Property="Height" Value="22"/>
            <Setter Property="Margin" Value="2,0"/>
            <Setter Property="FontSize" Value="9"/>
        </Style>
        <Style x:Key="ChartZoomButtonStyle" TargetType="Button" BasedOn="{StaticResource ScaleButtonStyle}">
            <Setter Property="Width" Value="22"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="Bold"/>
        </Style>
        <Style x:Key="ResizeThumbStyle" TargetType="Thumb">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Panel.ZIndex" Value="100"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border Background="Transparent"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="6"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True" Margin="1,2">
                            <Track.DecreaseRepeatButton><RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton>
                            <Track.Thumb><Thumb MinHeight="24"><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#6675869C" CornerRadius="3"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                            <Track.IncreaseRepeatButton><RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton>
                        </Track>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <shell:WindowChrome.WindowChrome>
        <shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="8" CornerRadius="0" GlassFrameThickness="0" UseAeroCaptionButtons="False"/>
    </shell:WindowChrome.WindowChrome>
    <Grid>
    <Border x:Name="GlassSurface" CornerRadius="26" BorderBrush="#26FFFFFF" BorderThickness="1">
        <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#F3162031" Offset="0"/>
                <GradientStop Color="#F00B111D" Offset="0.55"/>
                <GradientStop Color="#F314182A" Offset="1"/>
            </LinearGradientBrush>
        </Border.Background>
        <Grid>
            <Border x:Name="GlassGlowLayer" CornerRadius="26" IsHitTestVisible="False" Opacity="0.58">
                <Border.Background>
                    <RadialGradientBrush x:Name="GlassGlowBrush" Center="0.18,0.10" GradientOrigin="0.18,0.10" RadiusX="0.72" RadiusY="0.60">
                        <GradientStop Color="#365EEAD4" Offset="0"/>
                        <GradientStop Color="#1267E8F9" Offset="0.38"/>
                        <GradientStop Color="#00000000" Offset="1"/>
                    </RadialGradientBrush>
                </Border.Background>
            </Border>
            <Border x:Name="GlassSheenLayer" CornerRadius="26" IsHitTestVisible="False" Opacity="0.42">
                <Border.Background>
                    <LinearGradientBrush x:Name="GlassSheenBrush" StartPoint="-0.35,-0.15" EndPoint="0.75,0.85">
                        <GradientStop Color="#00FFFFFF" Offset="0"/>
                        <GradientStop Color="#24FFFFFF" Offset="0.46"/>
                        <GradientStop Color="#05FFFFFF" Offset="0.54"/>
                        <GradientStop Color="#00000000" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
            </Border>
            <ScrollViewer x:Name="LayoutViewport" Margin="22,18,22,18" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False" PanningMode="VerticalOnly">
            <Grid x:Name="LayoutGrid">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition x:Name="LayoutLeftColumn" Width="*"/>
                    <ColumnDefinition x:Name="LayoutRightColumn" Width="0"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="94"/>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="150"/>
                    <RowDefinition Height="138"/>
                    <RowDefinition Height="56"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Grid x:Name="HeaderSection" Grid.Row="0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="0"/></Grid.RowDefinitions>
                    <Viewbox x:Name="HeaderTitleBox" Grid.Column="0" Stretch="Uniform" StretchDirection="DownOnly" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="0,0,10,0">
                    <StackPanel>
                        <TextBlock Text="D O R M   E N E R G Y" Foreground="#5EEAD4" FontSize="9" FontWeight="Bold"/>
                        <TextBlock x:Name="MainRoomText" Text="Your room" Foreground="#D9E4F2" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,0"/>
                    </StackPanel>
                    </Viewbox>
                    <StackPanel x:Name="HeaderActions" Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Button x:Name="CollapseButton" Content="&#x2212;" ToolTip="&#x6298;&#x53E0;&#x7A97;&#x53E3;" Style="{StaticResource HeaderButtonStyle}" Margin="0,0,8,0"/>
                        <Button x:Name="AuthButton" Content="&#x8BBE;&#x7F6E;" Width="42" FontSize="10" Style="{StaticResource HeaderButtonStyle}" Margin="0,0,8,0"/>
                        <Button x:Name="RefreshButton" Content="&#x21BB;" Style="{StaticResource HeaderButtonStyle}" Margin="0,0,8,0"/>
                        <Button x:Name="CloseButton" Content="&#x00D7;" Style="{StaticResource HeaderButtonStyle}"/>
                    </StackPanel>
                </Grid>

                <StackPanel x:Name="BalanceSection" Grid.Row="1" VerticalAlignment="Center" HorizontalAlignment="Center">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                        <Border Width="34" Height="34" CornerRadius="17" Background="#225EEAD4" BorderBrush="#405EEAD4" BorderThickness="1" Margin="0,0,9,0" VerticalAlignment="Center">
                            <TextBlock Text="&#x26A1;" Foreground="#6FFFE9" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock x:Name="BalanceText" Text="--" Foreground="#E8FFFB" FontSize="52" FontWeight="SemiBold"/>
                        <TextBlock Text=" &#x5EA6;" Foreground="#8291A8" FontSize="17" VerticalAlignment="Bottom" Margin="0,0,0,9"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,-2,0,0">
                        <TextBlock Text="&#x533A;&#x95F4;&#x53D8;&#x5316;" Foreground="#6E7C91" FontSize="10"/>
                        <TextBlock x:Name="BalanceDeltaText" Text=" --" Foreground="#8EA0B8" FontSize="10" FontWeight="SemiBold"/>
                    </StackPanel>
                </StackPanel>

                <Border x:Name="RangeSection" Grid.Row="2" Background="#12000000" BorderBrush="#1EFFFFFF" BorderThickness="1" CornerRadius="13" Padding="3" Margin="0,2,0,5">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Button x:Name="DayRangeButton" Grid.Column="0" Content="&#x4ECA;&#x65E5;" Style="{StaticResource RangeButtonStyle}"/>
                        <Button x:Name="WeekRangeButton" Grid.Column="1" Content="&#x672C;&#x5468;" Style="{StaticResource RangeButtonStyle}"/>
                        <Button x:Name="MonthRangeButton" Grid.Column="2" Content="&#x672C;&#x6708;" Style="{StaticResource RangeButtonStyle}"/>
                        <Button x:Name="AllRangeButton" Grid.Column="3" Content="&#x5168;&#x90E8;" Style="{StaticResource RangeButtonStyle}"/>
                    </Grid>
                </Border>

                <Border x:Name="ChartSection" Grid.Row="3" Background="#12FFFFFF" BorderBrush="#28FFFFFF" BorderThickness="1" CornerRadius="17" Margin="0,4,0,10" Padding="13,10,13,7">
                    <Border.Effect><DropShadowEffect Color="#020617" BlurRadius="16" ShadowDepth="3" Opacity="0.28"/></Border.Effect>
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <Grid x:Name="ChartHeader" Grid.Row="0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <StackPanel x:Name="ChartHeading">
                                <TextBlock Text="&#x7535;&#x91CF;&#x8D8B;&#x52BF;" Foreground="#E2EAF5" FontSize="12" FontWeight="SemiBold"/>
                                <TextBlock x:Name="PeriodText" Text="Today" Foreground="#607086" FontSize="9" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                            <StackPanel x:Name="ChartActions" Grid.Column="1" HorizontalAlignment="Right">
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                    <Button x:Name="MinuteScaleButton" Content="&#x5206;&#x949F;" Style="{StaticResource ScaleButtonStyle}"/>
                                    <Button x:Name="HourScaleButton" Content="&#x5C0F;&#x65F6;" Style="{StaticResource ScaleButtonStyle}"/>
                                    <Button x:Name="ChartZoomOutButton" Content="&#x2212;" ToolTip="&#x7F29;&#x5C0F;" Style="{StaticResource ChartZoomButtonStyle}"/>
                                    <Button x:Name="ChartResetButton" Content="&#x25CE;" ToolTip="&#x67E5;&#x770B;&#x5168;&#x90E8;" Style="{StaticResource ChartZoomButtonStyle}"/>
                                    <Button x:Name="ChartZoomInButton" Content="+" ToolTip="&#x653E;&#x5927;" Style="{StaticResource ChartZoomButtonStyle}"/>
                                </StackPanel>
                                <TextBlock x:Name="ChartRangeText" Text="Waiting for data" Foreground="#718198" FontSize="8" HorizontalAlignment="Right" Margin="0,2,1,0" ToolTip="&#x6EDA;&#x8F6E;&#x7F29;&#x653E; &#x00B7; &#x62D6;&#x52A8;&#x5E73;&#x79FB; &#x00B7; &#x53CC;&#x51FB;&#x590D;&#x4F4D;"/>
                            </StackPanel>
                        </Grid>
                        <Canvas x:Name="ChartCanvas" Grid.Row="1" MinHeight="60" Margin="0,5,0,0" ClipToBounds="True" Cursor="Hand" ToolTip="&#x6EDA;&#x8F6E;&#x7F29;&#x653E; &#x00B7; &#x62D6;&#x52A8;&#x5E73;&#x79FB; &#x00B7; &#x53CC;&#x51FB;&#x590D;&#x4F4D;"/>
                    </Grid>
                </Border>

                <Grid x:Name="StatsSection" Grid.Row="4" Margin="-4,-1,-4,5">
                    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Grid.Row="0" Grid.Column="0" Background="#0FFFFFFF" BorderBrush="#20FFFFFF" BorderThickness="1" CornerRadius="14" Margin="4" Padding="12,8">
                        <StackPanel VerticalAlignment="Center"><TextBlock Text="&#x7D2F;&#x8BA1;&#x7528;&#x7535;" Foreground="#69798F" FontSize="9"/><Viewbox Stretch="Uniform" StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="ConsumedText" Text="--" Foreground="#EEF5FF" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,0"/></Viewbox></StackPanel>
                    </Border>
                    <Border Grid.Row="0" Grid.Column="1" Background="#0FFFFFFF" BorderBrush="#20FFFFFF" BorderThickness="1" CornerRadius="14" Margin="4" Padding="12,8">
                        <StackPanel VerticalAlignment="Center"><TextBlock Text="&#x65E5;&#x5747;&#x7528;&#x7535;" Foreground="#69798F" FontSize="9"/><Viewbox Stretch="Uniform" StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="DailyAverageText" Text="--" Foreground="#EEF5FF" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,0"/></Viewbox></StackPanel>
                    </Border>
                    <Border Grid.Row="1" Grid.Column="0" Background="#0FFFFFFF" BorderBrush="#20FFFFFF" BorderThickness="1" CornerRadius="14" Margin="4" Padding="12,8">
                        <StackPanel VerticalAlignment="Center"><TextBlock Text="&#x6B63;&#x5411;&#x7535;&#x91CF;&#x53D8;&#x5316;" Foreground="#69798F" FontSize="9"/><Viewbox Stretch="Uniform" StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="RechargedText" Text="--" Foreground="#EEF5FF" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,0"/></Viewbox></StackPanel>
                    </Border>
                    <Border Grid.Row="1" Grid.Column="1" Background="#0FFFFFFF" BorderBrush="#20FFFFFF" BorderThickness="1" CornerRadius="14" Margin="4" Padding="12,8">
                        <StackPanel VerticalAlignment="Center"><TextBlock Text="&#x9884;&#x8BA1;&#x53EF;&#x7528;" Foreground="#69798F" FontSize="9"/><Viewbox Stretch="Uniform" StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="EstimatedDaysText" Text="--" Foreground="#EEF5FF" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,0"/></Viewbox></StackPanel>
                    </Border>
                </Grid>

                <Border x:Name="PeakSection" Grid.Row="5" Background="#125EEAD4" BorderBrush="#325EEAD4" BorderThickness="1" CornerRadius="14" Margin="0,0,0,6" Padding="12,7">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <StackPanel VerticalAlignment="Center" Margin="0,0,8,0">
                            <TextBlock Text="&#x8017;&#x7535;&#x6700;&#x591A;&#x65F6;&#x6BB5;" Foreground="#7D8DA3" FontSize="9"/>
                            <Viewbox Stretch="Uniform" StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="PeakPeriodText" Text="--" Foreground="#EEF5FF" FontSize="13" FontWeight="SemiBold" Margin="0,2,0,0"/></Viewbox>
                        </StackPanel>
                        <TextBlock x:Name="PeakUsageText" Grid.Column="1" Text="--" Foreground="#63F5DF" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    </Grid>
                </Border>

                <StackPanel x:Name="StatusSection" Grid.Row="6" VerticalAlignment="Center">
                    <TextBlock x:Name="StatusText" Text="Starting..." Foreground="#8291A8" FontSize="10" TextAlignment="Center" TextWrapping="Wrap"/>
                    <TextBlock x:Name="ReminderStatusText" Text="&#x4F4E;&#x7535;&#x91CF;&#x63D0;&#x9192;" Foreground="#8291A8" FontSize="9" TextAlignment="Center" TextWrapping="Wrap" Margin="0,3,0,0"/>
                </StackPanel>
            </Grid>
            </ScrollViewer>
            <Grid x:Name="CompactSection" Visibility="Collapsed" Margin="14,9,11,9">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="42"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="40"/>
                </Grid.ColumnDefinitions>
                <Border Width="34" Height="34" CornerRadius="17" Background="#285EEAD4" BorderBrush="#555EEAD4" BorderThickness="1" VerticalAlignment="Center">
                    <TextBlock x:Name="CompactIconText" Text="&#x26A1;" Foreground="#8AFFF0" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <Grid Grid.Column="1" Margin="3,0,8,0">
                    <Grid.RowDefinitions><RowDefinition Height="18"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock x:Name="CompactRoomText" Text="Your room" Foreground="#9BACBF" FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <StackPanel Grid.Row="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="CompactStatusDot" Width="6" Height="6" Fill="#5EEAD4" Margin="0,0,6,0" VerticalAlignment="Center"/>
                        <TextBlock x:Name="CompactBalanceText" Text="--" Foreground="#E8FFFB" FontSize="23" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        <TextBlock x:Name="CompactUnitText" Text=" &#x5EA6;" Foreground="#8291A8" FontSize="10" VerticalAlignment="Bottom" Margin="0,0,0,4"/>
                    </StackPanel>
                </Grid>
                <Button x:Name="ExpandButton" Grid.Column="2" Content="&#x2304;" ToolTip="&#x5C55;&#x5F00;&#x7A97;&#x53E3;" Style="{StaticResource HeaderButtonStyle}" Width="36" Height="36" FontSize="20" VerticalAlignment="Center"/>
            </Grid>
        </Grid>
    </Border>
    <Thumb x:Name="ResizeLeft" Tag="left" Width="9" HorizontalAlignment="Left" VerticalAlignment="Stretch" Cursor="SizeWE" Style="{StaticResource ResizeThumbStyle}"/>
    <Thumb x:Name="ResizeRight" Tag="right" Width="9" HorizontalAlignment="Right" VerticalAlignment="Stretch" Cursor="SizeWE" Style="{StaticResource ResizeThumbStyle}"/>
    <Thumb x:Name="ResizeTop" Tag="top" Height="9" HorizontalAlignment="Stretch" VerticalAlignment="Top" Cursor="SizeNS" Style="{StaticResource ResizeThumbStyle}"/>
    <Thumb x:Name="ResizeBottom" Tag="bottom" Height="9" HorizontalAlignment="Stretch" VerticalAlignment="Bottom" Cursor="SizeNS" Style="{StaticResource ResizeThumbStyle}"/>
    <Thumb x:Name="ResizeTopLeft" Tag="top-left" Width="18" Height="18" HorizontalAlignment="Left" VerticalAlignment="Top" Cursor="SizeNWSE" Style="{StaticResource ResizeThumbStyle}"/>
    <Thumb x:Name="ResizeTopRight" Tag="top-right" Width="18" Height="18" HorizontalAlignment="Right" VerticalAlignment="Top" Cursor="SizeNESW" Style="{StaticResource ResizeThumbStyle}"/>
    <Thumb x:Name="ResizeBottomLeft" Tag="bottom-left" Width="18" Height="18" HorizontalAlignment="Left" VerticalAlignment="Bottom" Cursor="SizeNESW" Style="{StaticResource ResizeThumbStyle}"/>
    <Thumb x:Name="ResizeBottomRight" Tag="bottom-right" Width="22" Height="22" HorizontalAlignment="Right" VerticalAlignment="Bottom" Cursor="SizeNWSE" Style="{StaticResource ResizeThumbStyle}"/>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$balanceText = $window.FindName('BalanceText')
$balanceDeltaText = $window.FindName('BalanceDeltaText')
$statusText = $window.FindName('StatusText')
$chartCanvas = $window.FindName('ChartCanvas')
$chartRangeText = $window.FindName('ChartRangeText')
$periodText = $window.FindName('PeriodText')
$consumedText = $window.FindName('ConsumedText')
$dailyAverageText = $window.FindName('DailyAverageText')
$rechargedText = $window.FindName('RechargedText')
$estimatedDaysText = $window.FindName('EstimatedDaysText')
$peakPeriodText = $window.FindName('PeakPeriodText')
$peakUsageText = $window.FindName('PeakUsageText')
$dayRangeButton = $window.FindName('DayRangeButton')
$weekRangeButton = $window.FindName('WeekRangeButton')
$monthRangeButton = $window.FindName('MonthRangeButton')
$allRangeButton = $window.FindName('AllRangeButton')
$minuteScaleButton = $window.FindName('MinuteScaleButton')
$hourScaleButton = $window.FindName('HourScaleButton')
$chartZoomOutButton = $window.FindName('ChartZoomOutButton')
$chartResetButton = $window.FindName('ChartResetButton')
$chartZoomInButton = $window.FindName('ChartZoomInButton')
$authButton = $window.FindName('AuthButton')
$collapseButton = $window.FindName('CollapseButton')
$expandButton = $window.FindName('ExpandButton')
$compactSection = $window.FindName('CompactSection')
$compactBalanceText = $window.FindName('CompactBalanceText')
$compactStatusDot = $window.FindName('CompactStatusDot')
$compactIconText = $window.FindName('CompactIconText')
$compactRoomText = $window.FindName('CompactRoomText')
$compactUnitText = $window.FindName('CompactUnitText')
$glassSurface = $window.FindName('GlassSurface')
$glassGlowLayer = $window.FindName('GlassGlowLayer')
$glassGlowBrush = $window.FindName('GlassGlowBrush')
$glassSheenLayer = $window.FindName('GlassSheenLayer')
$glassSheenBrush = $window.FindName('GlassSheenBrush')
$layoutGrid = $window.FindName('LayoutGrid')
$layoutViewport = $window.FindName('LayoutViewport')
$headerTitleBox = $window.FindName('HeaderTitleBox')
$headerActions = $window.FindName('HeaderActions')
$chartHeader = $window.FindName('ChartHeader')
$chartHeading = $window.FindName('ChartHeading')
$chartActions = $window.FindName('ChartActions')
$layoutLeftColumn = $window.FindName('LayoutLeftColumn')
$layoutRightColumn = $window.FindName('LayoutRightColumn')
$headerSection = $window.FindName('HeaderSection')
$balanceSection = $window.FindName('BalanceSection')
$rangeSection = $window.FindName('RangeSection')
$chartSection = $window.FindName('ChartSection')
$statsSection = $window.FindName('StatsSection')
$peakSection = $window.FindName('PeakSection')
$statusSection = $window.FindName('StatusSection')
$resizeThumbs = @(
    $window.FindName('ResizeLeft'),
    $window.FindName('ResizeRight'),
    $window.FindName('ResizeTop'),
    $window.FindName('ResizeBottom'),
    $window.FindName('ResizeTopLeft'),
    $window.FindName('ResizeTopRight'),
    $window.FindName('ResizeBottomLeft'),
    $window.FindName('ResizeBottomRight')
)
$refreshButton = $window.FindName('RefreshButton')
$closeButton = $window.FindName('CloseButton')
$brushConverter = New-Object Windows.Media.BrushConverter
$script:SelectedRange = 'all'
$script:ChartGranularity = 'minute'
$script:ChartZoom = 1.0
$script:ChartViewStartRatio = 0.0
$script:ChartInteractionActive = $false
$script:ChartHistoryCache = $null
$script:ChartHistoryCacheKey = $null
$script:LastBalance = $null
$script:ChartNeedsRender = $false
$script:PendingBalanceRefresh = $false
$script:FoldLayoutHoldUntil = [DateTime]::MinValue
$script:IsCollapsed = $false
$script:ExpandedGeometry = $null
$script:FoldAnimation = $null
$script:GlassCurrentX = 0.18
$script:GlassCurrentY = 0.10
$script:GlassTargetX = 0.18
$script:GlassTargetY = 0.10
$script:GlassPointerInside = $false
$script:GlassIdleTicks = 0
$rangeButtonMap = @{
    day   = $dayRangeButton
    week  = $weekRangeButton
    month = $monthRangeButton
    all   = $allRangeButton
}
$scaleButtonMap = @{
    minute = $minuteScaleButton
    hour   = $hourScaleButton
}

function Set-PublicLabels {
    $window.FindName('MainRoomText').Text=$script:RoomDisplayName
    $compactRoomText.Text=$script:RoomDisplayName
    $script:LastBalance=$null
    $balanceText.Text='--'
    Update-CompactBalance
}
function Constrain-WidgetToWorkArea {
    $area = [System.Windows.SystemParameters]::WorkArea
    if ($window.Width -gt $area.Width) { $window.Width = $area.Width }
    if ($window.Height -gt $area.Height) { $window.Height = $area.Height }

    $maximumLeft = $area.Right - $window.Width
    $maximumTop = $area.Bottom - $window.Height
    if ($window.Left -lt $area.Left) { $window.Left = $area.Left }
    if ($window.Left -gt $maximumLeft) { $window.Left = $maximumLeft }
    if ($window.Top -lt $area.Top) { $window.Top = $area.Top }
    if ($window.Top -gt $maximumTop) { $window.Top = $maximumTop }
}

function Update-CompactBalance {
    if ($null -eq $script:LastBalance) {
        $compactBalanceText.Text = '--'
        $compactBalanceText.Foreground = $brushConverter.ConvertFromString('#E8FFFB')
        return
    }

    $compactBalanceText.Text = ('{0:N2}' -f [double]$script:LastBalance)
    if ([double]$script:LastBalance -lt 10) {
        $compactBalanceText.Foreground = $brushConverter.ConvertFromString('#FB7185')
    }
    elseif ([double]$script:LastBalance -lt 20) {
        $compactBalanceText.Foreground = $brushConverter.ConvertFromString('#FBBF24')
    }
    else {
        $compactBalanceText.Foreground = $brushConverter.ConvertFromString('#5EEAD4')
    }
}

function Reset-CompactTypography {
    $compactIconText.FontSize = 17
    $compactRoomText.FontSize = 10
    $compactBalanceText.FontSize = 23
    $compactUnitText.FontSize = 10
    $expandButton.Width = 36
    $expandButton.Height = 36
    $expandButton.FontSize = 20
}

function Set-ResizeThumbsVisible {
    param([Parameter(Mandatory = $true)][bool]$Visible)
    foreach ($thumb in $resizeThumbs) {
        $thumb.Visibility = if ($Visible) { 'Visible' } else { 'Collapsed' }
        $thumb.IsEnabled = $Visible
    }
}

function Complete-FoldTransition {
    param([Parameter(Mandatory = $true)][bool]$Expanded)

    $script:FoldLayoutHoldUntil = [DateTime]::UtcNow.AddMilliseconds(320)
    if ($Expanded) {
        $window.MinWidth = 300
        $window.MinHeight = 300
        $window.ResizeMode = 'CanResizeWithGrip'
        $compactSection.Visibility = 'Collapsed'
        $layoutViewport.Visibility = 'Visible'
        Set-ResizeThumbsVisible -Visible $true
        $script:IsCollapsed = $false
        Set-ResponsiveLayout
        # The hidden layout and its chart visuals are retained while folded.
        # Reusing them avoids rebuilding up to 1,600 plotted elements at the
        # exact moment the geometry animation finishes.
        if ($script:ChartNeedsRender) {
            $postFoldChartTimer.Stop()
            $postFoldChartTimer.Start()
        }
    }
    else {
        $layoutViewport.Visibility = 'Collapsed'
        $compactSection.Visibility = 'Visible'
        Set-ResizeThumbsVisible -Visible $false
        $window.ResizeMode = 'NoResize'
        $script:IsCollapsed = $true
        Update-CompactBalance
    }
    Constrain-WidgetToWorkArea
    $script:FoldLayoutWidth = $window.ActualWidth
    $script:FoldLayoutHeight = $window.ActualHeight
    $script:FoldAnimation = $null
    Complete-WidgetGeometryEditing
    if ($script:PendingBalanceRefresh) { $deferredBalanceTimer.Start() }
    if ($script:GlassPointerInside -or $script:GlassWasRunning) {
        $script:GlassIdleTicks = 0
        $glassMotionTimer.Start()
    }
    $script:GlassWasRunning = $false
}

function Start-FoldTransition {
    param([Parameter(Mandatory = $true)][bool]$Expand)
    if ($null -ne $script:FoldAnimation -or $script:WidgetGeometryEditing) { return }
    if ($Expand -and (-not $script:IsCollapsed -or $null -eq $script:ExpandedGeometry)) { return }
    if (-not $Expand -and $script:IsCollapsed) { return }

    # Stop pending chart work before preparing animation snapshots. Query
    # callbacks defer themselves until the motion has completed.
    $script:FoldAnimation = [pscustomobject]@{ Expand = $Expand }
    $script:WidgetGeometryEditing = $true
    $script:WidgetVisibilityCandidate = $null
    $resizeRedrawTimer.Stop()
    if ($script:ChartInteractionTimer.IsEnabled) { $script:ChartNeedsRender = $true }
    $script:ChartInteractionTimer.Stop()
    $postFoldChartTimer.Stop()
    $script:GlassWasRunning = $glassMotionTimer.IsEnabled
    $glassMotionTimer.Stop()

    $currentWidth = [double]$window.ActualWidth
    $currentHeight = [double]$window.ActualHeight
    if ($currentWidth -le 0) { $currentWidth = [double]$window.Width }
    if ($currentHeight -le 0) { $currentHeight = [double]$window.Height }
    $currentRight = [double]$window.Left + $currentWidth
    $workArea = [System.Windows.SystemParameters]::WorkArea

    if ($Expand) {
        $targetWidth = [Math]::Max(300.0, [Math]::Min([double]$script:ExpandedGeometry.Width, $workArea.Width))
        $targetHeight = [Math]::Max(300.0, [Math]::Min([double]$script:ExpandedGeometry.Height, $workArea.Height))
        $targetLeft = [Math]::Max($workArea.Left, [Math]::Min($workArea.Right - $targetWidth, $currentRight - $targetWidth))
        $targetTop = [Math]::Max($workArea.Top, [Math]::Min($workArea.Bottom - $targetHeight, [double]$window.Top))
    }
    else {
        $script:ExpandedGeometry = [pscustomobject]@{ Width = $currentWidth; Height = $currentHeight }
        $script:IsCollapsed = $true
        Reset-CompactTypography
        Update-CompactBalance
        Set-ResizeThumbsVisible -Visible $false
        $window.ResizeMode = 'NoResize'
        $window.MinWidth = 258
        $window.MinHeight = 72
        $targetWidth = [Math]::Min(286.0, $workArea.Width)
        $targetHeight = [Math]::Min(78.0, $workArea.Height)
        $targetLeft = [Math]::Max($workArea.Left, [Math]::Min($workArea.Right - $targetWidth, $currentRight - $targetWidth))
        $targetTop = [Math]::Max($workArea.Top, [Math]::Min($workArea.Bottom - $targetHeight, [double]$window.Top))
    }

    $script:FoldAnimation = [pscustomobject]@{
        Expand = $Expand; Width = $targetWidth; Height = $targetHeight
        Left = $targetLeft; Top = $targetTop
    }
    try {
        $foldMotion.Start($Expand, $targetLeft, $targetTop, $targetWidth, $targetHeight)
    }
    catch {
        # A snapshot/render failure must leave a usable final window.
        $window.Width = $targetWidth
        $window.Height = $targetHeight
        $window.Left = $targetLeft
        $window.Top = $targetTop
        $glassSurface.Visibility = 'Visible'
        Complete-FoldTransition -Expanded $Expand
        try {
            [IO.File]::AppendAllText($RuntimeLogPath,
                ('{0:o} | fold fallback | {1}{2}' -f (Get-Date), 'UI operation failed', [Environment]::NewLine))
        }
        catch { }
    }
}

function Get-RangeStart {
    param(
        [Parameter(Mandatory = $true)][string]$Range,
        [datetime]$Now = (Get-Date)
    )

    switch ($Range) {
        'day' {
            return $Now.Date
        }
        'week' {
            $daysSinceMonday = (([int]$Now.DayOfWeek + 6) % 7)
            return $Now.Date.AddDays(-$daysSinceMonday)
        }
        'month' {
            return [datetime]::new($Now.Year, $Now.Month, 1)
        }
        default {
            return [datetime]::MinValue
        }
    }
}

function Get-RangeHistory {
    param([string]$Range = $script:SelectedRange)

    $allHistory = @(Get-BalanceHistory)
    if ($Range -eq 'all' -or $allHistory.Count -eq 0) {
        return $allHistory
    }

    $rangeStart = Get-RangeStart -Range $Range
    return @($allHistory | Where-Object { ([datetime]$_.Timestamp) -ge $rangeStart })
}

function Get-ChartHistory {
    param([string]$Range = $script:SelectedRange)

    $cacheKey = $Range + '|' + $script:ChartGranularity
    if ($null -eq $script:ChartHistoryCache) {
        $script:ChartHistoryCache = @{}
    }
    if ($script:ChartHistoryCache.ContainsKey($cacheKey)) { return $script:ChartHistoryCache[$cacheKey] }

    $history = @(Get-RangeHistory -Range $Range)
    if ($history.Count -eq 0) { return @() }

    # Keep one final reading for each selected time bucket. This avoids
    # duplicate manual refreshes while preserving the balance at every minute
    # or hour shown on the chart.
    $buckets = [ordered]@{}
    foreach ($entry in $history) {
        $timestamp = [datetime]$entry.Timestamp
        if ($script:ChartGranularity -eq 'hour') {
            $bucketTime = [datetime]::new($timestamp.Year, $timestamp.Month, $timestamp.Day, $timestamp.Hour, 0, 0)
        }
        else {
            $bucketTime = [datetime]::new($timestamp.Year, $timestamp.Month, $timestamp.Day, $timestamp.Hour, $timestamp.Minute, 0)
        }
        $buckets[$bucketTime.Ticks.ToString()] = [pscustomobject]@{
            Timestamp = $bucketTime
            Balance   = [double]$entry.Balance
        }
    }
    $script:ChartHistoryCache[$cacheKey] = @($buckets.Values)
    return $script:ChartHistoryCache[$cacheKey]
}

function Clear-ChartHistoryCache {
    $script:ChartHistoryCache = @{}
    $script:ChartHistoryCacheKey = $null
}

function Reset-ChartViewport {
    $script:ChartZoom = 1.0
    $script:ChartViewStartRatio = 0.0
}

function Queue-ChartRender {
    if ($null -eq $script:ChartInteractionTimer) {
        Draw-BalanceChart
        return
    }
    if (-not $script:ChartInteractionTimer.IsEnabled) {
        $script:ChartInteractionTimer.Start()
    }
}

function Set-ChartZoom {
    param(
        [Parameter(Mandatory = $true)][double]$Factor,
        [double]$AnchorRatio = 0.5
    )
    $oldZoom = [Math]::Max(1.0, [double]$script:ChartZoom)
    $newZoom = [Math]::Max(1.0, [Math]::Min(180.0, $oldZoom * $Factor))
    if ([Math]::Abs($newZoom - $oldZoom) -lt 0.001) { return }

    $oldVisibleRatio = 1.0 / $oldZoom
    $newVisibleRatio = 1.0 / $newZoom
    $AnchorRatio = [Math]::Max(0.0, [Math]::Min(1.0, $AnchorRatio))
    $anchorOnFullRange = $script:ChartViewStartRatio + ($AnchorRatio * $oldVisibleRatio)
    $maxStart = [Math]::Max(0.0, 1.0 - $newVisibleRatio)
    $newStart = $anchorOnFullRange - ($AnchorRatio * $newVisibleRatio)

    $script:ChartZoom = $newZoom
    $script:ChartViewStartRatio = [Math]::Max(0.0, [Math]::Min($maxStart, $newStart))
    Queue-ChartRender
}

function Get-PeriodCaption {
    param(
        [string]$Range,
        [object[]]$History
    )

    $now = Get-Date
    switch ($Range) {
        'day' {
            return $now.ToString('yyyy-MM-dd')
        }
        'week' {
            return (Get-RangeStart -Range 'week' -Now $now).ToString('MM-dd') + ' - ' + $now.ToString('MM-dd')
        }
        'month' {
            return $now.ToString('yyyy-MM')
        }
        default {
            if ($History.Count -gt 0) {
                return ([datetime]$History[0].Timestamp).ToString('yyyy-MM-dd') + ' - now'
            }
            return 'All history'
        }
    }
}

function Draw-BalanceChart {
    if ($script:IsCollapsed -or $null -ne $script:FoldAnimation -or $script:WidgetGeometryEditing) {
        $script:ChartNeedsRender = $true
        return
    }
    $script:ChartNeedsRender = $false
    $chartCanvas.Children.Clear()
    $width = [double]$chartCanvas.ActualWidth
    $height = [double]$chartCanvas.ActualHeight
    if ($width -lt 20 -or $height -lt 20) { return }

    $allChartHistory = @(Get-ChartHistory -Range $script:SelectedRange)
    $showingFallbackHistory = $false
    if ($allChartHistory.Count -eq 0) {
        $allChartHistory = @(Get-ChartHistory -Range 'all')
        $showingFallbackHistory = $allChartHistory.Count -gt 0
    }

    if ($allChartHistory.Count -eq 0) {
        $chartRangeText.Text = 'Waiting for data'
        $periodText.Text = 'No history available'
        return
    }

    if ($showingFallbackHistory) {
        $lastAvailable = [datetime]$allChartHistory[$allChartHistory.Count - 1].Timestamp
        $periodText.Text = 'No data in this period - showing history through ' + $lastAvailable.ToString('MM-dd HH:mm')
    }
    else {
        $periodText.Text = Get-PeriodCaption -Range $script:SelectedRange -History $allChartHistory
    }

    $fullWindowStart = [datetime]$allChartHistory[0].Timestamp
    $fullWindowEnd = [datetime]$allChartHistory[$allChartHistory.Count - 1].Timestamp
    if (($fullWindowEnd - $fullWindowStart).TotalSeconds -lt 60) {
        $fullWindowStart = $fullWindowEnd.AddMinutes(-1)
    }
    $fullSeconds = ($fullWindowEnd - $fullWindowStart).TotalSeconds
    $zoom = [Math]::Max(1.0, [double]$script:ChartZoom)
    $visibleRatio = 1.0 / $zoom
    $maxViewStart = [Math]::Max(0.0, 1.0 - $visibleRatio)
    $viewStartRatio = [Math]::Max(0.0, [Math]::Min($maxViewStart, [double]$script:ChartViewStartRatio))
    $windowStart = $fullWindowStart.AddSeconds($fullSeconds * $viewStartRatio)
    $windowEnd = $windowStart.AddSeconds($fullSeconds * $visibleRatio)
    $history = @($allChartHistory | Where-Object {
        $timestamp = [datetime]$_.Timestamp
        $timestamp -ge $windowStart -and $timestamp -le $windowEnd
    })
    if ($history.Count -eq 0) {
        $history = @($allChartHistory | Select-Object -Last 1)
    }

    $values = @($history | ForEach-Object { [double]$_.Balance })
    $minimum = [double](($values | Measure-Object -Minimum).Minimum)
    $maximum = [double](($values | Measure-Object -Maximum).Maximum)
    $granularityLabel = if ($script:ChartGranularity -eq 'hour') { 'Hour' } else { 'Minute' }
    $zoomSuffix = if ($zoom -gt 1.01) { ' | {0:N1}x' -f $zoom } else { '' }
    $fallbackSuffix = if ($showingFallbackHistory) { ' | history' } else { '' }
    $chartRangeText.Text = ('{0} pts | {1}{2}{3}' -f $history.Count, $granularityLabel, $zoomSuffix, $fallbackSuffix)

    $displayMinimum = $minimum
    $displayMaximum = $maximum
    if ([Math]::Abs($displayMaximum - $displayMinimum) -lt 0.01) {
        $displayMinimum -= 0.5
        $displayMaximum += 0.5
    }
    else {
        $padding = ($displayMaximum - $displayMinimum) * 0.12
        $displayMinimum -= $padding
        $displayMaximum += $padding
    }

    # Reserve a fixed logical strip for the vertical value scale. The chart
    # canvas itself is responsive, so this keeps the labels visible in both
    # portrait and landscape layouts.
    $uiScale = if ($script:UiScale -gt 0) { [double]$script:UiScale } else { 1.0 }
    $baseLeft = if ($width -ge 220) { 38.0 } else { 32.0 }
    $left = $baseLeft * $uiScale
    $right = 3.0
    $top = 4.0
    $bottom = 17.0 * $uiScale
    $plotWidth = $width - $left - $right
    $plotHeight = $height - $top - $bottom

    foreach ($fraction in @(0.0, 0.5, 1.0)) {
        $gridLine = New-Object Windows.Shapes.Line
        $gridLine.X1 = $left
        $gridLine.X2 = $left + $plotWidth
        $gridLine.Y1 = $top + ($plotHeight * $fraction)
        $gridLine.Y2 = $gridLine.Y1
        $gridLine.Stroke = $brushConverter.ConvertFromString('#26394B63')
        $gridLine.StrokeThickness = 1
        [void]$chartCanvas.Children.Add($gridLine)

        $scaleValue = $displayMaximum - (($displayMaximum - $displayMinimum) * $fraction)
        $scaleLabel = New-Object Windows.Controls.TextBlock
        $scaleLabel.Text = ('{0:N2}' -f $scaleValue)
        $scaleLabel.Width = $left - (7.0 * $uiScale)
        $scaleLabel.TextAlignment = 'Right'
        $scaleLabel.FontSize = 8.0 * $uiScale
        $scaleLabel.Foreground = $brushConverter.ConvertFromString('#6F8098')
        [Windows.Controls.Canvas]::SetLeft($scaleLabel, 0)
        $scaleLabelTop = [Math]::Max(0.0, [Math]::Min($height - (13.0 * $uiScale), $gridLine.Y1 - (6.0 * $uiScale)))
        [Windows.Controls.Canvas]::SetTop($scaleLabel, $scaleLabelTop)
        [void]$chartCanvas.Children.Add($scaleLabel)

        $scaleTick = New-Object Windows.Shapes.Line
        $scaleTick.X1 = $left - 4.0
        $scaleTick.X2 = $left
        $scaleTick.Y1 = $gridLine.Y1
        $scaleTick.Y2 = $gridLine.Y1
        $scaleTick.Stroke = $brushConverter.ConvertFromString('#40566B86')
        $scaleTick.StrokeThickness = 1
        [void]$chartCanvas.Children.Add($scaleTick)
    }

    $verticalAxis = New-Object Windows.Shapes.Line
    $verticalAxis.X1 = $left
    $verticalAxis.X2 = $left
    $verticalAxis.Y1 = $top
    $verticalAxis.Y2 = $top + $plotHeight
    $verticalAxis.Stroke = $brushConverter.ConvertFromString('#30566B86')
    $verticalAxis.StrokeThickness = 1
    [void]$chartCanvas.Children.Add($verticalAxis)

    $totalSeconds = ($windowEnd - $windowStart).TotalSeconds
    $range = $displayMaximum - $displayMinimum
    $displayHistory = $history
    $maxChartPoints = if ($script:ChartInteractionActive) { 650 } else { 1600 }
    if ($history.Count -gt $maxChartPoints) {
        $sampled = New-Object System.Collections.Generic.List[object]
        $stride = [int][Math]::Ceiling($history.Count / [double]$maxChartPoints)
        for ($index = 0; $index -lt $history.Count; $index += $stride) {
            $sampled.Add($history[$index])
        }
        if ($sampled[$sampled.Count - 1].Timestamp -ne $history[$history.Count - 1].Timestamp) {
            $sampled.Add($history[$history.Count - 1])
        }
        # Windows PowerShell 5 can throw "Argument types do not match" when a
        # generic List[object] is wrapped with @(). Convert it explicitly.
        $displayHistory = $sampled.ToArray()
    }

    # Time-axis ticks follow the selected chart granularity. Minute mode uses
    # HH:mm labels; hour mode uses hour labels and adds the date for long spans.
    foreach ($tickFraction in @(0.0, 0.25, 0.5, 0.75, 1.0)) {
        $tickX = $left + ($plotWidth * $tickFraction)
        $tickLine = New-Object Windows.Shapes.Line
        $tickLine.X1 = $tickX
        $tickLine.X2 = $tickX
        $tickLine.Y1 = $top
        $tickLine.Y2 = $top + $plotHeight
        $tickLine.Stroke = $brushConverter.ConvertFromString('#18394B63')
        $tickLine.StrokeThickness = 1
        [void]$chartCanvas.Children.Add($tickLine)

        $tickTime = $windowStart.AddSeconds($totalSeconds * $tickFraction)
        $tickLabel = New-Object Windows.Controls.TextBlock
        if ($script:ChartGranularity -eq 'hour') {
            if (($windowEnd.Date - $windowStart.Date).TotalDays -ge 1) {
                $tickLabel.Text = $tickTime.ToString('MM-dd HH')
            }
            else {
                $tickLabel.Text = $tickTime.ToString('HH') + 'h'
            }
        }
        else {
            $tickLabel.Text = $tickTime.ToString('HH:mm')
        }
        $tickLabel.Width = 54.0 * $uiScale
        $tickLabel.TextAlignment = 'Center'
        $tickLabel.FontSize = 8.0 * $uiScale
        $tickLabel.Foreground = $brushConverter.ConvertFromString('#56667C')
        $labelLeft = [Math]::Max(0.0, [Math]::Min($width - (54.0 * $uiScale), $tickX - (27.0 * $uiScale)))
        [Windows.Controls.Canvas]::SetLeft($tickLabel, $labelLeft)
        [Windows.Controls.Canvas]::SetTop($tickLabel, $height - (13.0 * $uiScale))
        [void]$chartCanvas.Children.Add($tickLabel)
    }

    $points = New-Object Windows.Media.PointCollection

    foreach ($entry in $displayHistory) {
        $xRatio = (($entry.Timestamp - $windowStart).TotalSeconds / $totalSeconds)
        $xRatio = [Math]::Max(0.0, [Math]::Min(1.0, $xRatio))
        $yRatio = (($displayMaximum - [double]$entry.Balance) / $range)
        $x = $left + ($plotWidth * $xRatio)
        $y = $top + ($plotHeight * $yRatio)
        $points.Add([Windows.Point]::new($x, $y))
    }

    if ($points.Count -gt 1) {
        $areaPoints = New-Object Windows.Media.PointCollection
        $areaPoints.Add([Windows.Point]::new($points[0].X, $top + $plotHeight))
        foreach ($point in $points) { $areaPoints.Add($point) }
        $areaPoints.Add([Windows.Point]::new($points[$points.Count - 1].X, $top + $plotHeight))
        $area = New-Object Windows.Shapes.Polygon
        $area.Points = $areaPoints
        $area.Fill = $brushConverter.ConvertFromString('#165EEAD4')
        [void]$chartCanvas.Children.Add($area)

        $glowLine = New-Object Windows.Shapes.Polyline
        $glowLine.Points = $points
        $glowLine.Stroke = $brushConverter.ConvertFromString('#805EEAD4')
        $glowLine.StrokeThickness = 7
        $glowLine.Opacity = 0.18
        $glowLine.StrokeLineJoin = 'Round'
        [void]$chartCanvas.Children.Add($glowLine)

        $line = New-Object Windows.Shapes.Polyline
        $line.Points = $points
        $line.Stroke = $brushConverter.ConvertFromString('#63F5DF')
        $line.StrokeThickness = 2.3
        $line.StrokeLineJoin = 'Round'
        [void]$chartCanvas.Children.Add($line)
    }

    $pointSize = if ($points.Count -le 120) { 5.0 } elseif ($points.Count -le 500) { 3.4 } else { 2.2 }
    foreach ($point in $points) {
        $pointDot = New-Object Windows.Shapes.Ellipse
        $pointDot.Width = $pointSize
        $pointDot.Height = $pointSize
        $pointDot.Fill = $brushConverter.ConvertFromString('#B563F5DF')
        $pointDot.Stroke = $brushConverter.ConvertFromString('#CC0B111D')
        $pointDot.StrokeThickness = 0.5
        [Windows.Controls.Canvas]::SetLeft($pointDot, $point.X - ($pointSize / 2.0))
        [Windows.Controls.Canvas]::SetTop($pointDot, $point.Y - ($pointSize / 2.0))
        [void]$chartCanvas.Children.Add($pointDot)
    }

    $lastPoint = $points[$points.Count - 1]
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 8
    $dot.Height = 8
    $dot.Fill = $brushConverter.ConvertFromString('#D7FFF8')
    $dot.Stroke = $brushConverter.ConvertFromString('#5EEAD4')
    $dot.StrokeThickness = 2
    [Windows.Controls.Canvas]::SetLeft($dot, $lastPoint.X - 4)
    [Windows.Controls.Canvas]::SetTop($dot, $lastPoint.Y - 4)
    [void]$chartCanvas.Children.Add($dot)

}

function Update-BalanceStatistics {
    param([double]$CurrentBalance)

    $history = @(Get-RangeHistory)
    if ($history.Count -eq 0) {
        $consumedText.Text = '--'
        $dailyAverageText.Text = '--'
        $rechargedText.Text = '--'
        $estimatedDaysText.Text = '--'
        $peakPeriodText.Text = '--'
        $peakUsageText.Text = '--'
        $balanceDeltaText.Text = ' --'
        return
    }

    $consumed = 0.0
    $recharged = 0.0
    for ($i = 1; $i -lt $history.Count; $i++) {
        $previous = [double]$history[$i - 1].Balance
        $current = [double]$history[$i].Balance
        $change = $current - $previous
        if ($change -lt -0.0001) {
            $consumed += -$change
        }
        elseif ($change -gt 0.0001) {
            $recharged += $change
        }
    }

    $consumedText.Text = ('{0:N2} kWh' -f $consumed)
    $rechargedText.Text = ('{0:N2} kWh' -f $recharged)

    $periodChange = [double]$history[$history.Count - 1].Balance - [double]$history[0].Balance
    $balanceDeltaText.Text = (' {0:+0.00;-0.00;0.00} kWh' -f $periodChange)
    if ($periodChange -lt -0.0001) {
        $balanceDeltaText.Foreground = $brushConverter.ConvertFromString('#F59E9E')
    }
    elseif ($periodChange -gt 0.0001) {
        $balanceDeltaText.Foreground = $brushConverter.ConvertFromString('#5EEAD4')
    }
    else {
        $balanceDeltaText.Foreground = $brushConverter.ConvertFromString('#8EA0B8')
    }

    $startDate = ([datetime]$history[0].Timestamp).Date
    $endDate = ([datetime]$history[$history.Count - 1].Timestamp).Date
    $calendarDays = [Math]::Max(1, ($endDate - $startDate).Days + 1)
    if ($consumed -gt 0) {
        $dailyAverage = $consumed / $calendarDays
        $dailyAverageText.Text = ('{0:N2} kWh/day' -f $dailyAverage)
        $estimatedDaysText.Text = ('{0:N1} days' -f ($CurrentBalance / $dailyAverage))
    }
    else {
        $dailyAverageText.Text = 'Collecting...'
        $estimatedDaysText.Text = 'Collecting...'
    }

    # Aggregate observed balance drops into clock-hour buckets. Long gaps are
    # excluded because the exact hour of consumption cannot be inferred while
    # the computer was asleep or the recorder was not running.
    $hourlyUsage = @{}
    for ($i = 1; $i -lt $history.Count; $i++) {
        $previousTimestamp = [datetime]$history[$i - 1].Timestamp
        $currentTimestamp = [datetime]$history[$i].Timestamp
        $gapMinutes = ($currentTimestamp - $previousTimestamp).TotalMinutes
        if ($gapMinutes -le 0 -or $gapMinutes -gt 15) { continue }

        $drop = [double]$history[$i - 1].Balance - [double]$history[$i].Balance
        if ($drop -le 0.0001) { continue }

        $hourStart = [datetime]::new(
            $currentTimestamp.Year,
            $currentTimestamp.Month,
            $currentTimestamp.Day,
            $currentTimestamp.Hour,
            0,
            0
        )
        $hourKey = $hourStart.Ticks.ToString()
        if (-not $hourlyUsage.ContainsKey($hourKey)) {
            $hourlyUsage[$hourKey] = [pscustomobject]@{ Start = $hourStart; Usage = 0.0 }
        }
        $hourlyUsage[$hourKey].Usage += $drop
    }

    $peak = $null
    foreach ($bucket in $hourlyUsage.Values) {
        if ($null -eq $peak -or [double]$bucket.Usage -gt [double]$peak.Usage) {
            $peak = $bucket
        }
    }

    if ($null -ne $peak) {
        $peakEnd = $peak.Start.AddHours(1)
        $peakPeriodText.Text = $peak.Start.ToString('MM-dd  HH:mm') + ' - ' + $peakEnd.ToString('HH:mm')
        $peakUsageText.Text = ('{0:N2} kWh' -f [double]$peak.Usage)
    }
    else {
        $peakPeriodText.Text = 'Collecting...'
        $peakUsageText.Text = '--'
    }
}

function Update-RangeView {
    Draw-BalanceChart
    $balance = $script:LastBalance
    if ($null -eq $balance) {
        $allHistory = @(Get-BalanceHistory)
        if ($allHistory.Count -gt 0) {
            $balance = [double]$allHistory[$allHistory.Count - 1].Balance
        }
    }
    if ($null -ne $balance) {
        Update-BalanceStatistics -CurrentBalance $balance
    }
}

function Set-SelectedRange {
    param([Parameter(Mandatory = $true)][string]$Range)

    $script:SelectedRange = $Range
    Clear-ChartHistoryCache
    Reset-ChartViewport
    foreach ($entry in $rangeButtonMap.GetEnumerator()) {
        $entry.Value.Background = $brushConverter.ConvertFromString('#0DFFFFFF')
        $entry.Value.Foreground = $brushConverter.ConvertFromString('#75849A')
    }
    $rangeButtonMap[$Range].Background = $brushConverter.ConvertFromString('#2A5EEAD4')
    $rangeButtonMap[$Range].Foreground = $brushConverter.ConvertFromString('#E7FFFB')
    Update-RangeView
}

function Set-ChartGranularity {
    param([Parameter(Mandatory = $true)][ValidateSet('minute', 'hour')][string]$Granularity)

    $script:ChartGranularity = $Granularity
    Clear-ChartHistoryCache
    Reset-ChartViewport
    foreach ($entry in $scaleButtonMap.GetEnumerator()) {
        $entry.Value.Background = $brushConverter.ConvertFromString('#0DFFFFFF')
        $entry.Value.Foreground = $brushConverter.ConvertFromString('#75849A')
    }
    $scaleButtonMap[$Granularity].Background = $brushConverter.ConvertFromString('#2A5EEAD4')
    $scaleButtonMap[$Granularity].Foreground = $brushConverter.ConvertFromString('#E7FFFB')
    Draw-BalanceChart
}

function Set-SectionPlacement {
    param(
        [Parameter(Mandatory = $true)]$Element,
        [int]$Row,
        [int]$Column,
        [int]$RowSpan = 1,
        [int]$ColumnSpan = 1
    )
    [Windows.Controls.Grid]::SetRow($Element, $Row)
    [Windows.Controls.Grid]::SetColumn($Element, $Column)
    [Windows.Controls.Grid]::SetRowSpan($Element, $RowSpan)
    [Windows.Controls.Grid]::SetColumnSpan($Element, $ColumnSpan)
}

function Initialize-ResponsiveMetrics {
    if ($null -ne $script:ResponsiveMetrics) { return }
    $metrics = New-Object System.Collections.Generic.List[object]
    $queue = New-Object 'System.Collections.Generic.Queue[System.Windows.DependencyObject]'
    # Only keep authored expanded-view elements. Button template children,
    # plotted labels and the fixed-size capsule must not acquire a second scale.
    $queue.Enqueue($layoutGrid)
    while ($queue.Count -gt 0) {
        $element = $queue.Dequeue()
        if ($element -eq $chartCanvas) { continue }
        if ($element -is [Windows.FrameworkElement]) {
            $metrics.Add([pscustomobject]@{
                Element  = $element
                FontSize = if ($element -is [Windows.Controls.TextBlock] -or $element -is [Windows.Controls.Button]) { [double]$element.FontSize } else { [double]::NaN }
                Width    = [double]$element.Width
                Height   = [double]$element.Height
                Margin   = $element.Margin
                Padding  = if ($element -is [Windows.Controls.Border]) { $element.Padding } else { $null }
                Radius   = if ($element -is [Windows.Controls.Border]) { $element.CornerRadius } else { $null }
            })
        }
        if ($element -is [Windows.Controls.Button] -or $element -is [Windows.Controls.TextBlock]) { continue }
        $childCount = [Windows.Media.VisualTreeHelper]::GetChildrenCount($element)
        for ($childIndex = 0; $childIndex -lt $childCount; $childIndex++) {
            $queue.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($element, $childIndex))
        }
    }
    $script:ResponsiveMetrics = $metrics.ToArray()
}

function Update-ResponsiveTypography {
    if ($script:IsCollapsed) { return }
    if ($null -eq $script:ResponsiveMetrics) { return }
    $scale = [double]$script:UiScale
    if ($scale -le 0) { $scale = 1.0 }
    if ([Math]::Abs($scale - [double]$script:AppliedUiScale) -lt 0.002) { return }
    $script:AppliedUiScale = $scale

    foreach ($metric in $script:ResponsiveMetrics) {
        if (-not [double]::IsNaN($metric.FontSize)) {
            $metric.Element.FontSize = [Math]::Max(7.0, $metric.FontSize * $scale)
        }
        if (-not [double]::IsNaN($metric.Width)) { $metric.Element.Width = $metric.Width * $scale }
        if (-not [double]::IsNaN($metric.Height)) { $metric.Element.Height = $metric.Height * $scale }
        $m = $metric.Margin
        $metric.Element.Margin = [Windows.Thickness]::new($m.Left * $scale, $m.Top * $scale, $m.Right * $scale, $m.Bottom * $scale)
        if ($null -ne $metric.Padding) {
            $p = $metric.Padding
            $metric.Element.Padding = [Windows.Thickness]::new($p.Left * $scale, $p.Top * $scale, $p.Right * $scale, $p.Bottom * $scale)
            $r = $metric.Radius
            $metric.Element.CornerRadius = [Windows.CornerRadius]::new($r.TopLeft * $scale, $r.TopRight * $scale, $r.BottomRight * $scale, $r.BottomLeft * $scale)
        }
    }
}

function Set-ResponsiveLayout {
    if ($script:IsCollapsed) { return }
    $width = [Math]::Max(1.0, [double]$window.ActualWidth)
    $height = [Math]::Max(1.0, [double]$window.ActualHeight)
    $isLandscape = $width -ge ($height * 1.12)
    $newMode = if ($isLandscape) { 'landscape' } else { 'portrait' }
    $script:LayoutMode = $newMode
    # The shorter available dimension limits type and controls. Making a
    # window taller must not enlarge its text beyond the available column width.
    $widthScale = if ($isLandscape) { $width / 760.0 } else { $width / 384.0 }
    $heightScale = if ($isLandscape) { $height / 420.0 } else { $height / 612.0 }
    $script:UiScale = [Math]::Max(0.72, [Math]::Min(1.70, [Math]::Min($widthScale, $heightScale)))
    $s = [double]$script:UiScale
    Update-ResponsiveTypography

    $lengthConverter = New-Object Windows.GridLengthConverter
    if ($isLandscape) {
        $layoutViewport.Margin = [Windows.Thickness]::new(18 * $s, 14 * $s, 18 * $s, 14 * $s)
        $layoutLeftColumn.Width = $lengthConverter.ConvertFromString('42*')
        $layoutRightColumn.Width = $lengthConverter.ConvertFromString('58*')

        Set-SectionPlacement -Element $headerSection -Row 0 -Column 0 -ColumnSpan 2
        Set-SectionPlacement -Element $balanceSection -Row 1 -Column 0
        Set-SectionPlacement -Element $rangeSection -Row 2 -Column 0
        Set-SectionPlacement -Element $statsSection -Row 3 -Column 0 -RowSpan 2
        Set-SectionPlacement -Element $chartSection -Row 1 -Column 1 -RowSpan 3
        Set-SectionPlacement -Element $peakSection -Row 4 -Column 1
        Set-SectionPlacement -Element $statusSection -Row 6 -Column 0 -ColumnSpan 2
        $chartSection.Margin = [Windows.Thickness]::new(9 * $s, 4 * $s, 0, 8 * $s)
        $statsSection.Margin = [Windows.Thickness]::new(-4 * $s, 3 * $s, 5 * $s, 2 * $s)
    }
    else {
        $layoutViewport.Margin = [Windows.Thickness]::new(22 * $s, 18 * $s, 22 * $s, 18 * $s)
        $layoutLeftColumn.Width = $lengthConverter.ConvertFromString('*')
        $layoutRightColumn.Width = $lengthConverter.ConvertFromString('0')

        Set-SectionPlacement -Element $headerSection -Row 0 -Column 0
        Set-SectionPlacement -Element $balanceSection -Row 1 -Column 0
        Set-SectionPlacement -Element $rangeSection -Row 2 -Column 0
        Set-SectionPlacement -Element $chartSection -Row 3 -Column 0
        Set-SectionPlacement -Element $statsSection -Row 4 -Column 0
        Set-SectionPlacement -Element $peakSection -Row 5 -Column 0
        Set-SectionPlacement -Element $statusSection -Row 6 -Column 0
        $chartSection.Margin = [Windows.Thickness]::new(0, 4 * $s, 0, 10 * $s)
        $statsSection.Margin = [Windows.Thickness]::new(-4 * $s, -1 * $s, -4 * $s, 5 * $s)
    }

    $contentWidth = $width - 2 - $layoutViewport.Margin.Left - $layoutViewport.Margin.Right
    $actionsWidth = 162.0
    $stackHeader = $contentWidth -lt ((148.0 + $actionsWidth + 12.0) * $s)
    $headerHeight = if ($stackHeader) { 74.0 * $s } else { 42.0 * $s }
    Set-SectionPlacement -Element $headerTitleBox -Row 0 -Column 0 -ColumnSpan $(if ($stackHeader) { 2 } else { 1 })
    Set-SectionPlacement -Element $headerActions -Row $(if ($stackHeader) { 1 } else { 0 }) -Column $(if ($stackHeader) { 0 } else { 1 }) -ColumnSpan $(if ($stackHeader) { 2 } else { 1 })
    $headerSection.RowDefinitions[0].Height = [Windows.GridLength]::new($(if ($stackHeader) { 36 * $s } else { $headerHeight }))
    $headerSection.RowDefinitions[1].Height = [Windows.GridLength]::new($(if ($stackHeader) { 38 * $s } else { 0 }))

    $chartWidth = if ($isLandscape) { $contentWidth * 0.58 - 9 * $s } else { $contentWidth }
    $stackChart = ($chartWidth - 28 * $s) -lt (278 * $s)
    Set-SectionPlacement -Element $chartHeading -Row 0 -Column 0 -ColumnSpan $(if ($stackChart) { 2 } else { 1 })
    Set-SectionPlacement -Element $chartActions -Row $(if ($stackChart) { 1 } else { 0 }) -Column $(if ($stackChart) { 0 } else { 1 }) -ColumnSpan $(if ($stackChart) { 2 } else { 1 })
    $chartActions.Margin = [Windows.Thickness]::new(0, $(if ($stackChart) { 5 * $s } else { 0 }), 0, 0)
    $chartCanvas.MinHeight = 52 * $s

    $minimumChart = $(if ($stackChart) { 154.0 } else { 126.0 }) * $s
    if ($isLandscape) {
        $rowHeights = @($headerHeight, (92 * $s), (52 * $s), -1, (54 * $s), 0, (48 * $s))
        $minimumHeight = $headerHeight + (332 * $s)
    }
    else {
        $rowHeights = @($headerHeight, (92 * $s), (52 * $s), -1, (116 * $s), (54 * $s), (48 * $s))
        $minimumHeight = $headerHeight + (362 * $s) + $minimumChart
    }
    $availableHeight = $height - 2 - $layoutViewport.Margin.Top - $layoutViewport.Margin.Bottom
    $layoutGrid.Height = [Math]::Max($minimumHeight, $availableHeight)
    for ($index = 0; $index -lt $rowHeights.Count; $index++) {
        $layoutGrid.RowDefinitions[$index].Height = if ($rowHeights[$index] -lt 0) {
            [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        } else {
            [Windows.GridLength]::new([double]$rowHeights[$index])
        }
    }
}

function Update-BalanceDisplay {
    if ($null -ne $script:FoldAnimation -or $script:WidgetGeometryEditing) {
        $script:PendingBalanceRefresh=$true
        return
    }
    $script:PendingBalanceRefresh=$false
    $statusText.Text='Refreshing...'
    $compactStatusDot.Fill=$brushConverter.ConvertFromString('#FBBF24')
    try {
        $result=Get-DormBalance
        $value=[double]$result.Balance
        $script:LastBalance=$value
        Invoke-LowBalanceReminder -Balance $value
        $historySaved=$true
        try { Add-BalanceHistory -Balance $value -Timestamp $result.Updated }
        catch { $historySaved=$false }
        Clear-ChartHistoryCache
        $balanceText.Text=('{0:N2}' -f $value)
        $color=if($value-lt 10){'#FB7185'}elseif($value-lt 20){'#FBBF24'}else{'#5EEAD4'}
        $balanceText.Foreground=$brushConverter.ConvertFromString($color)
        Update-CompactBalance
        $compactStatusDot.Fill=$brushConverter.ConvertFromString('#5EEAD4')
        $statusText.Foreground=$brushConverter.ConvertFromString('#94A3B8')
        $statusText.Text=$(if($Demo){'DEMO - fictional data | '}else{''})+'Updated '+$result.Updated.ToString('HH:mm:ss')
        if(-not $historySaved){$statusText.Text+=' | History save unavailable'}
        Set-ResponsiveLayout
        if(-not $script:IsCollapsed){Draw-BalanceChart}else{$script:ChartNeedsRender=$true}
        Update-BalanceStatistics -CurrentBalance $value
    }
    catch {
        $latest=@(Get-BalanceHistory | Select-Object -Last 1)
        $script:LastBalance=if($latest.Count){[double]$latest[0].Balance}else{$null}
        $balanceText.Text=if($null-ne $script:LastBalance){'{0:N2}' -f $script:LastBalance}else{'--'}
        $balanceText.Foreground=$brushConverter.ConvertFromString('#FBBF24')
        Update-CompactBalance
        $compactStatusDot.Fill=$brushConverter.ConvertFromString('#FB7185')
        $statusText.Foreground=$brushConverter.ConvertFromString('#FB7185')
        $statusText.Text='Query unavailable. Check Settings and your current authorization.'
        if(-not $script:IsCollapsed){Draw-BalanceChart}else{$script:ChartNeedsRender=$true}
    }
}

$postFoldChartTimer = New-Object Windows.Threading.DispatcherTimer
$postFoldChartTimer.Interval = [TimeSpan]::FromMilliseconds(260)
$postFoldChartTimer.Add_Tick({
    $postFoldChartTimer.Stop()
    if ($script:IsCollapsed -or $null -ne $script:FoldAnimation -or $script:WidgetGeometryEditing) { return }
    if (-not $script:ChartNeedsRender) { return }
    Draw-BalanceChart
    $script:ChartNeedsRender = $false
})

$deferredBalanceTimer = New-Object Windows.Threading.DispatcherTimer
$deferredBalanceTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$deferredBalanceTimer.Add_Tick({
    if ($null -ne $script:FoldAnimation -or $script:WidgetGeometryEditing) { return }
    $deferredBalanceTimer.Stop()
    if ($script:PendingBalanceRefresh) { Update-BalanceDisplay }
})

$foldMotion = New-Object CachedFoldMotion($window, $glassSurface, $layoutViewport, $compactSection)
$foldMotion.Add_Completed({
    $expanded = [bool]$script:FoldAnimation.Expand
    if ($foldMotion.LastError) {
        $window.Width = $script:FoldAnimation.Width
        $window.Height = $script:FoldAnimation.Height
        $window.Left = $script:FoldAnimation.Left
        $window.Top = $script:FoldAnimation.Top
    }
    Complete-FoldTransition -Expanded $expanded
    try {
        $message = '{0:o} | fold expand={1}, frames={2}, motionMs={3:N1}, maxGapMs={4:N1}, prepareMs={5:N1}, restoreMs={6:N1}{7}' -f (Get-Date), $expanded, $foldMotion.LastFrameCount, $foldMotion.LastDurationMilliseconds, $foldMotion.LastMaxFrameMilliseconds, $foldMotion.LastPreparationMilliseconds, $foldMotion.LastRestoreMilliseconds, [Environment]::NewLine
        [IO.File]::AppendAllText($RuntimeLogPath, $message)
    }
    catch { }
})

$glassMotionTimer = New-Object Windows.Threading.DispatcherTimer
$glassMotionTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$glassMotionTimer.Add_Tick({
    if ($script:WidgetGeometryEditing) { $glassMotionTimer.Stop(); return }
    $script:GlassCurrentX += ($script:GlassTargetX - $script:GlassCurrentX) * 0.16
    $script:GlassCurrentY += ($script:GlassTargetY - $script:GlassCurrentY) * 0.16
    $glassGlowBrush.Center = [Windows.Point]::new($script:GlassCurrentX, $script:GlassCurrentY)
    $glassGlowBrush.GradientOrigin = [Windows.Point]::new($script:GlassCurrentX, $script:GlassCurrentY)
    $glassSheenBrush.StartPoint = [Windows.Point]::new($script:GlassCurrentX - 0.50, $script:GlassCurrentY - 0.34)
    $glassSheenBrush.EndPoint = [Windows.Point]::new($script:GlassCurrentX + 0.54, $script:GlassCurrentY + 0.48)
    $targetOpacity = if ($script:GlassPointerInside) { 0.70 } else { 0.46 }
    $glassGlowLayer.Opacity += ($targetOpacity - $glassGlowLayer.Opacity) * 0.14
    $glassSheenLayer.Opacity += (($targetOpacity * 0.68) - $glassSheenLayer.Opacity) * 0.14
    if (-not $script:GlassPointerInside) {
        $script:GlassIdleTicks++
        if ($script:GlassIdleTicks -gt 80 -and
            [Math]::Abs($script:GlassCurrentX - $script:GlassTargetX) -lt 0.002 -and
            [Math]::Abs($script:GlassCurrentY - $script:GlassTargetY) -lt 0.002) {
            $glassMotionTimer.Stop()
        }
    }
})

$window.Add_MouseMove({
    param($sender, $eventArgs)
    if ($script:WidgetGeometryEditing) { return }
    if ($window.ActualWidth -le 0 -or $window.ActualHeight -le 0) { return }
    $point = $eventArgs.GetPosition($window)
    $script:GlassTargetX = [Math]::Max(0.0, [Math]::Min(1.0, $point.X / $window.ActualWidth))
    $script:GlassTargetY = [Math]::Max(0.0, [Math]::Min(1.0, $point.Y / $window.ActualHeight))
    $script:GlassPointerInside = $true
    $script:GlassIdleTicks = 0
    if ($null -eq $script:FoldAnimation -and -not $script:WidgetGeometryEditing -and -not $glassMotionTimer.IsEnabled) { $glassMotionTimer.Start() }
})
$window.Add_MouseLeave({
    $script:GlassPointerInside = $false
    $script:GlassTargetX = 0.18
    $script:GlassTargetY = 0.10
    $script:GlassIdleTicks = 0
    if ($null -eq $script:FoldAnimation -and -not $script:WidgetGeometryEditing -and -not $glassMotionTimer.IsEnabled) { $glassMotionTimer.Start() }
})

$refreshButton.Add_Click({ Update-BalanceDisplay })
$collapseButton.Add_Click({ Start-FoldTransition -Expand $false })
$expandButton.Add_Click({ Start-FoldTransition -Expand $true })
$closeButton.Add_Click({
    if ($Demo) { $window.Close(); return }
    try {
        if (-not (Test-Path -LiteralPath $HistoryDirectory)) {
            [void](New-Item -ItemType Directory -Path $HistoryDirectory -Force)
        }
        [IO.File]::WriteAllText($IntentionalExitPath, (Get-Date).ToString('o'))
    }
    catch { }
    $window.Close()
})
$authButton.Add_Click({
    if (Show-QuerySettings) {
        Set-PublicLabels
        Clear-ChartHistoryCache
        Reset-ChartViewport
        Update-BalanceDisplay
    }
})

$dayRangeButton.Add_Click({ Set-SelectedRange -Range 'day' })
$weekRangeButton.Add_Click({ Set-SelectedRange -Range 'week' })
$monthRangeButton.Add_Click({ Set-SelectedRange -Range 'month' })
$allRangeButton.Add_Click({ Set-SelectedRange -Range 'all' })
$minuteScaleButton.Add_Click({ Set-ChartGranularity -Granularity 'minute' })
$hourScaleButton.Add_Click({ Set-ChartGranularity -Granularity 'hour' })
$chartZoomOutButton.Add_Click({ Set-ChartZoom -Factor (1.0 / 1.35) })
$chartZoomInButton.Add_Click({ Set-ChartZoom -Factor 1.35 })
$chartResetButton.Add_Click({
    Reset-ChartViewport
    Draw-BalanceChart
})
$chartCanvas.Add_MouseWheel({
    param($sender, $eventArgs)
    $pointer = $eventArgs.GetPosition($chartCanvas)
    $uiScale = if ($script:UiScale -gt 0) { [double]$script:UiScale } else { 1.0 }
    $baseLeft = if ($chartCanvas.ActualWidth -ge 220) { 38.0 } else { 32.0 }
    $plotLeft = $baseLeft * $uiScale
    $plotWidth = [Math]::Max(1.0, $chartCanvas.ActualWidth - $plotLeft - 3.0)
    $anchor = [Math]::Max(0.0, [Math]::Min(1.0, ($pointer.X - $plotLeft) / $plotWidth))
    $factor = if ($eventArgs.Delta -gt 0) { 1.28 } else { 1.0 / 1.28 }
    Set-ChartZoom -Factor $factor -AnchorRatio $anchor
    $eventArgs.Handled = $true
})
$chartCanvas.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ClickCount -ge 2) {
        Reset-ChartViewport
        Draw-BalanceChart
        $eventArgs.Handled = $true
        return
    }
    $pointer = $eventArgs.GetPosition($chartCanvas)
    $script:ChartPanStartX = [double]$pointer.X
    $script:ChartPanStartRatio = [double]$script:ChartViewStartRatio
    $script:ChartInteractionActive = $true
    [void]$chartCanvas.CaptureMouse()
    $chartCanvas.Cursor = [Windows.Input.Cursors]::SizeAll
    $eventArgs.Handled = $true
})
$chartCanvas.Add_MouseMove({
    param($sender, $eventArgs)
    if (-not $chartCanvas.IsMouseCaptured) { return }
    $pointer = $eventArgs.GetPosition($chartCanvas)
    $uiScale = if ($script:UiScale -gt 0) { [double]$script:UiScale } else { 1.0 }
    $baseLeft = if ($chartCanvas.ActualWidth -ge 220) { 38.0 } else { 32.0 }
    $plotWidth = [Math]::Max(1.0, $chartCanvas.ActualWidth - ($baseLeft * $uiScale) - 3.0)
    $visibleRatio = 1.0 / [Math]::Max(1.0, [double]$script:ChartZoom)
    $maxStart = [Math]::Max(0.0, 1.0 - $visibleRatio)
    $dragRatio = -(([double]$pointer.X - $script:ChartPanStartX) / $plotWidth) * $visibleRatio
    $script:ChartViewStartRatio = [Math]::Max(0.0, [Math]::Min($maxStart, $script:ChartPanStartRatio + $dragRatio))
    Queue-ChartRender
    $eventArgs.Handled = $true
})
$chartCanvas.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    if ($chartCanvas.IsMouseCaptured) { $chartCanvas.ReleaseMouseCapture() }
    $script:ChartInteractionActive = $false
    $chartCanvas.Cursor = [Windows.Input.Cursors]::Hand
    Queue-ChartRender
    $eventArgs.Handled = $true
})
$script:WidgetGeometryEditing = $false
$script:WidgetGeometryResize = $false
$script:GeometryFinalizing = $false
$script:GeometryGlassWasRunning = $false
$script:GeometryLayoutDirty = $false
$script:NativeGeometryResize = $false
$script:NativeGeometryActive = $false
$script:WidgetVisibilityHoldUntil = [DateTime]::MinValue
$script:WidgetVisibilityCandidate = $null
$script:WidgetVisibilityCandidateSince = [DateTime]::MinValue



$resizePreview = New-Object CachedResizePreview($window, $glassSurface)
$resizeDriver = New-Object WidgetResizeDriver

function Begin-WidgetGeometryEditing {
    param([switch]$Resizing)
    if ($null -ne $script:FoldAnimation) { return }
    if (-not $script:WidgetGeometryEditing) {
        $script:WidgetGeometryEditing = $true
        $script:WidgetVisibilityCandidate = $null
        $script:GeometryGlassWasRunning = $glassMotionTimer.IsEnabled
        $glassMotionTimer.Stop()
        $resizeRedrawTimer.Stop()
        if ($script:ChartInteractionTimer.IsEnabled) { $script:ChartNeedsRender = $true }
        $script:ChartInteractionTimer.Stop()
        $postFoldChartTimer.Stop()
    }
    if ($Resizing -and -not $script:WidgetGeometryResize) {
        $script:WidgetGeometryResize = $true
        $script:GeometryLayoutDirty = $true
        try { $resizePreview.Begin() }
        catch {
            $resizePreview.End()
            try { [IO.File]::AppendAllText($RuntimeLogPath, ('{0:o} | resize preview fallback | {1}{2}' -f (Get-Date), 'UI operation failed', [Environment]::NewLine)) } catch { }
        }
    }
}

function Complete-WidgetGeometryEditing {
    if ($script:GeometryFinalizing) { return }
    $script:GeometryFinalizing = $true
    $resized = $script:WidgetGeometryResize -or $script:GeometryLayoutDirty
    try {
        if ($resized) {
            Constrain-WidgetToWorkArea
            Set-ResponsiveLayout
            $resizePreview.End()
            $window.UpdateLayout()
            $script:ChartNeedsRender = $true
        }
    }
    finally {
        $resizePreview.End()
        $script:WidgetGeometryEditing = $false
        $script:WidgetGeometryResize = $false
        $script:GeometryLayoutDirty = $false
        $script:GeometryFinalizing = $false
        $script:WidgetVisibilityHoldUntil = [DateTime]::UtcNow.AddMilliseconds(400)
        $script:WidgetVisibilityCandidate = $null
        if ($script:ChartNeedsRender -and -not $script:IsCollapsed) {
            $resizeRedrawTimer.Stop()
            $resizeRedrawTimer.Start()
        }
        if ($script:PendingBalanceRefresh) { $deferredBalanceTimer.Start() }
        if ($script:GeometryGlassWasRunning -or $script:GlassPointerInside) {
            $script:GlassIdleTicks = 0
            $glassMotionTimer.Start()
        }
        $script:GeometryGlassWasRunning = $false
    }
}

function Get-WidgetVisibilityTransition {
    param(
        [ValidateSet('widget','companion','desktop','application','transient')][string]$Reason,
        [DateTime]$Now = [DateTime]::UtcNow
    )
    if ($script:WidgetGeometryEditing -or $Now -lt $script:WidgetVisibilityHoldUntil -or $Reason -eq 'transient') {
        # An unknown foreground does not prove that another app is active.
        # Keep the current state; resume only after a stable known decision.
        $script:WidgetVisibilityCandidate = $null
        return $null
    }
    $target = $Reason -eq 'widget' -or $Reason -eq 'companion' -or $Reason -eq 'desktop'
    if ($target -eq $script:WidgetShown) {
        $script:WidgetVisibilityCandidate = $null
        return $null
    }
    if ($script:WidgetVisibilityCandidate -isnot [bool] -or $script:WidgetVisibilityCandidate -ne $target) {
        $script:WidgetVisibilityCandidate = $target
        $script:WidgetVisibilityCandidateSince = $Now
        return $null
    }
    if (($Now - $script:WidgetVisibilityCandidateSince).TotalMilliseconds -lt 300) { return $null }
    $script:WidgetVisibilityCandidate = $null
    return $target
}

$script:ManualWidgetResize = $null

function Stop-ManualWidgetResize {
    $resizeDriver.Stop()
}

$resizeDriver.Add_Completed({
    $script:ManualWidgetResize = $null
    Complete-WidgetGeometryEditing
})

$window.Add_PreviewMouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($null -ne $script:FoldAnimation -or $script:IsCollapsed) { return }
    $edge = ''
    # Corners are last in the existing list; test them before overlapping edges.
    for ($index = $resizeThumbs.Count - 1; $index -ge 0; $index--) {
        $thumb = $resizeThumbs[$index]
        if (-not $thumb.IsVisible -or -not $thumb.IsEnabled -or $thumb.ActualWidth -le 0 -or $thumb.ActualHeight -le 0) { continue }
        $point = $eventArgs.GetPosition($thumb)
        if ($point.X -ge 0 -and $point.Y -ge 0 -and
            $point.X -lt $thumb.ActualWidth -and $point.Y -lt $thumb.ActualHeight) { $edge = [string]$thumb.Tag; break }
    }
    if (-not $edge) { return }
    Begin-WidgetGeometryEditing -Resizing
    $script:ManualWidgetResize = [pscustomobject]@{ Edge = $edge }
    $eventArgs.Handled = $true
    try {
        if (-not $resizeDriver.Start($window, $edge)) {
            $script:ManualWidgetResize = $null
            Complete-WidgetGeometryEditing
        }
    }
    catch {
        $script:ManualWidgetResize = $null
        Complete-WidgetGeometryEditing
        throw
    }
})
$window.Add_PreviewMouseLeftButtonUp({
    param($sender, $eventArgs)
    if ($null -ne $script:ManualWidgetResize) { $eventArgs.Handled = $true; Stop-ManualWidgetResize }
})
$window.Add_LostMouseCapture({
    if ($null -ne $script:ManualWidgetResize -and [DesktopWidgetNative]::GetCapture() -ne $script:WidgetHandle) { Stop-ManualWidgetResize }
})

$resizeDragHandler = [System.Windows.Controls.Primitives.DragDeltaEventHandler]{
    param($sender, $eventArgs)
    $edge = [string]$sender.Tag
    $horizontalChange = [double]$eventArgs.HorizontalChange
    $verticalChange = [double]$eventArgs.VerticalChange

    $left = $window.Left; $top = $window.Top
    $width = $window.Width; $height = $window.Height
    if ($edge -match 'left') {
        $width = [Math]::Max($window.MinWidth, $window.Width - $horizontalChange)
        $left += $window.Width - $width
    }
    elseif ($edge -match 'right') { $width = [Math]::Max($window.MinWidth, $window.Width + $horizontalChange) }
    if ($edge -match 'top') {
        $height = [Math]::Max($window.MinHeight, $window.Height - $verticalChange)
        $top += $window.Height - $height
    }
    elseif ($edge -match 'bottom') { $height = [Math]::Max($window.MinHeight, $window.Height + $verticalChange) }
    $source = [Windows.Interop.HwndSource]::FromHwnd($script:WidgetHandle)
    $transform = $source.CompositionTarget.TransformToDevice
    [void][DesktopWidgetNative]::SetWindowBounds($script:WidgetHandle,
        [int][Math]::Round($left * $transform.M11), [int][Math]::Round($top * $transform.M22),
        [int][Math]::Round($width * $transform.M11), [int][Math]::Round($height * $transform.M22))
}
$resizeGripDirections = @{
    'left' = 'Left'; 'right' = 'Right'; 'top' = 'Top'; 'bottom' = 'Bottom'
    'top-left' = 'TopLeft'; 'top-right' = 'TopRight'
    'bottom-left' = 'BottomLeft'; 'bottom-right' = 'BottomRight'
}
foreach ($resizeThumb in $resizeThumbs) {
    [Windows.Shell.WindowChrome]::SetResizeGripDirection($resizeThumb, [Windows.Shell.ResizeGripDirection]::None)
    [Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($resizeThumb, $true)
    $resizeThumb.Add_DragStarted({ Begin-WidgetGeometryEditing -Resizing })
    $resizeThumb.Add_DragDelta($resizeDragHandler)
    $resizeThumb.Add_DragCompleted({ Complete-WidgetGeometryEditing })
}

function Test-WidgetDragMoveBlocked {
    param($Source)
    $current = $Source
    for ($depth = 0; $null -ne $current -and $depth -lt 64; $depth++) {
        if ($current -is [Windows.Controls.Primitives.Thumb] -or
            $current -is [Windows.Controls.Primitives.ButtonBase] -or
            $current -is [Windows.Controls.Primitives.TextBoxBase] -or
            $current -is [Windows.Controls.Primitives.Selector] -or
            $current -eq $chartCanvas) { return $true }
        if ($current -isnot [Windows.DependencyObject]) { break }
        $parent = $null
        if ($current -is [Windows.Media.Visual] -or $current -is [Windows.Media.Media3D.Visual3D]) {
            $parent = [Windows.Media.VisualTreeHelper]::GetParent($current)
        }
        if ($null -eq $parent) { $parent = [Windows.LogicalTreeHelper]::GetParent($current) }
        if ($null -eq $parent -and $current -is [Windows.FrameworkElement]) { $parent = $current.TemplatedParent }
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $false
}

$window.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($null -ne $script:FoldAnimation -or $eventArgs.Handled -or (Test-WidgetDragMoveBlocked -Source $eventArgs.OriginalSource)) { return }
    # A template child can be the source. Keep the entire resize target out
    # of the generic window move loop, even if its routed source changes.
    foreach ($resizeThumb in $resizeThumbs) {
        if (-not $resizeThumb.IsVisible -or -not $resizeThumb.IsEnabled) { continue }
        $point = $eventArgs.GetPosition($resizeThumb)
        if ($point.X -ge 0 -and $point.Y -ge 0 -and
            $point.X -lt $resizeThumb.ActualWidth -and $point.Y -lt $resizeThumb.ActualHeight) { return }
    }
    Begin-WidgetGeometryEditing
    try { $sender.DragMove() } catch { }
    finally { Complete-WidgetGeometryEditing }
    Constrain-WidgetToWorkArea
})
$script:WidgetHandle = [IntPtr]::Zero
$window.Add_SourceInitialized({
    $script:WidgetHandle = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
    $script:WidgetGeometrySource = [Windows.Interop.HwndSource]::FromHwnd($script:WidgetHandle)
    $script:WidgetGeometryHook = [Windows.Interop.HwndSourceHook]{
        param([IntPtr]$handle, [int]$message, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
        if ($message -eq 0x0112) { $script:NativeGeometryResize = ($wParam.ToInt64() -band 0xFFF0) -eq 0xF000 }
        elseif ($message -eq 0x0231) {
            $script:NativeGeometryActive = $true
            Begin-WidgetGeometryEditing -Resizing:$script:NativeGeometryResize
        }
        elseif ($message -eq 0x0232) {
            $script:NativeGeometryActive = $false
            Complete-WidgetGeometryEditing
            $script:NativeGeometryResize = $false
        }
        elseif ($message -eq 0x001F -and $null -eq $script:FoldAnimation) {
            if ($resizeDriver.IsActive) { $resizeDriver.Cancel() }
            elseif ($script:WidgetGeometryEditing) {
                $script:NativeGeometryActive = $false
                Complete-WidgetGeometryEditing
            }
        }
        elseif ($message -eq 0x0215 -and $null -eq $script:FoldAnimation -and [DesktopWidgetNative]::GetCapture() -ne $script:WidgetHandle) {
            if ($resizeDriver.IsActive) { $resizeDriver.Stop() }
            elseif ($script:WidgetGeometryEditing -and ([DesktopWidgetNative]::GetAsyncKeyState(1) -band 0x8000) -eq 0) {
                $script:NativeGeometryActive = $false
                Complete-WidgetGeometryEditing
            }
        }
        return [IntPtr]::Zero
    }
    $script:WidgetGeometrySource.AddHook($script:WidgetGeometryHook)
    try {
        $detached = [DesktopWidgetNative]::DetachFromDesktop($script:WidgetHandle)
        $message = '{0:o} | overlay handle=0x{1:X}, detached={2}{3}' -f (Get-Date), $script:WidgetHandle.ToInt64(), $detached, [Environment]::NewLine
        [IO.File]::AppendAllText($RuntimeLogPath, $message)
    }
    catch {
        try { [IO.File]::AppendAllText($RuntimeLogPath, ('{0:o} | overlay error | {1}{2}' -f (Get-Date), 'UI error', [Environment]::NewLine)) } catch { }
    }
})

$workArea = [System.Windows.SystemParameters]::WorkArea
$window.Left = $workArea.Right - $window.Width - 24
$window.Top = $workArea.Top + 24
Constrain-WidgetToWorkArea

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMinutes(1)
$timer.Add_Tick({ Update-BalanceDisplay })
$timer.Start()

# Dynamic wallpaper engines repaint the desktop icon surface.  Keep the widget
# as an independent overlay: show it only while the desktop is foreground and
# hide it completely whenever any application is active.
$visibilityTimer = New-Object Windows.Threading.DispatcherTimer
$visibilityTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$visibilityTimer.Add_Tick({
    try {
        if ($script:WidgetGeometryEditing) {
            # Recover an orphaned preview if a shell/capture transition omitted
            # the end message. Let an active driver commit its final sample.
            if ($null -eq $script:FoldAnimation -and ([DesktopWidgetNative]::GetAsyncKeyState(1) -band 0x8000) -eq 0) {
                if ($resizeDriver.IsActive) { $resizeDriver.Stop() }
                elseif (-not $script:NativeGeometryActive -and ($resizePreview.IsActive -or $script:WidgetGeometryResize)) {
                    Complete-WidgetGeometryEditing
                }
            }
            return
        }
        $reason = [DesktopWidgetNative]::VisibilityReason($script:WidgetHandle)
        $transition = Get-WidgetVisibilityTransition -Reason $reason
        if ($null -eq $transition) { return }
        if ($transition -and -not $script:WidgetShown) {
            [DesktopWidgetNative]::PrepareVisible($script:WidgetHandle)
            $script:WidgetShown = $true
        }
        elseif (-not $transition -and $script:WidgetShown) {
            [DesktopWidgetNative]::PrepareHidden($script:WidgetHandle)
            $script:WidgetShown = $false
        }
    }
    catch { }
})
$script:WidgetShown = $false
$visibilityTimer.Start()

$resizeRedrawTimer = New-Object Windows.Threading.DispatcherTimer
$resizeRedrawTimer.Interval = [TimeSpan]::FromMilliseconds(140)
$resizeRedrawTimer.Add_Tick({
    $resizeRedrawTimer.Stop()
    if ($script:WidgetGeometryEditing -or $null -ne $script:FoldAnimation) {
        $script:ChartNeedsRender = $true
        return
    }
    if ($script:GeometryLayoutDirty) {
        Set-ResponsiveLayout
        $script:GeometryLayoutDirty = $false
    }
    if (-not $script:IsCollapsed -and $script:ChartNeedsRender) { Draw-BalanceChart }
})
$script:ChartInteractionTimer = New-Object Windows.Threading.DispatcherTimer
$script:ChartInteractionTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$script:ChartInteractionTimer.Add_Tick({
    $script:ChartInteractionTimer.Stop()
    if ($script:IsCollapsed -or $null -ne $script:FoldAnimation -or $script:WidgetGeometryEditing) {
        $script:ChartNeedsRender = $true
        return
    }
    Draw-BalanceChart
})
$window.Add_SizeChanged({
    if ($null -ne $script:FoldAnimation) { return }
    if ($script:WidgetGeometryEditing -or $script:GeometryFinalizing) {
        $script:GeometryLayoutDirty = $true
        return
    }
    if ([DateTime]::UtcNow -lt $script:FoldLayoutHoldUntil -and
        [Math]::Abs($window.ActualWidth - $script:FoldLayoutWidth) -lt 0.5 -and
        [Math]::Abs($window.ActualHeight - $script:FoldLayoutHeight) -lt 0.5) { return }
    if ($null -eq $script:ManualWidgetResize) { Constrain-WidgetToWorkArea }
    # Coalesce rapid external/programmatic size changes too. The retained
    # bitmap path covers mouse resizing; this debounce covers other callers.
    $script:GeometryLayoutDirty = $true
    $script:ChartNeedsRender = $true
    $resizeRedrawTimer.Stop()
    $resizeRedrawTimer.Start()
})

$window.Add_Loaded({
    Set-PublicLabels
    if (-not $Demo -and -not $script:PublicConfigured) { [void](Show-QuerySettings); Set-PublicLabels }
    if (-not $Demo) { try { Initialize-ReminderIcon } catch { } }
    Update-ReminderSummary
    Initialize-ResponsiveMetrics
    Set-ResponsiveLayout
    Update-ResponsiveTypography
    Set-SelectedRange -Range 'all'
    Set-ChartGranularity -Granularity 'minute'
    Update-BalanceDisplay
    $glassMotionTimer.Start()
})
$window.Add_Closed({
    Close-ReminderIcon
    [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})
$unhandledExceptionHandler = [Windows.Threading.DispatcherUnhandledExceptionEventHandler]{
    param($sender, $eventArgs)
    try {
        $message = '{0:o} | UI dispatch error{1}' -f (Get-Date), [Environment]::NewLine
        [IO.File]::AppendAllText($RuntimeLogPath, $message)
    }
    catch { }
    # A rendering or shell-state edge case must not stop history recording.
    $eventArgs.Handled = $true
}
[Windows.Threading.Dispatcher]::CurrentDispatcher.Add_UnhandledException($unhandledExceptionHandler)
try {
    $window.Show()
    [Windows.Threading.Dispatcher]::Run()
}
finally {
    Close-ReminderIcon
    $timer.Stop()
    $visibilityTimer.Stop()
    $resizeDriver.Dispose()
    $resizePreview.Dispose()
    $resizeRedrawTimer.Stop()
    $script:ChartInteractionTimer.Stop()
    $foldMotion.Dispose()
    $deferredBalanceTimer.Stop()
    $glassMotionTimer.Stop()
    $postFoldChartTimer.Stop()
    try { $appMutex.ReleaseMutex() } catch { }
    $appMutex.Dispose()
}
