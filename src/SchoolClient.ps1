# Public client: only explicitly supplied credentials for the official host.
Add-Type -AssemblyName System.Security
$script:PublicDataRoot = Join-Path $env:LOCALAPPDATA 'NuistElectricityQuery'
$script:PublicConfigPath = Join-Path $script:PublicDataRoot 'config.json'
$script:PublicCredentialPath = Join-Path $script:PublicDataRoot 'credentials.dat'
$script:CredentialEntropy = [Text.Encoding]::UTF8.GetBytes('NuistElectricityQuery-public-v1')
$script:OfficialApiUrl = 'https://icard.nuist.edu.cn/charge/feeitem/getThirdData'

function Test-QueryConfiguration {
    param([Parameter(Mandatory=$true)]$Config)
    foreach ($key in @('feeitemid','level','xiaoqu_id','loudong_id','room_id')) {
        $number = 0
        if (-not [int]::TryParse([string]$Config.query.$key,[ref]$number) -or $number -le 0) {
            throw ('A positive integer is required for '+$key+'. Use your own authorized request values.')
        }
    }
    if ([string]$Config.query.type -notmatch '^[A-Za-z0-9_-]{1,32}$') { throw 'Invalid query type.' }
    if ([string]::IsNullOrWhiteSpace([string]$Config.displayName) -or ([string]$Config.displayName).Length -gt 80) {
        throw 'A display name of 1-80 characters is required.'
    }
}

function Get-ProfileKey {
    param([Parameter(Mandatory=$true)]$Query)
    $identity = @('feeitemid','type','level','xiaoqu_id','loudong_id','room_id') |
        ForEach-Object { $_+'='+[string]$Query.$_ }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($identity -join '&')))
        return ([BitConverter]::ToString($bytes).Replace('-','').Substring(0,24).ToLowerInvariant())
    }
    finally { $hash.Dispose() }
}

function Initialize-PublicQuery {
    $script:PublicConfigured = $false
    $script:PublicConfiguration = $null
    $script:DemoHistory = @()
    if ($Demo) {
        $script:RoomDisplayName = 'NUIST Demo'
        $script:HistoryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('NuistDemo-'+[Guid]::NewGuid().ToString('N'))
        $script:DemoStarted = Get-Date
        $script:DemoHistory = @(for ($index=0; $index -lt 180; $index++) {
            [pscustomobject]@{ Timestamp=$script:DemoStarted.AddMinutes($index-179); Balance=(58.0-[Math]::Floor($index/15.0)*0.24) }
        })
        $script:PublicConfigured = $true
    }
    else {
        $script:RoomDisplayName = 'Configure your room'
        $script:HistoryDirectory = Join-Path $script:PublicDataRoot 'unconfigured'
        if (Test-Path -LiteralPath $script:PublicConfigPath) {
            try {
                $config = [IO.File]::ReadAllText($script:PublicConfigPath) | ConvertFrom-Json
                Test-QueryConfiguration $config
                $script:PublicConfiguration = $config
                $script:RoomDisplayName = [string]$config.displayName
                $script:HistoryDirectory = Join-Path (Join-Path $script:PublicDataRoot 'profiles') (Get-ProfileKey $config.query)
                $script:PublicConfigured = $true
            }
            catch { $script:PublicConfigured = $false }
        }
        [void][IO.Directory]::CreateDirectory($script:HistoryDirectory)
    }
    $script:HistoryPath = Join-Path $script:HistoryDirectory 'history.csv'
    $script:RuntimeLogPath = Join-Path $script:HistoryDirectory 'runtime.log'
    $script:IntentionalExitPath = Join-Path $script:PublicDataRoot 'intentional-exit.flag'
}

function Save-PublicCredentials {
    param([Parameter(Mandatory=$true)][string]$Authorization,[Parameter(Mandatory=$true)][string]$AccessToken)
    if ($Authorization -match '[\r\n]' -or $AccessToken -match '[\r\n]') { throw 'Headers cannot contain line breaks.' }
    if ([string]::IsNullOrWhiteSpace($Authorization) -or [string]::IsNullOrWhiteSpace($AccessToken)) { throw 'Both authorized request headers are required.' }
    $token = [regex]::Replace($AccessToken.Trim(), '(?i)^bearer\s+', '')
    $payload = @{authorization=$Authorization.Trim(); accessToken=$token} | ConvertTo-Json -Compress
    $plain = [Text.Encoding]::UTF8.GetBytes($payload)
    try {
        $encrypted = [Security.Cryptography.ProtectedData]::Protect($plain,$script:CredentialEntropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        [void][IO.Directory]::CreateDirectory($script:PublicDataRoot)
        [IO.File]::WriteAllBytes($script:PublicCredentialPath,$encrypted)
    }
    finally { [Array]::Clear($plain,0,$plain.Length); $payload=$null }
}

function Get-PublicCredentials {
    if (-not (Test-Path -LiteralPath $script:PublicCredentialPath)) { throw 'Authorization is missing. Open Settings.' }
    try {
        $encrypted = [IO.File]::ReadAllBytes($script:PublicCredentialPath)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($encrypted,$script:CredentialEntropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { return ([Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json) }
        finally { [Array]::Clear($plain,0,$plain.Length) }
    }
    catch { throw 'Cannot restore local authorization. Open Settings and enter your own current headers.' }
}

function ConvertFrom-SchoolBalance {
    param([Parameter(Mandatory=$true)]$Response)
    if ([string]$Response.code -ne '200') { throw 'School service rejected the query. Verify your own current authorization and room parameters.' }
    $data = $Response.map.showData
    if ($null -eq $data) { throw 'School response contains no showData. The response format may have changed.' }
    foreach ($property in $data.PSObject.Properties) {
        $number=0.0
        if ([double]::TryParse([string]$property.Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -and
            -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)) {
            return [pscustomobject]@{ Balance=$number; Updated=(Get-Date) }
        }
    }
    throw 'School response has no numeric balance. Check the documented response parser.'
}

function Get-DormBalance {
    if ($Demo) {
        $value = 55.36 - [Math]::Floor(((Get-Date)-$script:DemoStarted).TotalMinutes)*0.01
        return [pscustomobject]@{ Balance=$value; Updated=(Get-Date) }
    }
    if (-not $script:PublicConfigured) { throw 'Configure your own room and authorization in Settings first.' }
    $credentials=Get-PublicCredentials
    $body=@{}
    foreach ($key in @('feeitemid','type','level','xiaoqu_id','loudong_id','room_id')) { $body[$key]=$script:PublicConfiguration.query.$key }
    $headers=@{ Authorization=[string]$credentials.authorization; 'synjones-auth'=('bearer '+[string]$credentials.accessToken) }
    try {
        # The URL is deliberately fixed: a modified config cannot redirect headers.
        $response=Invoke-RestMethod -Method Post -Uri $script:OfficialApiUrl -Headers $headers -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 15 -MaximumRedirection 0
    }
    catch { throw 'Official service query failed. Check connectivity and your current authorization. No response or credentials were logged.' }
    finally { $headers.Clear();$credentials=$null }
    return ConvertFrom-SchoolBalance $response
}

function Show-QuerySettings {
    if ($Demo) {
        return Show-LowBalanceSettings
    }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    [xml]$settingsXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="NUIST Electricity - Settings" Width="520" Height="720" MinWidth="440" MinHeight="540" WindowStartupLocation="CenterScreen" Background="#111B2A" Foreground="#E8F0FC" FontFamily="Segoe UI">
<Window.Resources>
<Style TargetType="TextBox"><Setter Property="Margin" Value="0,3,0,10"/><Setter Property="Padding" Value="8"/><Setter Property="FontSize" Value="13"/></Style>
<Style TargetType="PasswordBox"><Setter Property="Margin" Value="0,3,0,10"/><Setter Property="Padding" Value="8"/><Setter Property="FontSize" Value="13"/></Style>
</Window.Resources>
<ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24">
<TextBlock Text="&#x5357;&#x4EAC;&#x4FE1;&#x606F;&#x5DE5;&#x7A0B;&#x5927;&#x5B66;&#x7535;&#x8D39;&#x67E5;&#x8BE2;" FontSize="21" FontWeight="SemiBold" Margin="0,0,0,12"/>
<TextBlock Text="&#x4EC5;&#x586B;&#x5199;&#x672C;&#x4EBA;&#x5DF2;&#x6388;&#x6743;&#x7684;&#x5B98;&#x65B9;&#x8BF7;&#x6C42;&#x53C2;&#x6570;&#x3002;&#x8BE6;&#x89C1; docs/METHOD.md&#x3002;" TextWrapping="Wrap" Margin="0,0,0,14"/>
<Button x:Name="ReminderSettingsButton" Content="&#x4F4E;&#x7535;&#x91CF;&#x63D0;&#x9192;&#x8BBE;&#x7F6E;&#xFF08;&#x9632;&#x6B62;&#x6B20;&#x8D39;&#x505C;&#x7535;&#xFF09;" Height="40" Margin="0,0,0,16" Background="#5EEAD4" Foreground="#102524" FontSize="14"/>
<TextBlock Text="&#x623F;&#x95F4;&#x663E;&#x793A;&#x540D;&#x79F0;"/><TextBox x:Name="DisplayName"/>
<TextBlock Text="feeitemid"/><TextBox x:Name="FeeItem"/>
<TextBlock Text="type"/><TextBox x:Name="QueryType" Text="IEC"/>
<TextBlock Text="level"/><TextBox x:Name="Level" Text="3"/>
<TextBlock Text="xiaoqu_id"/><TextBox x:Name="Campus"/>
<TextBlock Text="loudong_id"/><TextBox x:Name="Building"/>
<TextBlock Text="room_id"/><TextBox x:Name="Room"/>
<TextBlock Text="Authorization (full request header)"/><PasswordBox x:Name="Authorization"/>
<TextBlock Text="synjones-auth (bearer token)"/><PasswordBox x:Name="AccessToken"/>
<TextBlock Text="&#x4FDD;&#x5B58;&#x540E;&#x51ED;&#x636E;&#x4F7F;&#x7528; Windows DPAPI &#x52A0;&#x5BC6;&#x3002;&#x4E0D;&#x8981;&#x628A;&#x771F;&#x5B9E;&#x914D;&#x7F6E;&#x3001;&#x8BF7;&#x6C42;&#x6216;&#x622A;&#x56FE;&#x4E0A;&#x4F20;&#x81F3; GitHub&#x3002;" TextWrapping="Wrap" Foreground="#9BACBF" Margin="0,3,0,14"/>
<Button x:Name="SaveButton" Content="&#x4FDD;&#x5B58;&#x8BBE;&#x7F6E;" Height="40" Background="#5EEAD4" Foreground="#102524" FontSize="14"/>
</StackPanel></ScrollViewer></Window>
'@
    $reader=New-Object Xml.XmlNodeReader $settingsXaml
    $dialog=[Windows.Markup.XamlReader]::Load($reader)
    $dialog.FindName('ReminderSettingsButton').Add_Click({[void](Show-LowBalanceSettings -Owner $dialog)})
    $fieldMap=@{feeitemid='FeeItem';type='QueryType';level='Level';xiaoqu_id='Campus';loudong_id='Building';room_id='Room'}
    if ($null-ne $script:PublicConfiguration) {
        $dialog.FindName('DisplayName').Text=[string]$script:PublicConfiguration.displayName
        foreach ($entry in $fieldMap.GetEnumerator()) { $dialog.FindName($entry.Value).Text=[string]$script:PublicConfiguration.query.($entry.Key) }
    }
    $dialog.FindName('SaveButton').Add_Click({
        try {
            $query=[ordered]@{}
            foreach ($entry in $fieldMap.GetEnumerator()) { $query[$entry.Key]=$dialog.FindName($entry.Value).Text.Trim() }
            $config=[pscustomobject]@{displayName=$dialog.FindName('DisplayName').Text.Trim(); query=[pscustomobject]$query}
            Test-QueryConfiguration $config
            $authorization=$dialog.FindName('Authorization').Password
            $token=$dialog.FindName('AccessToken').Password
            if ($authorization -or $token) { Save-PublicCredentials -Authorization $authorization -AccessToken $token }
            elseif (-not (Test-Path -LiteralPath $script:PublicCredentialPath)) { throw 'Enter both headers for your first configuration.' }
            [void][IO.Directory]::CreateDirectory($script:PublicDataRoot)
            [IO.File]::WriteAllText($script:PublicConfigPath,($config|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
            $dialog.FindName('Authorization').Clear();$dialog.FindName('AccessToken').Clear()
            $authorization=$null;$token=$null
            $dialog.DialogResult=$true
            $dialog.Close()
        }
        catch { [void][Windows.MessageBox]::Show($_.Exception.Message,'Settings') }
    })
    $saved=$dialog.ShowDialog()
    if ($saved) { Initialize-PublicQuery; Initialize-ReminderSettings }
    return [bool]$saved
}
