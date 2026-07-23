Param (
    [Parameter(Mandatory = $true)]
    [string]
    $AzureUserName,
    [string]
    $AzurePassword,
    [string]
    $AzureTenantID,
    [string]
    $AzureSubscriptionID,
    [string]
    $ODLID,
    [string]
    $DeploymentID,
    [string]
    $vmAdminUsername,
    [string]
    $adminPassword,
    [string]
    $trainerUserName,
    [string]
    $trainerUserPassword,
    [string]
    $GitHubUserName,
    [string]
    $PAT,
    [string]
    $GitHubOrg,
    [string]
    $ghsecret
)

Start-Transcript -Path "C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt" -Append
[Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"

#Import Common Functions
$path = pwd
$path = $path.Path
$commonscriptpath = "$path" + "\cloudlabs-common\cloudlabs-windows-functions.ps1"
. $commonscriptpath

# Core CloudLabs setup - unchanged, required regardless of lab content
WindowsServerCommon
CreateCredFile $AzureUserName $AzurePassword $AzureTenantID $AzureSubscriptionID $DeploymentID

# Load the credentials that CreateCredFile just wrote out, so subsequent
# Az module / GitHub calls in this session actually have context to work with.
. C:\LabFiles\AzureCreds.ps1

Enable-CloudLabsEmbeddedShadow $vmAdminUsername $trainerUserName $trainerUserPassword

# --- GitHub / Copilot enablement ---
$UserEmail = $AzureUserName
$GroupId = "bb0215fb-69d3-4d16-be56-cd2da619de31"
$TenantId = "f871d17e-efcd-44c7-ba5a-0162efa2fded"
$ClientId = "e6b585c6-079f-489c-ae6b-a57a274139ea"
$ClientSecret = "w2R8Q~MooRgSA855CVxZitnxayzHDecQx4yFHahc"

Enable-GitHub -UserEmail $UserEmail -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -WithCopilot

# Set Environment Variables
# NOTE: fixed from script 2, which referenced the undefined $GitHubUserEmail.
[string]$GitUserEmail = $UserEmail
[string]$PAToken = $ghsecret

[System.Environment]::SetEnvironmentVariable('GitUserEmail', $GitHubUserName, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('ghsecret', $ghsecret, [System.EnvironmentVariableTarget]::Machine)

CloudlabsManualAgent Install

# Exercise 00, Task 2: Visual Studio Code
InstallVSCode
InstallModernVmValidator

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Host "Az.Accounts module not found - installing..."
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name Az.Accounts -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
}
Import-Module Az.Accounts -ErrorAction Stop
Update-AzConfig -DisableBreakingChangeWarning -Scope Process -ErrorAction Stop
Get-AzContext -ErrorAction SilentlyContinue | Out-Null

Import-Module $env:ChocolateyInstall\helpers\chocolateyProfile.psm1

Start-Sleep -Seconds 30

# Exercise 00, Task 2: Python 3 and pip
Write-Host "Installing Python..."
choco install python -y

# Exercise 00, Task 2: .NET SDK
Write-Host "Installing .NET SDK..."
choco install dotnet-sdk -y

# Exercise 00, Task 2: Dev Tunnel CLI
Write-Host "Installing Dev Tunnel CLI..."
Invoke-Expression (Invoke-WebRequest -UseBasicParsing 'https://aka.ms/DevTunnelCliInstall').Content

# Refresh PATH so python/dotnet/devtunnel installed above are callable
# in this same script session.
refreshenv

# Verify installs (matches the checks in Exercise 00, Task 2)
python --version
pip --version
dotnet --version
devtunnel --version

# Install the SQL Server (mssql) VS Code extension so users can connect to
# and query the Azure SQL Database provisioned by the lab, directly from VS Code.
Write-Host "Installing SQL Server (mssql) VS Code extension..."
$codeCmd = Get-Command code -ErrorAction SilentlyContinue
if (-not $codeCmd) {
    # If 'code' isn't on PATH yet in this session, refresh again before trying.
    refreshenv
}
code --install-extension ms-mssql.mssql --force

# Verify the extension installed correctly
code --list-extensions | Select-String "ms-mssql.mssql"

# Download the logon task, which installs the SQL Server / GitHub Copilot
# VS Code extensions in the correct (interactive user) context.
New-Item -Path "C:\LabScripts" -ItemType Directory -Force | Out-Null
$WebClient = New-Object System.Net.WebClient
$WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/github-copilot-sdlc/scripts/logontask-01.ps1", "C:\LabScripts\logon-task.ps1")

$Trigger = New-ScheduledTaskTrigger -AtLogOn
$User = "$($env:ComputerName)\$vmAdminUsername"
$Action = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe" -Argument "-executionPolicy Unrestricted -WindowStyle Hidden -File C:\LabScripts\logon-task.ps1"
$Settings = New-ScheduledTaskSettingsSet -Hidden
Register-ScheduledTask -TaskName "logon-task" -Trigger $Trigger -User $User -Action $Action -Settings $Settings -RunLevel Highest -Force

Stop-Transcript
Restart-Computer -Force
