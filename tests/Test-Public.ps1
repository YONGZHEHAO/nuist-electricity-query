$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
foreach($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse){
    if($file.FullName-like '*\dist\*'){continue}
    $errors=$null;$tokens=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ('Syntax error: '+$file.Name)}
}
$Demo=$true
. (Join-Path $root 'src\SchoolClient.ps1')
Initialize-PublicQuery
if(-not $script:PublicConfigured -or $script:DemoHistory.Count-ne 180){throw 'Demo initialization failed.'}
$result=Get-DormBalance
if($result.Balance-lt 0){throw 'Demo balance failed.'}
$balance=ConvertFrom-SchoolBalance ([pscustomobject]@{code=200;map=[pscustomobject]@{showData=[pscustomobject]@{reading='42.125'}}})
if($balance.Balance-ne 42.125){throw 'Response parser failed.'}
$rejected=$false
try{ConvertFrom-SchoolBalance ([pscustomobject]@{code=401;map=$null})}catch{$rejected=$true}
if(-not $rejected){throw 'Unauthorized responses must be rejected.'}
$config=[pscustomobject]@{displayName='Fictional test room';query=[pscustomobject]@{feeitemid=1;type='IEC';level=3;xiaoqu_id=1;loudong_id=1;room_id=1}}
Test-QueryConfiguration $config
$first=Get-ProfileKey $config.query
$config.query.room_id=2
if($first-eq (Get-ProfileKey $config.query)){throw 'Room histories are not isolated.'}
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture=Join-Path $tempRoot ('nuist-public-test-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try{
    $script:PublicDataRoot=$fixture
    $script:PublicCredentialPath=Join-Path $fixture 'credentials.dat'
    Save-PublicCredentials -Authorization 'fixture-authorization-not-real' -AccessToken 'fixture-token-not-real'
    $actual=Get-PublicCredentials
    if($actual.accessToken-ne 'fixture-token-not-real'){throw 'DPAPI roundtrip failed.'}
    if([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($script:PublicCredentialPath)).Contains('fixture-token')){throw 'Credentials stored in plaintext.'}
}
finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)-or [IO.Path]::GetFileName($resolved)-notlike 'nuist-public-test-*'){throw 'Unsafe test cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
$source=[IO.File]::ReadAllText((Join-Path $root 'src\PowerBalance.ps1'))
$native=[regex]::Match($source,'(?s)Add-Type -TypeDefinition @''\r?\n(.*?)\r?\n''@').Groups[1].Value
if(-not $native){throw 'Native window helper missing.'}
Add-Type -TypeDefinition $native
[xml]$xaml=[regex]::Match($source,'(?s)\[xml\]\$xaml = @''\r?\n(.*?)\r?\n''@').Groups[1].Value
$reader=New-Object Xml.XmlNodeReader $xaml
$window=[Windows.Markup.XamlReader]::Load($reader)
if($null-eq $window.FindName('AuthButton')-or $null-ne $window.FindName('RechargeButton')){throw 'Public UI controls are incorrect.'}
$window.Close()
$refs=@([Windows.Window].Assembly.Location,[Windows.Media.Visual].Assembly.Location,[Windows.Threading.Dispatcher].Assembly.Location,[System.Xaml.XamlReader].Assembly.Location)
Add-Type -Path (Join-Path $root 'src\PowerBalance.Motion.cs') -ReferencedAssemblies $refs
'PASS: syntax, demo, balance parser, authorization rejection, room isolation, DPAPI, public XAML, native and motion compilation.'
