# Local-only reminders. Never load credentials or send data to a push service.
function Get-DefaultReminderSettings {
    return [pscustomobject]@{enabled=$true;threshold=10.0;repeatMinutes=60}
}

function Test-ReminderSettings {
    param([Parameter(Mandatory=$true)]$Settings)
    if($Settings.enabled -isnot [bool]){throw 'Reminder enabled must be true or false.'}
    $threshold=0.0
    if([string]::IsNullOrWhiteSpace([string]$Settings.threshold) -or
        -not [double]::TryParse([string]$Settings.threshold,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$threshold) -or
        [double]::IsNaN($threshold) -or [double]::IsInfinity($threshold) -or $threshold-lt 0 -or $threshold-gt 10000){
        throw 'Threshold must be a finite number from 0 to 10000 kWh.'
    }
    $minutes=0
    if(-not [int]::TryParse([string]$Settings.repeatMinutes,[ref]$minutes) -or $minutes-lt 1 -or $minutes-gt 1440){
        throw 'Repeat interval must be an integer from 1 to 1440 minutes.'
    }
}

function New-ReminderState {
    param([double]$Threshold)
    return [pscustomobject]@{version=1;threshold=$Threshold;active=$false;lastNotifiedUtc=$null}
}

function Initialize-ReminderSettings {
    $script:ReminderSettings=Get-DefaultReminderSettings
    $script:ReminderSettingsPath=Join-Path $script:PublicDataRoot 'reminders.json'
    $script:ReminderStatePath=$null
    if(-not $Demo -and (Test-Path -LiteralPath $script:ReminderSettingsPath)){
        try{
            $settings=[IO.File]::ReadAllText($script:ReminderSettingsPath)|ConvertFrom-Json
            Test-ReminderSettings $settings
            $script:ReminderSettings=[pscustomobject]@{enabled=[bool]$settings.enabled;threshold=[double]$settings.threshold;repeatMinutes=[int]$settings.repeatMinutes}
        }catch{ # A malformed reminder file must not stop querying.
        }
    }
    $script:ReminderState=New-ReminderState $script:ReminderSettings.threshold
    if(-not $Demo -and $script:PublicConfigured){
        $script:ReminderStatePath=Join-Path $script:HistoryDirectory 'reminder-state.json'
        if(Test-Path -LiteralPath $script:ReminderStatePath){
            try{
                $state=[IO.File]::ReadAllText($script:ReminderStatePath)|ConvertFrom-Json
                if($state.version-eq 1 -and $state.active-is [bool] -and
                    [double]$state.threshold-eq $script:ReminderSettings.threshold){$script:ReminderState=$state}
            }catch{ }
        }
    }
    $script:LowBalanceActive=$false
    if(Get-Command Update-ReminderSummary -ErrorAction SilentlyContinue){Update-ReminderSummary}
}

function Get-ReminderDecision {
    param([Parameter(Mandatory=$true)][double]$Balance,
        [Parameter(Mandatory=$true)]$Settings,[Parameter(Mandatory=$true)]$State,
        [datetimeoffset]$Now=[datetimeoffset]::UtcNow)
    Test-ReminderSettings $Settings
    if([double]::IsNaN($Balance)-or [double]::IsInfinity($Balance)){throw 'Balance must be finite.'}
    $next=New-ReminderState ([double]$Settings.threshold)
    $low=[bool]$Settings.enabled -and $Balance-lt [double]$Settings.threshold
    $notify=$false;$reason='normal'
    if(-not $Settings.enabled){$reason='disabled'}
    elseif($low){
        $next.active=$true
        $last=[datetimeoffset]::MinValue
        $parsed=[datetimeoffset]::TryParse([string]$State.lastNotifiedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$last)
        $sameThreshold=[double]$State.threshold-eq [double]$Settings.threshold
        if(-not $State.active-or -not $sameThreshold-or -not $parsed){$notify=$true;$reason='first-low'}
        elseif($last-gt $Now){
            # Clock rollback: establish a new baseline rather than suppressing
            # reminders until the old (future) wall-clock time is reached.
            $next.lastNotifiedUtc=$Now.ToUniversalTime().ToString('o');$reason='clock-reset'
        }
        elseif(($Now-$last).TotalMinutes-ge [int]$Settings.repeatMinutes){$notify=$true;$reason='repeat-due'}
        else{$next.lastNotifiedUtc=$last.ToUniversalTime().ToString('o');$reason='cooldown'}
        if($notify){$next.lastNotifiedUtc=$Now.ToUniversalTime().ToString('o')}
    }
    return [pscustomobject]@{notify=$notify;low=$low;reason=$reason;state=$next}
}

function Save-ReminderState {
    if($Demo-or -not $script:ReminderStatePath){return}
    try{
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:ReminderStatePath))
        [IO.File]::WriteAllText($script:ReminderStatePath,($script:ReminderState|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    }catch{ # In-memory rate limiting still works when local storage is unavailable.
    }
}

function Save-ReminderSettings {
    param([Parameter(Mandatory=$true)]$Settings)
    Test-ReminderSettings $Settings
    $changed=$script:ReminderSettings.enabled-ne $Settings.enabled-or
        [double]$script:ReminderSettings.threshold-ne [double]$Settings.threshold
    if(-not $Demo){
        [void][IO.Directory]::CreateDirectory($script:PublicDataRoot)
        [IO.File]::WriteAllText($script:ReminderSettingsPath,($Settings|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    }
    $script:ReminderSettings=$Settings
    if($changed){
        $script:ReminderState=New-ReminderState ([double]$Settings.threshold)
        $script:LowBalanceActive=$false
        Save-ReminderState
    }
    Update-ReminderSummary
}

function Update-ReminderSummary {
    if($null-eq $script:ReminderSettings){return}
    $label=if($null-ne $window){$window.FindName('ReminderStatusText')}else{$null}
    if($null-ne $label){
        if(-not $script:ReminderSettings.enabled){$label.Text='每 1 分钟查询 · 低电量提醒已关闭';$color='#8291A8'}
        elseif($script:LowBalanceActive){
            $label.Text=('低电量 {0:N2} 度，请及时充值 · 阈值 {1:N2} 度' -f $script:LastBalance,$script:ReminderSettings.threshold)
            $color='#FBBF24'
        }else{
            $label.Text=('低于 {0:N2} 度提醒 · 重复间隔 {1} 分钟' -f $script:ReminderSettings.threshold,$script:ReminderSettings.repeatMinutes)
            $color='#8291A8'
        }
        $label.Foreground=([Windows.Media.BrushConverter]::new()).ConvertFromString($color)
    }
    if($null-ne $script:ReminderIcon){
        $script:ReminderIcon.Text=if($script:LowBalanceActive){'NUIST Electricity - LOW BALANCE'}else{'NUIST Electricity - monitoring'}
        $script:ReminderIcon.Icon=if($script:LowBalanceActive){[Drawing.SystemIcons]::Warning}else{[Drawing.SystemIcons]::Information}
    }
}

function Initialize-ReminderIcon {
    if($null-ne $script:ReminderIcon){return}
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    $script:ReminderIcon=New-Object Windows.Forms.NotifyIcon
    $script:ReminderIcon.Icon=[Drawing.SystemIcons]::Information
    $script:ReminderIcon.Text='NUIST Electricity Query'
    $menu=New-Object Windows.Forms.ContextMenuStrip
    $openItem=$menu.Items.Add('打开电量窗口')
    $openItem.Add_Click({Show-ReminderWindow})
    $settingsItem=$menu.Items.Add('低电量提醒设置')
    $settingsItem.Add_Click({[void](Show-LowBalanceSettings)})
    $testItem=$menu.Items.Add('发送测试提醒')
    $testItem.Add_Click({[void](Send-DesktopReminder -Test)})
    [void]$menu.Items.Add('-')
    $exitItem=$menu.Items.Add('退出工具')
    $exitItem.Add_Click({if($null-ne $closeButton){$closeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}})
    $script:ReminderIcon.ContextMenuStrip=$menu
    $script:ReminderIcon.Add_BalloonTipClicked({Show-ReminderWindow})
    $script:ReminderIcon.Add_DoubleClick({Show-ReminderWindow})
    $script:ReminderIcon.Visible=$true
}

function Show-ReminderWindow {
    if($null-eq $window){return}
    $window.Show()
    if($window.WindowState-eq 'Minimized'){$window.WindowState='Normal'}
    [void][DesktopWidgetNative]::PrepareVisible($script:WidgetHandle)
    $script:WidgetShown=$true
    [void]$window.Activate()
}

function Send-DesktopReminder {
    param([double]$Balance,[switch]$Test)
    try{
        Initialize-ReminderIcon
        $title=if($Test){'电费提醒测试'}else{'宿舍电量不足，请及时充值'}
        $text=if($Test){'这是一条测试通知。正式提醒将在成功查到电量低于设定阈值时发送。'}else{
            '当前剩余 {0:N2} 度，低于设定的 {1:N2} 度。请及时在学校官方渠道缴费，避免欠费停电。' -f $Balance,$script:ReminderSettings.threshold
        }
        $script:ReminderIcon.ShowBalloonTip(10000,$title,$text,[Windows.Forms.ToolTipIcon]::Warning)
        return $true
    }catch{return $false}
}

function Invoke-LowBalanceReminder {
    param([Parameter(Mandatory=$true)][double]$Balance,[datetimeoffset]$Now=[datetimeoffset]::UtcNow)
    # This function is called only by the successful real-time query branch.
    # Notification and filesystem failures must never turn a successful query
    # into a failed balance update or prevent history recording.
    try{
        $decision=Get-ReminderDecision -Balance $Balance -Settings $script:ReminderSettings -State $script:ReminderState -Now $Now
        $script:LowBalanceActive=$decision.low
        if($Demo){Update-ReminderSummary;return}
        $previous=$script:ReminderState|ConvertTo-Json -Compress
        if($decision.notify -and -not (Send-DesktopReminder -Balance $Balance)){
            $decision.state.lastNotifiedUtc=$script:ReminderState.lastNotifiedUtc
        }
        $script:ReminderState=$decision.state
        if(($script:ReminderState|ConvertTo-Json -Compress)-ne $previous){Save-ReminderState}
        Update-ReminderSummary
    }catch{ # Keep the balance and recorder operational if notifications fail.
    }
}

function Show-LowBalanceSettings {
    param($Owner)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    [xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="低电量提醒设置" Width="450" Height="420" ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Background="#111B2A" Foreground="#E8F0FC" FontFamily="Microsoft YaHei UI">
<StackPanel Margin="24">
<TextBlock Text="低电量提醒，避免欠费停电" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,18"/>
<CheckBox x:Name="Enabled" Content="启用 Windows 桌面通知" Foreground="#E8F0FC" FontSize="14" Margin="0,0,0,16"/>
<TextBlock Text="电量低于多少度时提醒（可填小数）"/><TextBox x:Name="Threshold" FontSize="15" Padding="7" Margin="0,4,0,14"/>
<TextBlock Text="仍低于阈值时，每隔多少分钟再次提醒"/><TextBox x:Name="Repeat" FontSize="15" Padding="7" Margin="0,4,0,14"/>
<TextBlock Text="仅成功实时查询触发。Windows 勿扰或通知设置可能拦截弹出。电脑和工具需保持运行。" TextWrapping="Wrap" Foreground="#9BACBF" FontSize="11" Margin="0,0,0,18"/>
<Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
<Button x:Name="Test" Content="发送测试提醒" Height="36" Margin="0,0,6,0"/>
<Button x:Name="Save" Grid.Column="1" Content="保存提醒设置" Height="36" Margin="6,0,0,0" Background="#5EEAD4"/>
</Grid></StackPanel></Window>
'@
    $reader=New-Object Xml.XmlNodeReader $xaml
    $dialog=[Windows.Markup.XamlReader]::Load($reader)
    if($null-ne $Owner-and $Owner.IsVisible){$dialog.Owner=$Owner}
    $dialog.FindName('Enabled').IsChecked=$script:ReminderSettings.enabled
    $dialog.FindName('Threshold').Text=([double]$script:ReminderSettings.threshold).ToString('0.##',[Globalization.CultureInfo]::InvariantCulture)
    $dialog.FindName('Repeat').Text=[string]$script:ReminderSettings.repeatMinutes
    $dialog.FindName('Test').Add_Click({
        $accepted=Send-DesktopReminder -Test
        $message=if($accepted){'已请求发送测试通知；若没看到，请检查 Windows 通知和勿扰设置。'}else{'通知未能发送，请检查 Windows 通知是否可用。'}
        [void][Windows.MessageBox]::Show($dialog,$message,'测试提醒')
    })
    $dialog.FindName('Save').Add_Click({
        try{
            $settings=[pscustomobject]@{enabled=[bool]$dialog.FindName('Enabled').IsChecked;threshold=$dialog.FindName('Threshold').Text.Trim();repeatMinutes=$dialog.FindName('Repeat').Text.Trim()}
            Test-ReminderSettings $settings
            Save-ReminderSettings ([pscustomobject]@{enabled=$settings.enabled;threshold=[double]::Parse($settings.threshold,[Globalization.CultureInfo]::InvariantCulture);repeatMinutes=[int]$settings.repeatMinutes})
            $dialog.DialogResult=$true
            $dialog.Close()
        }catch{[void][Windows.MessageBox]::Show($dialog,'阈值请输入 0–10000 的有限数字；重复间隔请输入 1–1440 的整数分钟。设置未保存时请检查本机目录权限。','无法保存提醒设置')}
    })
    return [bool]$dialog.ShowDialog()
}

function Close-ReminderIcon {
    if($null-eq $script:ReminderIcon){return}
    try{
        $script:ReminderIcon.Visible=$false
        if($null-ne $script:ReminderIcon.ContextMenuStrip){$script:ReminderIcon.ContextMenuStrip.Dispose()}
        $script:ReminderIcon.Dispose()
    }finally{$script:ReminderIcon=$null}
}
