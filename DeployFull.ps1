[CmdletBinding()]
Param(
    [Parameter()]
    [string]$Root
)

$global:VerbosePreference = "Continue";

Write-Warning "THIS IS A TESTING SCRIPT. DO NOT USE THIS SCRIPT IN A PIPELINE";

if ((Get-Module -ListAvailable -Name Az.Resources) -eq $null)
{
    if (-not ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))
    {
        Write-Warning -Message "The Az.Resources Module is not installed on the local machine and the current user does not have administrative privileges to install it. Please rectify before continuing."
        break
    }
    else
    {
        Install-Module -Name Az.Resources
    } 
}

$contextResult = Get-AzContext
if ($contextResult.Account.Id -eq $null)
{
    Write-Warning -Message "There is no current Azure Context. Enter your Azure UPN now."
    $azureUPN = Read-Host
    Connect-AzAccount -Identity $azureUPN
}


if([String]::IsNullOrEmpty($Root))
{
    $Root = $PSScriptRoot;
}

$arguments = @{
	"SubscriptionId" = '3f763b15-f8d6-4171-a3af-b8c33ee81e8e' ;
    "ParametersFile" = "$Root\parameters.SCGLdemo.json";
    "Verbose" = $VerbosePreference;
    "ErrorAction" = [System.Management.Automation.ActionPreference]::Stop;
    "PolicyDirectories" = @("$PSScriptRoot\Policy\Security");
    "ControlDirectories" = @("$PSScriptRoot\Controls\NIST");
    "ExceptionsFile" = "$Root\exceptions.SCGL.json";
    "DestroyExistingAssignments" = $false;
    "SuperVerbose" = $true;
    "TestingSubscriptionId" = '5175eb3e-e794-4846-8eeb-b155e4caf34f';
    "TestResultOutputDirectory" = "$env:TEMP\Policy\TestOutput\SCGL-demo\";
    "DocumentationAzureDevOpsOrganization" = "AccentureGovernancePlatformATCI"
    "DocumentationAzureDevOpsProject" = "AccentureGovernancePlatform-ATCI-Demo";
    "DocumentationAzureDevOpsWikiName" = "AccentureGovernancePlatform-ATCI-Demo.wiki";
    "DocumentationScopeNickName" = "/SCGL-Policies/Visual Studio Premium with MSDN";
    "PolicyExportClass" = "AuditOnly";
    "TestingCredentialSource" = "PowerShell";
}

$result = .\Deploy.ps1 @arguments;

$result;
