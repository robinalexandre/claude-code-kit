# Sets up the Claude Code config sync on Windows. Run it from the cloned repo:
#   powershell -ExecutionPolicy Bypass -File $HOME\.claude-sync\install.ps1 [-Machine windows] [-DevDir C:\path\to\repos]
param([string]$Machine = 'windows', [string]$DevDir = '')
$ErrorActionPreference = 'Stop'

foreach ($tool in @(@{ Cmd = 'git'; Id = 'Git.Git' }, @{ Cmd = 'jq'; Id = 'jqlang.jq' })) {
  if (-not (Get-Command $tool.Cmd -ErrorAction SilentlyContinue)) {
    Write-Host "Installing $($tool.Cmd)..."
    winget install --id $tool.Id -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  }
}

$gitDir = Split-Path (Get-Command git).Source
$bash = @(
  (Join-Path (Split-Path $gitDir) 'bin\bash.exe'),
  (Join-Path (Split-Path (Split-Path $gitDir)) 'bin\bash.exe'),
  'C:\Program Files\Git\bin\bash.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) { throw 'Git Bash (bash.exe) not found. Install Git for Windows.' }

if (-not $DevDir) {
  $current = '~/dev'
  $conf = Join-Path $PSScriptRoot "machines\$Machine.json"
  if (Test-Path $conf) {
    $saved = (Get-Content $conf -Raw | ConvertFrom-Json).devDir
    if ($saved) { $current = $saved }
  }
  $DevDir = Read-Host "Folder that holds your git repos [$current]"
  if (-not $DevDir) { $DevDir = $current }
}

& $bash (($PSScriptRoot -replace '\\', '/') + '/install.sh') $Machine ($DevDir -replace '\\', '/')
if ($LASTEXITCODE -ne 0) { throw 'install.sh failed, see the messages above.' }
