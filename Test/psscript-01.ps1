Param (
    [Parameter(Mandatory = $true)]
    [string]$AzureUserName,
    [string]$AzurePassword,
    [string]$AzureTenantID,
    [string]$AzureSubscriptionID,
    [string]$ODLID,
    [string]$DeploymentID,
    [string]$vmAdminUsername,
    [string]$adminPassword,
    [string]$trainerUserName,
    [string]$trainerUserPassword,
    [string]$GitHubUserName,
    [string]$PAT,
    [string]$GitHubOrg,
    [string]$ghsecret
)

try {
    Start-Transcript -Path "C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt" -Append -ErrorAction Stop
} catch {
    Write-Warning "Start-Transcript failed (a transcript may already be running): $($_.Exception.Message)"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

Write-Host "Downloading cloudlabs-windows-functions.ps1..."
$commonScriptDir  = "C:\LabFiles\cloudlabs-common"
$commonscriptpath = Join-Path $commonScriptDir "cloudlabs-windows-functions.ps1"
$commonFunctionsLoaded = $false

try {
    New-Item -ItemType Directory -Path $commonScriptDir -Force | Out-Null
    Invoke-WebRequest -Uri "https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/cloudlabs-windows-functions.ps1" `
        -OutFile $commonscriptpath -UseBasicParsing -ErrorAction Stop
    . $commonscriptpath
    $commonFunctionsLoaded = $true
    Write-Host "Loaded common functions from $commonscriptpath" -ForegroundColor Green
} catch {
    Write-Warning "Could not download/load cloudlabs-windows-functions.ps1: $($_.Exception.Message)"
    Write-Warning "CloudLabs-specific steps will be skipped for this run."
}

function Invoke-IfAvailable {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if (Get-Command $Name -ErrorAction SilentlyContinue) {
        try { & $Action }
        catch { Write-Warning "$Name failed: $($_.Exception.Message)" }
    } else {
        Write-Warning "$Name is not available (common functions not loaded) - skipping."
    }
}

$emailPattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'
if ($AzureUserName -notmatch $emailPattern) {
    Write-Warning "AzureUserName ('$AzureUserName') doesn't look like a valid email address - skipping CreateCredFile and Enable-GitHub to avoid corrupting downstream files. Re-run the script passing -AzureUserName explicitly as a parameter (not by pasting into an open console)."
} else {
    Invoke-IfAvailable -Name "CreateCredFile" -Action {
        CreateCredFile $AzureUserName $AzurePassword $AzureTenantID $AzureSubscriptionID $DeploymentID
    }
}

if (Test-Path "C:\LabFiles\AzureCreds.ps1") {
    . C:\LabFiles\AzureCreds.ps1
} else {
    Write-Warning "C:\LabFiles\AzureCreds.ps1 not found - skipping credential load (CreateCredFile may not have run)."
}

# populated to succeed, same class of issue as the logon-task fix below.
if ([string]::IsNullOrWhiteSpace($trainerUserName) -or [string]::IsNullOrWhiteSpace($trainerUserPassword)) {
    Write-Warning "trainerUserName/trainerUserPassword not supplied - skipping Enable-CloudLabsEmbeddedShadow (it would fail creating the scheduled task with an empty user)."
} else {
    Invoke-IfAvailable -Name "Enable-CloudLabsEmbeddedShadow" -Action {
        Enable-CloudLabsEmbeddedShadow $vmAdminUsername $trainerUserName $trainerUserPassword
    }
}

# --- Microsoft.Graph modules (installmggraph is the common-functions helper
# that installs exactly the sub-modules Enable-GitHub needs) ---
Invoke-IfAvailable -Name "installmggraph" -Action { installmggraph }

# --- GitHub / Copilot enablement ---
$UserEmail    = $AzureUserName
$TenantId     = "f871d17e-efcd-44c7-ba5a-0162efa2fded"
$ClientId     = "e6b585c6-079f-489c-ae6b-a57a274139ea"
$ClientSecret = "w2R8Q~MooRgSA855CVxZitnxayzHDecQx4yFHahc"

if ($UserEmail -notmatch $emailPattern) {
    Write-Warning "UserEmail ('$UserEmail') doesn't look like a valid email address - skipping Enable-GitHub."
} else {
    Invoke-IfAvailable -Name "Enable-GitHub" -Action {
        Enable-GitHub -UserEmail $UserEmail -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -WithCopilot
    }
}

[System.Environment]::SetEnvironmentVariable('GitUserEmail', $GitHubUserName, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('ghsecret', $ghsecret, [System.EnvironmentVariableTarget]::Machine)

function Stop-ServiceIfRunning {
    param([string]$ServiceName)
    try {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Host "Stopping '$ServiceName' before reinstall..."
            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
        }
    } catch {
        Write-Warning "Could not stop service '$ServiceName': $($_.Exception.Message)"
    }
}

Stop-ServiceIfRunning -ServiceName "Spektra.CloudLabs.Agent"
Invoke-IfAvailable -Name "CloudlabsManualAgent" -Action { CloudlabsManualAgent -Task "Install" }

# InstallVSCode / InstallModernVmValidator both route through the common
Invoke-IfAvailable -Name "InstallVSCode" -Action { InstallVSCode }

Stop-ServiceIfRunning -ServiceName "Spektra CloudLabs VM Agent"
Invoke-IfAvailable -Name "InstallModernVmValidator" -Action { InstallModernVmValidator }

# --- Az module setup ---
try {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Host "Az.Accounts module not found - installing..."
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module -Name Az.Accounts -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module Az.Accounts -ErrorAction Stop

    $updateAzConfigCmd = Get-Command Update-AzConfig -ErrorAction SilentlyContinue
    if ($updateAzConfigCmd -and $updateAzConfigCmd.Parameters.ContainsKey('DisableBreakingChangeWarning')) {
        Update-AzConfig -DisableBreakingChangeWarning -Scope Process -ErrorAction SilentlyContinue
    } else {
        Write-Warning "Update-AzConfig -DisableBreakingChangeWarning not supported by installed Az.Accounts version - skipping."
    }
    Get-AzContext -ErrorAction SilentlyContinue | Out-Null
} catch {
    Write-Warning "Az.Accounts setup had an issue: $($_.Exception.Message)"
}

try {
    Import-Module $env:ChocolateyInstall\helpers\chocolateyProfile.psm1 -ErrorAction Stop
} catch {
    Write-Warning "Could not import Chocolatey profile module: $($_.Exception.Message)"
}
Start-Sleep -Seconds 30

# --- Python 3 and pip ---
Write-Host "Installing Python..."
if (Get-Command Install-ChocoPackage -ErrorAction SilentlyContinue) {
    Install-ChocoPackage -PackageName "python"
} else {
    try { choco install python -y } catch { Write-Warning "Python install failed: $($_.Exception.Message)" }
}

# --- .NET SDK ---
Write-Host "Installing .NET SDK..."
if (Get-Command Install-ChocoPackage -ErrorAction SilentlyContinue) {
    Install-ChocoPackage -PackageName "dotnet-sdk"
} else {
    try { choco install dotnet-sdk -y } catch { Write-Warning ".NET SDK install failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# Dev Tunnel CLI: aka.ms/DevTunnelCliInstall serves a *bash* installer meant
# for Linux/macOS. On Windows, download the binary directly instead.
# ---------------------------------------------------------------------------
Write-Host "Installing Dev Tunnel CLI..."
try {
    $devTunnelDir = "C:\Program Files\devtunnel"
    New-Item -Path $devTunnelDir -ItemType Directory -Force | Out-Null
    Invoke-WebRequest -Uri "https://aka.ms/TunnelsCliDownload/win-x64" -OutFile "$devTunnelDir\devtunnel.exe" -UseBasicParsing

    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$devTunnelDir*") {
        [System.Environment]::SetEnvironmentVariable('Path', "$machinePath;$devTunnelDir", 'Machine')
    }
    $env:Path += ";$devTunnelDir"
} catch {
    Write-Warning "Dev Tunnel CLI install failed: $($_.Exception.Message)"
}

try { refreshenv } catch { Write-Warning "refreshenv failed: $($_.Exception.Message)" }

# --- Verify installs ---
foreach ($check in @(
    @{ Name = "python";    Args = "--version" },
    @{ Name = "pip";       Args = "--version" },
    @{ Name = "dotnet";    Args = "--version" },
    @{ Name = "devtunnel"; Args = "--version" }
)) {
    try {
        if (Get-Command $check.Name -ErrorAction SilentlyContinue) {
            & $check.Name $check.Args
        } else {
            Write-Warning "$($check.Name) not found on PATH in this session yet."
        }
    } catch {
        Write-Warning "$($check.Name) --version failed: $($_.Exception.Message)"
    }
}

# --- SQL Server (mssql) VS Code extension ---
Write-Host "Installing SQL Server (mssql) VS Code extension..."
try {
    $codeCmd = Get-Command code -ErrorAction SilentlyContinue
    if (-not $codeCmd) { refreshenv; $codeCmd = Get-Command code -ErrorAction SilentlyContinue }
    if ($codeCmd) {
        code --install-extension ms-mssql.mssql --force
        code --list-extensions | Select-String "ms-mssql.mssql"
    } else {
        Write-Warning "'code' CLI not found on PATH - skipping VS Code extension install."
    }
} catch {
    Write-Warning "VS Code extension install failed: $($_.Exception.Message)"
}

# --- Logon task for interactive-context installs (Copilot/SQL extensions) ---
try {
    New-Item -Path "C:\LabScripts" -ItemType Directory -Force | Out-Null
    $WebClient = New-Object System.Net.WebClient
    $WebClient.DownloadFile(
        "https://experienceazure.blob.core.windows.net/templates/github-copilot-sdlc/scripts/logontask-01.ps1",
        "C:\LabScripts\logon-task.ps1"
    )
} catch {
    Write-Warning "Could not download logon-task.ps1: $($_.Exception.Message)"
}

$effectiveAdminUser = $vmAdminUsername
if ([string]::IsNullOrWhiteSpace($effectiveAdminUser)) {
    Write-Warning "vmAdminUsername was not supplied - falling back to current user '$env:USERNAME' for the scheduled task."
    $effectiveAdminUser = $env:USERNAME
}
$User = "$($env:ComputerName)\$effectiveAdminUser"

try {
    $Trigger  = New-ScheduledTaskTrigger -AtLogOn
    $Action   = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe" `
                    -Argument "-executionPolicy Unrestricted -WindowStyle Hidden -File C:\LabScripts\logon-task.ps1"
    $Settings = New-ScheduledTaskSettingsSet -Hidden
    Register-ScheduledTask -TaskName "logon-task" -Trigger $Trigger -User $User -Action $Action -Settings $Settings -RunLevel Highest -Force -ErrorAction Stop
} catch {
    Write-Warning "Register-ScheduledTask failed for user '$User': $($_.Exception.Message)"
}

# --- Report any Chocolatey package failures the common functions tracked ---
Invoke-IfAvailable -Name "Get-ChocoInstallReport" -Action { Get-ChocoInstallReport | Out-Null }

try {
    Stop-Transcript
} catch {
    Write-Warning "Stop-Transcript failed: $($_.Exception.Message)"
}
