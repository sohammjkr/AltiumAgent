# First-time setup. Run from the repository root:
#   powershell -ExecutionPolicy Bypass -File scripts\setup.ps1

$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

Write-Host "Installing altium-agent and dev dependencies..." -ForegroundColor Cyan
python -m pip install -e ".[dev]" --quiet

if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Host "Created .env - set ANTHROPIC_API_KEY in it." -ForegroundColor Yellow
}

$workdir = "C:\ProgramData\AltiumAgent\bridge"
if (-not (Test-Path $workdir)) {
    New-Item -ItemType Directory -Force -Path $workdir | Out-Null
    Write-Host "Created bridge workdir $workdir"
}

Write-Host "`nRunning tests..." -ForegroundColor Cyan
python -m pytest -q

Write-Host "`nEnvironment check:" -ForegroundColor Cyan
python -m altium_agent.cli doctor

Write-Host @"

Next steps
----------
1. Set ANTHROPIC_API_KEY in .env
2. In Altium: File > Open Project > altium\AltiumAgent.PrjScr
3. Open src\Probe.pas, press F9, run Probe_Main
4. Back here:  altium-agent probe
5. Fix whatever the probe reports, then:  altium-agent serve
"@ -ForegroundColor Green
