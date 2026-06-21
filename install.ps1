# Heimdall installer (Windows, PowerShell).
#
#   irm https://raw.githubusercontent.com/galaxoid-labs/heimdall/main/install.ps1 | iex
#
# Installs into %USERPROFILE%\.heimdall:
#   bin\heimdall.exe   the CLI (prebuilt, from GitHub Releases)
#   heimdall\          the framework source (so `heimdall new` finds it)
# and sets the user PATH + HEIMDALL_HOME environment variables.
#
# Env knobs:
#   $env:HEIMDALL_VERSION = "v0.1.0"   install a specific release (default: latest)
#   $env:HEIMDALL_HOME    = "C:\path"  install location (default: $HOME\.heimdall)
#   $env:HEIMDALL_NO_MODIFY_PATH = "1" don't touch user PATH / env vars
#   $env:HEIMDALL_SKIP_VERIFY = "1"    skip SHA256 verification (not recommended)

$ErrorActionPreference = "Stop"

$Repo    = "galaxoid-labs/heimdall"
$Home_   = if ($env:HEIMDALL_HOME) { $env:HEIMDALL_HOME } else { Join-Path $HOME ".heimdall" }
$Version = if ($env:HEIMDALL_VERSION) { $env:HEIMDALL_VERSION } else { "latest" }

function Say  ($m) { Write-Host "heimdall $m" -ForegroundColor Blue }
function Ok   ($m) { Write-Host "  + $m" -ForegroundColor Green }
function Die  ($m) { Write-Host "heimdall: $m" -ForegroundColor Red; exit 1 }

# --- detect arch -----------------------------------------------------------
$arch = $env:PROCESSOR_ARCHITECTURE
switch ($arch) {
  "AMD64" { $Arch = "x86_64" }
  "ARM64" { $Arch = "arm64" }
  default { Die "unsupported architecture '$arch'" }
}

if ($env:HEIMDALL_BASE_URL) {
  $Base = $env:HEIMDALL_BASE_URL
} elseif ($Version -eq "latest") {
  $Base = "https://github.com/$Repo/releases/latest/download"
} else {
  $Base = "https://github.com/$Repo/releases/download/$Version"
}
$CliAsset       = "heimdall-windows-$Arch.exe"
$FrameworkAsset = "heimdall-framework.tar.gz"

Say "installer"
Write-Host "  platform   windows/$Arch"
Write-Host "  version    $Version"
Write-Host "  into       $Home_"
Write-Host "  source     github.com/$Repo"
Write-Host ""

# --- install ---------------------------------------------------------------
$bin = Join-Path $Home_ "bin"
New-Item -ItemType Directory -Force -Path $bin | Out-Null

# Download SHA256SUMS and verify each asset against it (unless opted out).
$verify = ($env:HEIMDALL_SKIP_VERIFY -ne "1")
$sums = @{}
if ($verify) {
  $sumsText = (Invoke-WebRequest -Uri "$Base/SHA256SUMS" -UseBasicParsing).Content
  foreach ($line in ($sumsText -split "`n")) {
    $p = ($line.Trim() -split "\s+", 2)
    if ($p.Count -eq 2) { $sums[$p[1]] = $p[0].ToLower() }
  }
} else { Write-Host "  ! skipping download verification (HEIMDALL_SKIP_VERIFY=1)" -ForegroundColor Red }

function Verify-Asset($file, $asset) {
  if (-not $verify) { return }
  $want = $sums[$asset]
  if (-not $want) { Die "no checksum listed for $asset in SHA256SUMS" }
  $got = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()
  if ($want -ne $got) { Die "checksum mismatch for $asset (expected $want, got $got)" }
  Ok "verified $asset"
}

Say "downloading CLI ($CliAsset)..."
$exe = Join-Path $bin "heimdall.exe"
Invoke-WebRequest -Uri "$Base/$CliAsset" -OutFile $exe
Verify-Asset $exe $CliAsset
Ok "CLI -> $exe"

Say "downloading framework ($FrameworkAsset)..."
$tar = Join-Path $env:TEMP "heimdall-framework.tar.gz"
Invoke-WebRequest -Uri "$Base/$FrameworkAsset" -OutFile $tar
Verify-Asset $tar $FrameworkAsset
$fw = Join-Path $Home_ "heimdall"
if (Test-Path $fw) { Remove-Item -Recurse -Force $fw }
# bsdtar ships with Windows 10+ as tar.exe
tar -xzf $tar -C $Home_
if (-not (Test-Path $fw)) { Die "framework archive did not contain a 'heimdall' directory" }
Ok "framework -> $fw"

# --- env vars (user scope) -------------------------------------------------
if ($env:HEIMDALL_NO_MODIFY_PATH -ne "1") {
  [Environment]::SetEnvironmentVariable("HEIMDALL_HOME", $Home_, "User")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($userPath -notlike "*$bin*") {
    $newPath = if ($userPath) { "$bin;$userPath" } else { $bin }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  }
  Ok "set user PATH + HEIMDALL_HOME"
  # Reflect into the current session too.
  $env:HEIMDALL_HOME = $Home_
  $env:Path = "$bin;$env:Path"
}

Write-Host ""
Say "installed."
Write-Host ""
Write-Host "Open a new terminal, then:"
Write-Host "  heimdall doctor     check your toolchain (Odin + bun + WebView2)"
Write-Host "  heimdall new myapp  scaffold an app"
Write-Host ""
Write-Host "heimdall builds apps with Odin and bun - install those too if 'doctor' flags them." -ForegroundColor DarkGray
