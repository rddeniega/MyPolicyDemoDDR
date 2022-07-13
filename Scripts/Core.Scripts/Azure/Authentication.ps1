Param(
    [switch]$SuperVerbose
)

. $PSScriptRoot\..\Logging.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Retry.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Json.ps1 -SuperVerbose:$SuperVerbose;

Function GetAccessTokenClientCredentials
{
    Param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$ClientSecret,

        [Parameter(Mandatory = $true)]
        [string]$Scope
    )

    $uri = "https://login.microsoftonline.com/$($TenantId)/oauth2/v2.0/token";
    $form = @{
        "client_id" = $ClientId;
        "client_secret" = $ClientSecret;
        "scope" = $Scope;
        "grant_type" = "client_credentials";
    }

    $result = Invoke-RestMethod -Method POST -Uri $uri -body $form;

    return $result;
}

Function GetAccessTokenFromPowershellCache
{
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Resource
    )

    LogVerbose "Getting Azure Context";
    $ctx = Get-AzContext;

    $authority = "https://login.microsoftonline.com/$($ctx.Tenant.Id)/"
    $sts = "https://sts.windows.net/$($ctx.Tenant.Id)/";

    LogVerbose "Expected Authority is $($authority)";
    LogVerbose "Expected Authority is $($sts)";
 
    LogVerbose "Reading Token Cache"
    $tokens = $ctx.TokenCache.ReadItems();

    LogVerbose "Found $($tokens.count) tokens";

    LogVerbose "Checking to see if this is executing in the context of an Azure DevOps Build";

    if([System.String]::IsNullOrEmpty($env:TF_BUILD) -eq $false)
    {
        LogVerbose "Found the presence of build variable 'TF_BUILD == $($env:TF_BUILD)'. Skipping authority check and using available token";
        $token = $tokens | select-object -first 1;
    }
    else
    {
        LogVerbose "Did not find evidence of Azure DevOps pipeline."        
        $token = $tokens | where-object { $_.IdentityProvider -eq $sts -and $_.Resource -eq $Resource } | select-object -first 1;
    
    }

    return $token.AccessToken;
}