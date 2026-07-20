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
    $McpRepoUrl,
    [string]
    $FoundryEndpoint,
    [string]
    $FoundryApiKey,
    [string]
    $FoundryChatDeployment,
    [string]
    $FoundryEmbeddingDeployment,
    [string]
    $SqlServerFqdn,
    [string]
    $SqlDatabaseName,
    [string]
    $SqlAdminLogin,
    [string]
    $SqlAdminPassword
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
Enable-CloudLabsEmbeddedShadow $vmAdminUsername $trainerUserName $trainerUserPassword
CloudlabsManualAgent Install

# Exercise 00, Task 2: Visual Studio Code
InstallVSCode
InstallModernVmValidator

New-Item -Path "C:\LabFiles" -ItemType Directory | Out-Null

Import-Module Az.Accounts -ErrorAction Stop
Update-AzConfig -DisableBreakingChangeWarning -Scope Process -ErrorAction Stop
Get-AzContext -ErrorAction SilentlyContinue | Out-Null

Import-Module $env:ChocolateyInstall\helpers\chocolateyProfile.psm1

# Exercise 00, Task 2: Python 3 and pip
Write-Host "Installing Python..."
choco install python -y

# Exercise 00, Task 2: .NET SDK
# --- ADDED --- was required by the lab guide (Exercise 6 / Data API Builder)
# but never actually installed by the original script.
Write-Host "Installing .NET SDK..."
choco install dotnet-sdk -y

# Exercise 00, Task 2: Dev Tunnel CLI
# --- ADDED --- required by the lab guide (Exercise 4) but never installed
# by the original script. Installed via Microsoft's official script rather
# than Chocolatey, since there is no official devtunnel choco package.
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

# --- MCP server + SQL lab working folder setup ---
# Required by Exercise 00, Task 3.
Write-Host "Setting up MCP server folder and SQL lab working folder..."

New-Item -Path "C:\LabFiles\sql_mcp_server" -ItemType Directory -Force | Out-Null
New-Item -Path "C:\LabFiles\sql-mcp-lab" -ItemType Directory -Force | Out-Null

if ($McpRepoUrl) {
    choco install git -y
    refreshenv
    git clone $McpRepoUrl "C:\LabFiles\sql_mcp_server_clone_tmp"
    Copy-Item -Path "C:\LabFiles\sql_mcp_server_clone_tmp\*" -Destination "C:\LabFiles\sql_mcp_server" -Recurse -Force
    Remove-Item -Path "C:\LabFiles\sql_mcp_server_clone_tmp" -Recurse -Force

    if (Test-Path "C:\LabFiles\sql_mcp_server\requirements.txt") {
        Write-Host "Installing MCP server Python dependencies..."
        python -m pip install --upgrade pip
        python -m pip install -r "C:\LabFiles\sql_mcp_server\requirements.txt"
    } else {
        Write-Host "[WARNING] requirements.txt not found after clone - check McpRepoUrl contents." -ForegroundColor Yellow
    }
} else {
    Write-Host "[WARNING] -McpRepoUrl was not provided. C:\LabFiles\sql_mcp_server was created empty." -ForegroundColor Yellow
}

# .env file for the MCP server (server.py), per Exercise 00, Task 4/5
$envFileContent = @"
FOUNDRY_ENDPOINT=$FoundryEndpoint
FOUNDRY_API_KEY=$FoundryApiKey
FOUNDRY_CHAT_DEPLOYMENT=$FoundryChatDeployment
FOUNDRY_EMBEDDING_DEPLOYMENT=$FoundryEmbeddingDeployment
SQL_SERVER=$SqlServerFqdn
SQL_DATABASE=$SqlDatabaseName
SQL_USERNAME=$SqlAdminLogin
SQL_PASSWORD=$SqlAdminPassword
"@

Set-Content -Path "C:\LabFiles\sql_mcp_server\.env" -Value $envFileContent -Encoding UTF8
Write-Host "MCP server .env file written to C:\LabFiles\sql_mcp_server\.env"

# Download the logon task, which installs the SQL Server / GitHub Copilot
# VS Code extensions in the correct (interactive user) context.
$WebClient = New-Object System.Net.WebClient
$WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/faq-ai-assistant/scripts/logon-task.ps1", "C:\LabFiles\logon-task.ps1")

$Trigger = New-ScheduledTaskTrigger -AtLogOn
$User = "$($env:ComputerName)\azureuser"
$Action = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe" -Argument "-executionPolicy Unrestricted -WindowStyle Hidden -File C:\LabFiles\logon-task.ps1"
$Settings = New-ScheduledTaskSettingsSet -Hidden
Register-ScheduledTask -TaskName "logon-task" -Trigger $Trigger -User $User -Action $Action -Settings $Settings -RunLevel Highest -Force

Stop-Transcript

Restart-Computer -Force
