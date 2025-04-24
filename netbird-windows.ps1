# IN the event running scripts is blocked run this command: Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force

# NetBird Silent Installer/Updater for All Users (with Auto-Start)


$repo = "netbirdio/netbird"
$assetNamePattern = "windows"
$downloadPath = "$env:TEMP\netbird_latest.exe"
$versionFile = "$env:ProgramData\netbird_version.txt"
$installPath = "C:\Program Files\NetBird\netbird.exe"

try {
    Write-Output "Checking latest NetBird version..."
    $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ "User-Agent" = "PowerShell" }
    $latestVersion = $releaseInfo.tag_name
    $asset = $releaseInfo.assets | Where-Object { $_.name -like "*$assetNamePattern*" -and $_.name -like "*.exe" } | Select-Object -First 1

    if (-not $asset) {
        Write-Output "Could not find a suitable release asset for Windows."
        pause
        return
    }

    $netbirdInstalled = Test-Path $installPath
    $currentVersion = if (Test-Path $versionFile) { Get-Content $versionFile -ErrorAction SilentlyContinue } else { "" }

    if (-not $netbirdInstalled) {
        Write-Output "NetBird is not installed. Installing latest version $latestVersion..."
    } elseif ($currentVersion -ne $latestVersion) {
        Write-Output "New version detected: $latestVersion (installed: $currentVersion). Updating..."
    } else {
        Write-Output "NetBird is up to date: $currentVersion"
        pause
        return
    }

    Write-Output "Downloading installer..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath

    # Kill running NetBird process if needed
    Get-Process -Name "netbird" -ErrorAction SilentlyContinue | Stop-Process -Force

    # Run installer silently (NSIS)
    Write-Output "Running silent install..."
    Start-Process -FilePath $downloadPath -ArgumentList "/S" -Wait

    # Save new version info
    Set-Content -Path $versionFile -Value $latestVersion

    # Install and start NetBird as a service
    if (Test-Path $installPath) {
        Write-Output "Starting NetBird service..."
        Start-Process -FilePath $installPath -ArgumentList "service install" -Wait
        Start-Process -FilePath $installPath -ArgumentList "service start" -Wait
    }

    Write-Output "Installation and startup complete. NetBird version: $latestVersion"
}
catch {
    Write-Output "An error occurred: $_"
}
