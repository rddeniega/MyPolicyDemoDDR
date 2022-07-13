Param(
    [switch]$SuperVerbose
)

. $PSScriptRoot\..\..\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose;

Function BuildPersonalAccessToken
{
    Param(
        [Parameter(Mandatory = $true)]
        [string]$PersonalAccessToken
    )

    
    $encodedPat = [System.Convert]::ToBase64String([System.Text.ASCIIEncoding]::ASCII.GetBytes(":$($PersonalAccessToken)"));

    return $encodedPat;
}

Function BuildPersonalAccessTokenHeaderValue
{
    Param(
        [Parameter(Mandatory = $true)]
        [string]$PersonalAccessToken
    )

    $val = BuildPersonalAccessToken -PersonalAccessToken $PersonalAccessToken;

    $result = "Basic $($val)";

    return $result;
}

Function CallAdoApi {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true, ParameterSetName = "pat")]
        [string]$PersonalAccessToken,

        [Parameter(Mandatory = $true, ParameterSetName = "bearer")]
        [string]$BearerToken,

        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [string]$Project,

        [Parameter(Mandatory = $true)]
        [string]$ApiPathAndQuery,

        [Hashtable]$Headers = @{},
        [object]$BodyObject = $null
    )

    LogVerbose "START ADO CALL $($Method) $($uri)";

    if($PSCmdlet.ParameterSetName -eq "pat")
    {
        $authHeaderValue = BuildPersonalAccessTokenHeaderValue -PersonalAccessToken $PersonalAccessToken;
    }
    elseif($PSCmdlet.ParameterSetName -eq "bearer")
    {
        $authHeaderValue = "Bearer $($BearerToken)";
    }

    $Headers["Authorization"] = $authHeaderValue; 

    $uri = "https://dev.azure.com/$($Organization)/$($Project)/_apis/$($ApiPathAndQuery)";

    $restArguments = @{
        "ContentType" = "application/json; charset=utf-8";
        "Method" = $Method;
        "Headers" = $Headers;
        "Uri" = $uri;
        "UseBasicParsing" = $true;
        "Verbose" = $VerbosePreference
        "ErrorAction" = "Stop";
    }

    if($BodyObject -ne $null)
    {
        $body = $bodyObject | ConvertTo-Json -Depth 100;

        $restArguments["Body"] = $body;
    }

    try
    {
        $result = Invoke-WebRequest @restArguments;
    }
    catch {
        $er = $_.Exception.Response
        if($er -ne $null)
        {
            Write-Warning "ERROR RESPONSE IS NOT NULL";
        }

        $es = $er.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($es)
        $reader.BaseStream.Position = 0;

        $data = $reader.ReadToEnd();

        LogWarning $data;

        throw $_;
    }

    LogVerbose "ADO RESPONSE TO '$($Method) $($uri)' is '$($result.StatusCode)'";

    return $result;
}