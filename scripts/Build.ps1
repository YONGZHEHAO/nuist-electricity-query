param([string]$Version='0.1.0')
$ErrorActionPreference='Stop'
if($Version-notmatch '^\d+\.\d+\.\d+$'){throw 'Use a semantic version such as 0.1.0.'}
$root=Split-Path $PSScriptRoot
$dist=Join-Path $root 'dist'
$package=Join-Path $dist ('NUIST-Electricity-v'+$Version+'-windows-x64')
if(Test-Path -LiteralPath $package){throw 'Package already exists. Move the old package before rebuilding.'}
[void][IO.Directory]::CreateDirectory($package)
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $compiler)){throw 'The Windows .NET Framework x64 compiler is required.'}
$exe=Join-Path $package 'NUIST-Electricity.exe'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /debug- "/out:$exe" /reference:System.Windows.Forms.dll (Join-Path $root 'src\Launcher.cs')
if($LASTEXITCODE-ne 0){throw 'Launcher compilation failed.'}
[void][IO.Directory]::CreateDirectory((Join-Path $package 'src'))
foreach($name in @('PowerBalance.ps1','PowerBalance.Motion.cs','SchoolClient.ps1')){
    Copy-Item -LiteralPath (Join-Path $root ('src\'+$name)) -Destination (Join-Path $package ('src\'+$name))
}
foreach($name in @('README.md','LICENSE','SECURITY.md','config.example.json')){
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $package $name)
}
[void][IO.Directory]::CreateDirectory((Join-Path $package 'docs'))
foreach($name in @('METHOD.md','PRIVACY.md')){
    Copy-Item -LiteralPath (Join-Path $root ('docs\'+$name)) -Destination (Join-Path $package ('docs\'+$name))
}
Copy-Item -LiteralPath (Join-Path $root 'scripts\Demo.cmd') -Destination (Join-Path $package 'Demo.cmd')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=$package+'.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($package,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'),$hash+'  '+[IO.Path]::GetFileName($zip)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
'Portable package: '+$zip
'SHA256: '+$hash
