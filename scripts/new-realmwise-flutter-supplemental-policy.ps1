<#
.SYNOPSIS
Creates a narrow App Control supplemental policy for Realmwise's Flutter
release compiler and the currently built Realmwise executable.

.DESCRIPTION
The policy uses SHA-256 hash rules because Flutter's gen_snapshot.exe is
unsigned. It does not modify the active base policy. With -Deploy, it installs
the generated supplemental policy using CiTool, which combines its allow rules
with the base policy identified by -BasePolicyId.

Run this script from an elevated PowerShell prompt. First run it to allow
gen_snapshot.exe and the existing Debug executable. Build the Release app,
then run it again to create a second supplemental policy for the Release EXE.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [guid]$BasePolicyId = '0283ac0f-fff1-49ae-ada1-8a933130cad6',
  [string]$GenSnapshotPath = 'C:\Users\jaken\flutter\flutter\bin\cache\artifacts\engine\windows-x64-release\gen_snapshot.exe',
  [string]$RealmwiseExePath,
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\app-control'),
  [switch]$Deploy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($RealmwiseExePath)) {
  $releaseExe = Join-Path $repositoryRoot 'build\windows\x64\runner\Release\realmwise.exe'
  $debugExe = Join-Path $repositoryRoot 'build\windows\x64\runner\Debug\realmwise.exe'
  $RealmwiseExePath = if (Test-Path -LiteralPath $releaseExe) {
    $releaseExe
  } else {
    Write-Warning 'Release realmwise.exe does not exist yet; using the current Debug executable. Re-run after the first successful Release build to allow its distinct hash.'
    $debugExe
  }
}

$targets = @($GenSnapshotPath, $RealmwiseExePath) | ForEach-Object {
  $item = Get-Item -LiteralPath $_ -ErrorAction Stop
  if ($item.PSIsContainer -or $item.Extension -ne '.exe') {
    throw "Target must be an .exe file: $($_)"
  }
  $item
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$policyId = [guid]::NewGuid()
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$policyName = "Realmwise Flutter Hash Allow $stamp"
$policyXml = Join-Path $OutputDirectory "$policyId.xml"
$policyBinary = Join-Path $OutputDirectory "$policyId.cip"

try {
  Import-Module ConfigCI -ErrorAction Stop
} catch {
  $powershell51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $edition = (Get-CimInstance Win32_OperatingSystem).Caption
  throw @"
The Windows App Control ConfigCI module is unavailable in this shell.

Detected Windows edition: $edition

Windows Home can enforce and deploy App Control policies, but Microsoft does
not provide the App Control PowerShell cmdlets (including ConfigCI) on Home.
Do not try to add a Windows optional feature for ConfigCI on this edition.

Create this policy on a Windows Pro, Enterprise, Education, or Server machine
instead. Copy only the two target EXEs and this script to that machine, then
run it with explicit paths, for example:
  .\new-realmwise-flutter-supplemental-policy.ps1 -GenSnapshotPath C:\Temp\gen_snapshot.exe -RealmwiseExePath C:\Temp\realmwise.exe -OutputDirectory C:\Temp\RealmwisePolicy

Copy the generated .cip file back to this computer and deploy it from an
elevated PowerShell prompt:
  CiTool.exe --update-policy C:\Path\To\<policy-guid>.cip

First run this script from an elevated Windows PowerShell 5.1 session:
  & '$powershell51' -NoProfile

Then verify the module is present:
  Get-Module -ListAvailable ConfigCI

Original import error: $($_.Exception.Message)
"@
}

Write-Host 'Creating hash rules for:' -ForegroundColor Cyan
foreach ($target in $targets) {
  $hash = Get-FileHash -LiteralPath $target.FullName -Algorithm SHA256
  Write-Host "  $($target.FullName)" -ForegroundColor Cyan
  Write-Host "    SHA256 $($hash.Hash)" -ForegroundColor DarkGray
}

# Create rules directly from the two explicit files. Do not scan a directory:
# scanning the Flutter SDK or the repository would create a much broader policy.
$rules = foreach ($target in $targets) {
  New-CIPolicyRule -Level Hash -DriverFilePath $target.FullName
}

New-CIPolicy -FilePath $policyXml -Rules $rules -MultiplePolicyFormat
Set-CIPolicyIdInfo -FilePath $policyXml `
  -SupplementsBasePolicyID $BasePolicyId `
  -PolicyId $policyId `
  -PolicyName $policyName

# A supplemental policy must be enforced to provide its allow rules.
Set-RuleOption -FilePath $policyXml -Option 3 -Delete
ConvertFrom-CIPolicy -XmlFilePath $policyXml -BinaryFilePath $policyBinary | Out-Null

Write-Host "`nCreated supplemental policy:" -ForegroundColor Green
Write-Host "  XML: $policyXml"
Write-Host "  CIP: $policyBinary"
Write-Host "  Supplements base policy: {$BasePolicyId}"

if (-not $Deploy) {
  Write-Host "`nReview the XML, then deploy from an elevated PowerShell prompt:" -ForegroundColor Yellow
  Write-Host "  & '$PSCommandPath' -Deploy"
  exit 0
}

if (-not (Test-IsAdministrator)) {
  throw 'Deployment requires an elevated PowerShell prompt.'
}

$ciTool = Get-Command CiTool.exe -ErrorAction Stop
if ($PSCmdlet.ShouldProcess($policyBinary, 'Deploy App Control supplemental policy')) {
  & $ciTool.Source --update-policy $policyBinary
  if ($LASTEXITCODE -ne 0) {
    throw "CiTool failed with exit code $LASTEXITCODE. The base policy may not allow supplemental policies or may require a signed supplemental policy."
  }
  & $ciTool.Source --refresh
  Write-Host "`nDeployed. Confirm it is active with:" -ForegroundColor Green
  Write-Host "  (CiTool -lp -json | ConvertFrom-Json).Policies | Format-Table PolicyID,FriendlyName,IsEnforced"
}
