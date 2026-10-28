# Glances web server as a Windows service (Glances 4.x + NSSM). Updated 2026-10.
# run this if you are prevented from running scripts:
# Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force

# Run this as Administrator

# Stop on the first failed cmdlet instead of carrying on with a half-done install
$ErrorActionPreference = "Stop"

# Define variables
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd -or $pythonCmd.Source -like "*\WindowsApps\*") {
    # The WindowsApps python.exe is the Microsoft Store alias/stub; a service
    # running as LocalSystem can't use it. Install Python from python.org
    # ("Install for all users" + "Add python.exe to PATH") and re-run.
    Write-Host "Python not found (or only the Microsoft Store alias). Install Python 3.10+ from https://www.python.org/downloads/windows/ and re-run." -ForegroundColor Red
    exit 1
}
$pythonPath = $pythonCmd.Source
# NSSM's download page recommends the 2.24-101 pre-release over 2.24 on
# Windows 10 Creators Update and newer (2.24 services can fail to start).
$nssmUrl = "https://nssm.cc/ci/nssm-2.24-101-g897c7ad.zip"
$nssmZip = "$env:TEMP\nssm.zip"
$nssmExtractPath = "$env:ProgramFiles\nssm"
$glancesServiceName = "Glances"

# Step 1: Install Glances with web dependencies
# Use "python -m pip" so Glances lands in the same Python the service will run
Write-Host "Installing Glances with web support..."
& $pythonPath -m pip install --upgrade "glances[web]" -q
if ($LASTEXITCODE -ne 0) { Write-Host "pip install glances[web] failed." -ForegroundColor Red; exit 1 }

# Step 2: Download and extract NSSM
Write-Host "Downloading NSSM..."
Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip -UseBasicParsing

Write-Host "Extracting NSSM..."
Expand-Archive -Path $nssmZip -DestinationPath $nssmExtractPath -Force

# Find nssm.exe (assumes 64-bit Windows)
$nssmExe = Get-ChildItem "$nssmExtractPath\nssm-*\win64\nssm.exe" -ErrorAction Stop | Select-Object -First 1

# Step 3: Create the Glances service
# On a re-run, remove the old service first so "nssm install" doesn't fail
if (Get-Service $glancesServiceName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing Glances service..."
    & $nssmExe.FullName stop $glancesServiceName | Out-Null
    & $nssmExe.FullName remove $glancesServiceName confirm | Out-Null
}
Write-Host "Creating Glances service..."
# -w = web server mode (binds 0.0.0.0:61208 by default)
& $nssmExe.FullName install $glancesServiceName $pythonPath "-m glances -w"
if ($LASTEXITCODE -ne 0) { Write-Host "nssm install failed." -ForegroundColor Red; exit 1 }

# Optionally set working directory (current user folder)
& $nssmExe.FullName set $glancesServiceName AppDirectory "$env:USERPROFILE"

# Step 4: Start the service
Write-Host "Starting Glances service..."
Start-Service $glancesServiceName

# Step 5: Add Windows Firewall inbound rule for Glances
Write-Host "Adding firewall rule for Glances on port 61208..."
if (-not (Get-NetFirewallRule -DisplayName "Allow Glances Web UI" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow Glances Web UI" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 61208 `
        -Action Allow `
        -Profile Any `
        -Description "Allows inbound TCP traffic for Glances web interface on port 61208" | Out-Null
}


Write-Host "Done. Glances is running on port 61208 and will auto-start on boot."
