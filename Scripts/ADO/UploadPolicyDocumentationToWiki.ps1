[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [string[]]$files,

    [Parameter(Mandatory = $true)]
    [string[]]$scopeNickName,
    
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $true)]
    [string]$Project,

    [Parameter(Mandatory = $true, ParameterSetName = "pat")]
    [string]$AuthenticationVaultName,

    [Parameter(Mandatory = $true, ParameterSetName = "pat")]
    [string]$AuthenticationVaultSecretName,

    [Parameter(Mandatory = $true, ParameterSetName = "bearer")]
    [string]$AccessToken,

    [Parameter(Mandatory = $true, ParameterSetName = "manpat")]
    [string]$PersonalAccessToken,

    [string]$WikiName = "$($Project).wiki",

    [switch]$SuperVerbose
)

. $PSScriptRoot\Common\Wiki.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Core.Scripts\Retry.ps1 -SuperVerbose:$SuperVerbose;

$commonArgs = @{
    "Organization" = $Organization;
    "Project" = $Project;
};

if($PSCmdlet.ParameterSetName -eq "pat")
{
    $secret = Get-AzKeyVaultSecret -VaultName $AuthenticationVaultName -Name $AuthenticationVaultSecretName;
    $commonArgs["PersonalAccessToken"] = $secret.SecretValueText;
}

if($PSCmdlet.ParameterSetName -eq "bearer")
{
    $commonArgs["BearerToken"] = $AccessToken;
}

if($PSCmdlet.ParameterSetName -eq "manpat")
{
    $commonArgs["PersonalAccessToken"] = $PersonalAccessToken;
}


$getWikiInfoBlock = {
    $wikiInfo = GetWiki @commonArgs -WikiName $WikiName;

    LogVerbose "Got Wiki Information (ORG=$($Organization), PROJECT=$($Project), WIKI=$($WikiName))";

    $wikiInfo;
};

$wiki = Retry -OperationName "Deploy/Documentation/ADO/GetWiki" -RetryTimeout 1000 -RetryCount 5 -ScriptBlock $getWikiInfoBlock;

LogVerbose $(Stringify $wiki)

foreach($file in $files)
{
    $fileInfo = Get-Item $file;

    $pagePath = "$($scopeNickName)/$($fileInfo.Name)".Trim(".md");
    $pageContent = $fileInfo | Get-Content -Raw;

    LogVerbose "Uploading '$($file)' to specified wiki for scope '$scopeNickName'";

    $postWikiPageBlock = {
        LogVerbose "Posting Wiki content from file '$($file)' => $($Organization)/$($Project)/$($wiki.value.id)/$($pagePath)";

        PostWikiPage @commonArgs -WikiId $wiki.value.id -PagePath $($pagePath) -Content "$pageContent" -Verbose:$VerbosePreference;
        
        LogVerbose "Successfully posted Wiki content from file '$($file)' => $($Organization)/$($Project)/$($wiki.value.id)/$($pagePath)";
    };

    Retry -OperationName "Deploy/Documentation/ADO/PostWikiPage" -RetryTimeout 1000 -RetryCount 5 -ScriptBlock $postWikiPageBlock;
}
