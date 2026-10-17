$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. (Join-Path $root 'src\Alerts.ps1')
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture=Join-Path $tempRoot ('nuist-alert-test-'+[Guid]::NewGuid().ToString('N'))
$script:PublicDataRoot=$fixture
$script:HistoryDirectory=Join-Path $fixture 'fictional-profile'
$script:PublicConfigured=$true
$Demo=$false
[void][IO.Directory]::CreateDirectory($script:HistoryDirectory)
$script:NotificationCount=0
function Send-DesktopReminder {param($Balance,[switch]$Test) $script:NotificationCount++;return $true}
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
$reports=New-Object 'System.Collections.Generic.List[string]'
try{
    Initialize-ReminderSettings
    $settings=Get-DefaultReminderSettings
    $now=[datetimeoffset]'2026-10-17T08:00:00Z'
    Assert ($settings.enabled-and $settings.threshold-eq 10-and $settings.repeatMinutes-eq 60) 'Default reminder policy differs.'
    foreach($bad in @('',-1,10001,'NaN','Infinity','not-a-number')){
        $rejected=$false
        try{Test-ReminderSettings ([pscustomobject]@{enabled=$true;threshold=$bad;repeatMinutes=60})}catch{$rejected=$true}
        Assert $rejected 'Invalid threshold accepted.'
    }
    foreach($bad in @('',0,1441,1.5,'abc')){
        $rejected=$false
        try{Test-ReminderSettings ([pscustomobject]@{enabled=$true;threshold=10;repeatMinutes=$bad})}catch{$rejected=$true}
        Assert $rejected 'Invalid repeat interval accepted.'
    }
    Test-ReminderSettings ([pscustomobject]@{enabled=$true;threshold=0;repeatMinutes=1})
    Test-ReminderSettings ([pscustomobject]@{enabled=$true;threshold=10000;repeatMinutes=1440})
    $state=New-ReminderState 10
    $atThreshold=Get-ReminderDecision 10 $settings $state $now
    Assert (-not $atThreshold.notify-and -not $atThreshold.low) 'Equality must not alert.'
    $first=Get-ReminderDecision 9.99 $settings $state $now
    Assert ($first.notify-and $first.low) 'First below-threshold value must alert.'
    $zero=Get-ReminderDecision 0 $settings $state $now
    Assert $zero.notify 'Zero balance is valid and must alert below a positive threshold.'
    $cooldown=Get-ReminderDecision 9.5 $settings $first.state ($now.AddMinutes(59))
    Assert (-not $cooldown.notify) 'Repeated alert before interval.'
    $due=Get-ReminderDecision 9.5 $settings $first.state ($now.AddMinutes(60))
    Assert $due.notify 'Repeat interval failed.'
    $resume=Get-ReminderDecision 9.5 $settings $first.state ($now.AddDays(7))
    Assert $resume.notify 'Wakeup should emit one due reminder.'
    $again=Get-ReminderDecision 9.5 $settings $resume.state ($now.AddDays(7).AddMinutes(1))
    Assert (-not $again.notify) 'Missed reminders must not replay after wakeup.'
    $recover=Get-ReminderDecision 10 $settings $first.state ($now.AddMinutes(2))
    Assert (-not $recover.state.active-and $null-eq $recover.state.lastNotifiedUtc) 'Recovery did not clear cycle.'
    Assert (Get-ReminderDecision 9.99 $settings $recover.state ($now.AddMinutes(3))).notify 'New low cycle should alert immediately.'
    $clock=Get-ReminderDecision 9.5 $settings $first.state ($now.AddHours(-2))
    Assert (-not $clock.notify-and $clock.reason-eq 'clock-reset') 'Clock rollback not corrected.'
    $clockDue=Get-ReminderDecision 9.5 $settings $clock.state ($now.AddHours(-1))
    Assert $clockDue.notify 'Clock rollback suppressed reminders indefinitely.'
    $reports.Add('PASS: validation, exact threshold, zero balance, cooldown, due repeats, sleep recovery, recharge reset, clock rollback.')

    Invoke-LowBalanceReminder -Balance 9 -Now $now
    Assert ($script:NotificationCount-eq 1) 'First notification was not requested.'
    Assert (Test-Path -LiteralPath $script:ReminderStatePath) 'Reminder state not persisted.'
    Initialize-ReminderSettings
    Invoke-LowBalanceReminder -Balance 9 -Now ($now.AddMinutes(5))
    Assert ($script:NotificationCount-eq 1) 'Restart bypassed cooldown.'
    $saved=$script:ReminderState.lastNotifiedUtc
    Save-ReminderSettings (Get-DefaultReminderSettings)
    Assert ($script:ReminderState.lastNotifiedUtc-eq $saved) 'Saving unchanged settings reset cooldown.'
    Save-ReminderSettings ([pscustomobject]@{enabled=$true;threshold=10.0;repeatMinutes=120})
    Assert ($script:ReminderState.lastNotifiedUtc-eq $saved) 'Interval edit reset cooldown.'
    Save-ReminderSettings ([pscustomobject]@{enabled=$false;threshold=10.0;repeatMinutes=60})
    Invoke-LowBalanceReminder -Balance 1 -Now ($now.AddMinutes(10))
    Assert ($script:NotificationCount-eq 1) 'Disabled notification was sent.'
    Save-ReminderSettings (Get-DefaultReminderSettings)
    Invoke-LowBalanceReminder -Balance 9 -Now ($now.AddMinutes(11))
    Assert ($script:NotificationCount-eq 2) 'Re-enable failed to begin new cycle.'
    $script:HistoryDirectory=Join-Path $fixture 'another-fictional-profile'
    Initialize-ReminderSettings
    Invoke-LowBalanceReminder -Balance 9 -Now ($now.AddMinutes(12))
    Assert ($script:NotificationCount-eq 3) 'Other room reused prior cooldown.'
    Save-ReminderSettings ([pscustomobject]@{enabled=$true;threshold=8.5;repeatMinutes=60})
    Invoke-LowBalanceReminder -Balance 8 -Now ($now.AddMinutes(13))
    Assert ($script:NotificationCount-eq 4) 'Threshold edit failed to start new evaluation.'
    $reports.Add('PASS: per-room persistence, restart deduplication, unchanged settings, repeat edits, disable/re-enable, threshold edits.')

    function Send-DesktopReminder {param($Balance,[switch]$Test) return $false}
    $script:ReminderState=New-ReminderState 8.5
    Invoke-LowBalanceReminder -Balance 8 -Now ($now.AddMinutes(14))
    Assert ($null-eq $script:ReminderState.lastNotifiedUtc) 'Failed delivery consumed cooldown.'
    $decision=Get-ReminderDecision 8 $script:ReminderSettings $script:ReminderState ($now.AddMinutes(15))
    Assert $decision.notify 'Failed notification cannot retry.'
    function Send-DesktopReminder {param($Balance,[switch]$Test) throw 'Synthetic notifier fault'}
    Invoke-LowBalanceReminder -Balance 8 -Now ($now.AddMinutes(16))
    $reports.Add('PASS: notification failures do not escape balance updates or consume the delivery cooldown.')

    $Demo=$true
    $script:NotificationCount=0
    function Send-DesktopReminder {param($Balance,[switch]$Test) $script:NotificationCount++;return $true}
    $before=([IO.File]::ReadAllText($script:ReminderSettingsPath))
    Initialize-ReminderSettings
    Invoke-LowBalanceReminder -Balance 1 -Now $now
    Assert ($script:NotificationCount-eq 0) 'Demo emitted an automatic system notification.'
    Save-ReminderSettings ([pscustomobject]@{enabled=$true;threshold=100.0;repeatMinutes=1})
    Assert (([IO.File]::ReadAllText($script:ReminderSettingsPath))-eq $before) 'Demo modified real reminder settings.'
    $stateBefore=$script:ReminderState|ConvertTo-Json -Compress
    [void](Send-DesktopReminder -Test)
    Assert (($script:ReminderState|ConvertTo-Json -Compress)-eq $stateBefore) 'Test reminder changed the real alarm cycle.'
    $reports.Add('PASS: demo does not automatically notify or persist settings; explicit test does not mutate alarm state.')
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $source=[IO.File]::ReadAllText((Join-Path $root 'src\Alerts.ps1'))
    [xml]$xaml=[regex]::Match($source,'(?s)\[xml\]\$xaml=@''\r?\n(.*?)\r?\n''@').Groups[1].Value
    $reader=New-Object Xml.XmlNodeReader $xaml
    $dialog=[Windows.Markup.XamlReader]::Load($reader)
    foreach($name in @('Enabled','Threshold','Repeat','Test','Save')){Assert ($null-ne $dialog.FindName($name)) ('Missing reminder control: '+$name)}
    $dialog.Close()
    $reports.Add('PASS: reminder settings XAML and controls load.')
    # Exercise the real balance-update entry point with an unavailable history
    # file and then a failed query. Neither case may suppress or invent alerts.
    $main=[IO.File]::ReadAllText((Join-Path $root 'src\PowerBalance.ps1'))
    $ast=[Management.Automation.Language.Parser]::ParseInput($main,[ref]$null,[ref]$null)
    $node=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-eq 'Update-BalanceDisplay'},$false)
    . ([scriptblock]::Create($node.Extent.Text))
    $statusText=[pscustomobject]@{Text='';Foreground=$null}
    $balanceText=[pscustomobject]@{Text='';Foreground=$null}
    $compactStatusDot=[pscustomobject]@{Fill=$null}
    $brushConverter=New-Object Windows.Media.BrushConverter
    $script:FoldAnimation=$null;$script:WidgetGeometryEditing=$false;$script:IsCollapsed=$false
    $script:NotificationCount=0
    function Get-DormBalance {return [pscustomobject]@{Balance=4.25;Updated=(Get-Date)}}
    function Invoke-LowBalanceReminder {param($Balance)$script:NotificationCount++}
    function Add-BalanceHistory {param($Balance,$Timestamp)throw 'Synthetic history write fault'}
    function Clear-ChartHistoryCache { }
    function Update-CompactBalance { }
    function Set-ResponsiveLayout { }
    function Draw-BalanceChart { }
    function Update-BalanceStatistics {param($CurrentBalance)}
    function Get-BalanceHistory {return [pscustomobject]@{Balance=4.25;Timestamp=(Get-Date)}}
    Update-BalanceDisplay
    Assert ($script:NotificationCount-eq 1-and $balanceText.Text-eq '4.25') 'History write failure suppressed a fresh low-balance alert.'
    function Get-DormBalance {throw 'Synthetic network fault'}
    Update-BalanceDisplay
    Assert ($script:NotificationCount-eq 1) 'Failed query triggered a new alert using historical data.'
    $reports.Add('PASS: failed history write does not suppress a fresh alert; failed query never alerts from old history.')
    $reports
}
finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)-or [IO.Path]::GetFileName($resolved)-notlike 'nuist-alert-test-*'){throw 'Unsafe test cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
