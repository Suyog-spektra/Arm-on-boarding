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
    $trainerUserPassword
)

Start-Transcript -Path "C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt" -Append
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"

#Import Common Functions
$path = pwd
$path = $path.Path
$commonscriptpath = "$path" + "\cloudlabs-common\cloudlabs-windows-functions.ps1"
. $commonscriptpath

# Core CloudLabs setup - unchanged, required regardless of lab content
WindowsServerCommon
CreateCredFile $AzureUserName $AzurePassword $AzureTenantID $AzureSubscriptionID $DeploymentID
Enable-CloudLabsEmbeddedShadow $vmAdminUsername $trainerUserName $trainerUserPassword
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
$WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/faq-ai-assistant/scripts/logon-task.ps1", "C:\LabScripts\logon-task.ps1")

$Trigger = New-ScheduledTaskTrigger -AtLogOn
$User = "$($env:ComputerName)\$vmAdminUsername"
$Action = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe" -Argument "-executionPolicy Unrestricted -WindowStyle Hidden -File C:\LabScripts\logon-task.ps1"
$Settings = New-ScheduledTaskSettingsSet -Hidden
Register-ScheduledTask -TaskName "logon-task" -Trigger $Trigger -User $User -Action $Action -Settings $Settings -RunLevel Highest -Force

Stop-Transcript

Restart-Computer -Force
