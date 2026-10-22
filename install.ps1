# Installs the kit on Windows from PowerShell: finds Git Bash and runs install.sh in it, with the
# same arguments. Run it from the cloned kit:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 [--all | --list | PART...]
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

& $bash (($PSScriptRoot -replace '\\', '/') + '/install.sh') @args
if ($LASTEXITCODE -ne 0) { throw 'install.sh failed, see the messages above.' }
