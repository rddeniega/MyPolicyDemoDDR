Param(
    [switch]$SuperVerbose
)

. $PSScriptRoot\Core.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\..\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose;

$currentApiVersion = "6.1-preview.1";


Function PostWikiPage{
    Param(

        [Parameter(Mandatory = $true, ParameterSetName = "pat")]
        [string]$PersonalAccessToken,

        [Parameter(Mandatory = $true, ParameterSetName = "bearer")]
        [string]$BearerToken,

        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [string]$Project,

        [Parameter(Mandatory = $true)]
        [string]$WikiId,

        [Parameter(Mandatory = $true)]
        [string]$PagePath,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $commonArgs = @{
        "Organization" = $Organization;
        "Project" = $Project;
    }

    if($PSCmdlet.ParameterSetName -eq "pat")
    {
        $commonArgs["PersonalAccessToken"] = $PersonalAccessToken;
    }
    
    if($PSCmdlet.ParameterSetName -eq "bearer")
    {
        $commonArgs["BearerToken"] = $BearerToken;
    }

    LogVerbose $PagePath;

    # Ensure Ancestors
    $pathParts = [System.String[]]$PagePath.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries);

    LogVerbose "ADO.Publish.CreateAncestorTree.All.Start - Starting creation of ancestor pages."
    for($i = 1; $i -le $pathParts.Length -1; $i++)
    {
        $parts = $pathParts | select -First $i;   
        $ancestorPath = [String]::Join("/", $parts);
        
        try
        {           
            LogVerbose "ADO.Publish.CreateAncestorTree.Node.Get.Start - Creating ancestor with path '$($ancestorPath)'";
            $wikiPage = GetWikiPage @commonArgs -WikiId $WikiId -PagePath $ancestorPath;
            LogVerbose "ADO.Publish.CreateAncestorTree.Node.Get.Found - Ancestor with path '$($ancestorPath)' exists, no changes.";

        }
        catch
        {            
            LogVerbose "ADO.Publish.CreateAncestorTree.Missing - Ancestor with path '$($ancestorPath)' does not exist (exception)";

            $ancestorBodyObject = New-Object PSCustomObject;
            $ancestorBodyObject | Add-Member -Type NoteProperty -Name "content" -Value " ";

            LogWarning "Page not found - Creating new ($($ancestorPath))";

            try {
                LogVerbose "ADO.Publish.CreateAncestorTree.Node.Create.Start - Starting to create Ancestor with path '$($ancestorPath)'.";
                $result = CallAdoApi @commonArgs -Method "PUT" -ApiPathAndQuery "wiki/wikis/$($WikiId)/pages?path=$($ancestorPath)&api-version=$($currentApiVersion)" -BodyObject $ancestorBodyObject;
                LogVerbose "ADO.Publish.CreateAncestorTree.Node.Create.Finish - Finished creating Ancestor with path '$($ancestorPath)'.";
            }
            catch {
                LogWarning "ADO.Publish.CreateAncestorTree.Node.Create.Failed - FAILED TO CREATE Ancestor with path '$($ancestorPath)'.";
                throw $_;
            }
            
        }
    }
    
    LogVerbose "ADO.Publish.CreateAncestorTree.All.Finish - Finished creation of ancestor pages."

    $bodyObject = New-Object PSCustomObject;
    $bodyObject | Add-Member -Type NoteProperty -Name "content" -Value $Content;

    $body = $bodyObject | ConvertTo-Json -Depth 100;

    LogVerbose "ADO.Publish.Start - Starting to publish content to '$($PagePath)'.";
    try
    {
        
        LogVerbose "ADO.Publish.Content.GetCurrent - Checking if page exists @ '$($PagePath)'.";
        $wikiPage = GetWikiPage @commonArgs -WikiId $wikiId -PagePath $PagePath;
        LogVerbose "ADO.Publish.Content.GetCurrent.Found - page exists @ '$($PagePath)' - Updating via ETAG.";

        # If we get here, a page exists
        $headers = @{
            "If-Match" =  $wikiPage.Headers["ETag"] | select -first 1 | %{ $_ };
        }

        LogVerbose "ADO.Publish.Content.Update.Start - Updating Page @ '$($PagePath)'.";
        $result = CallAdoApi @commonArgs -Method "PUT" -ApiPathAndQuery "wiki/wikis/$($WikiId)/pages?path=$($PagePath)&api-version=$($currentApiVersion)" -BodyObject $bodyObject -Headers $headers;
        LogVerbose "ADO.Publish.Content.Update.Finish - Finished Updating Page @ '$($PagePath)'.";
    }
    catch
    {
        try 
        {
            LogVerbose "ADO.Publish.Content.GetCurrent.NotFound - Page does not exist @ '$($PagePath)', Creating.";
            LogVerbose $($_.Exception | FlattenException | Stringify)

            LogVerbose "ADO.Publish.Content.Create.Start - Creating Page @ '$($PagePath)'.";
            $result = CallAdoApi @commonArgs -Method "PUT" -ApiPathAndQuery "wiki/wikis/$($WikiId)/pages?path=$($PagePath)&api-version=$($currentApiVersion)" -BodyObject $bodyObject;
            LogVerbose "ADO.Publish.Content.Create.Finish - Finished Creating Page @ '$($PagePath)'.";
        }
        catch {
            LogWarning "ADO.Publish.Content.Create.Failed.Unexpected - Unexpected Failure occured while Creating Page @ '$($PagePath)'. The build will be halted.";
            throw $_;
        }
    }

    return $result.Content | ConvertTo-Json -Depth 100 ;
}

Function GetWikiPage{
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = "pat")]
        [string]$PersonalAccessToken,

        [Parameter(Mandatory = $true, ParameterSetName = "bearer")]
        [string]$BearerToken,

        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [string]$Project,

        [Parameter(Mandatory = $true)]
        [string]$WikiId,

        [Parameter(Mandatory = $true)]
        [string]$PagePath
    )

    
    $commonArgs = @{
        "Organization" = $Organization;
        "Project" = $Project;
    }

    if($PSCmdlet.ParameterSetName -eq "pat")
    {
        $commonArgs["PersonalAccessToken"] = $PersonalAccessToken;
    }
    
    if($PSCmdlet.ParameterSetName -eq "bearer")
    {
        $commonArgs["BearerToken"] = $BearerToken;
    }

    $response = CallAdoApi @commonArgs -Method "GET" -ApiPathAndQuery "wiki/wikis/$($WikiId)/pages?path=$($PagePath)&api-version=$($currentApiVersion)"

    $body = $response.Content | ConvertFrom-Json ;

    $result = New-Object PSCustomObject;
    $result | Add-Member -Type NoteProperty -Name "Headers" -Value $response.Headers;
    $result | Add-Member -Type NoteProperty -Name "Result" -Value $body;

    return $result;
}

Function GetWikis{
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = "pat")]
        [string]$PersonalAccessToken,

        [Parameter(Mandatory = $true, ParameterSetName = "bearer")]
        [string]$BearerToken,

        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [string]$Project
    )

    $commonArgs = @{
        "Organization" = $Organization;
        "Project" = $Project;
    }
    
    if($PSCmdlet.ParameterSetName -eq "pat")
    {
        $commonArgs["PersonalAccessToken"] = $PersonalAccessToken;
    }
    
    if($PSCmdlet.ParameterSetName -eq "bearer")
    {
        $commonArgs["BearerToken"] = $BearerToken;
    }

    $response = CallAdoApi @commonArgs -Method "Get" -ApiPathAndQuery "wiki/wikis?api-version=$($currentApiVersion)";

    $result = $response.Content | ConvertFrom-Json;

    return $result;
}

Function GetWiki{
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = "pat")]
        [string]$PersonalAccessToken,

        [Parameter(Mandatory = $true, ParameterSetName = "bearer")]
        [string]$BearerToken,

        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [string]$Project,

        [Parameter(Mandatory = $true)]
        [string]$WikiName
    )

    
    $commonArgs = @{
        "Organization" = $Organization;
        "Project" = $Project;
    }
    
    if($PSCmdlet.ParameterSetName -eq "pat")
    {
        $commonArgs["PersonalAccessToken"] = $PersonalAccessToken;
    }
    
    if($PSCmdlet.ParameterSetName -eq "bearer")
    {
        $commonArgs["BearerToken"] = $BearerToken;
    }

    $response = CallAdoApi @commonArgs -Method "Get" -ApiPathAndQuery "wiki/wikis/$($WikiName)?api-version=$($currentApiVersion)";

    $result = $response.Content | ConvertFrom-Json;

    return $result;
}