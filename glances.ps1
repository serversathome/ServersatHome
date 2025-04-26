# run this if you are prevented from running scripts: 
#Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force

# Run this as Administrator

# Define variables
$pythonPath = (Get-Command python).Source
$nssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
$nssmZip = "$env:TEMP\nssm.zip"
$nssmExtractPath = "$env:ProgramFiles\nssm"
$glancesServiceName = "Glances"

# Step 1: Install Glances with web dependencies
Write-Host "Installing Glances with web support..."
pip install "glances[web]" -q

# Step 2: Download and extract NSSM
Write-Host "Downloading NSSM..."
Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip

Write-Host "Extracting NSSM..."
Expand-Archive -Path $nssmZip -DestinationPath $nssmExtractPath -Force

# Find nssm.exe (assumes 64-bit Windows)
$nssmExe = Get-ChildItem "$nssmExtractPath\nssm-*\win64\nssm.exe" -ErrorAction Stop | Select-Object -First 1

# Step 3: Create the Glances service
Write-Host "Creating Glances service..."
& $nssmExe.FullName install $glancesServiceName $pythonPath "-m glances -w"

# Optionally set working directory (current user folder)
& $nssmExe.FullName set $glancesServiceName AppDirectory "$env:USERPROFILE"

# Step 4: Start the service
Write-Host "Starting Glances service..."
Start-Service $glancesServiceName

Write-Host "Done. Glances is running on port 61208 and will auto-start on boot."
