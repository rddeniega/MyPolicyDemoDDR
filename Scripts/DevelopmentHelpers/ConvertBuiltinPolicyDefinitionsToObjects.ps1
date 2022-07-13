[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true, ParameterSetName = "SubscriptionId")]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, ParameterSetName = "ManagementGroupName")]
    [string]$ManagementGroupName
)

. $PSScriptRoot\..\Common\Deployment.ps1;
. $PSScriptRoot\..\Core.Scripts\Diagnostics.ps1;
. $PSScriptRoot\..\Core.Scripts\Logging.ps1;
. $PSScriptRoot\..\Core.Scripts\Json.ps1;
. $PSScriptRoot\..\Core.Scripts\Retry.ps1;
. $PSScriptRoot\..\Core.Scripts\stdio.ps1;

$tempDirectory = [System.IO.Path]::Combine($env:TEMP, [System.Guid]::NewGuid());

if((Test-Path $tempDirectory) -eq $false)
{
    mkdir $tempDirectory | out-null;
}

Push-Location $tempDirectory; 

$getPolicyDefinitionArgs = @{
    "Verbose" = $VerbosePreference;
    "BuiltIn" = $true;
}

if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
{
    $getPolicyDefinitionArgs["SubscriptionId"] = $SubscriptionId;
}

if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
{
    $getPolicyDefinitionArgs["ManagementGroupName"] = $ManagementGroupName;
}

$policyDefinitions = Get-AzPolicyDefinition @getPolicyDefinitionArgs;

$jsonBase = @'
{
    "$schema": "https://schema.toncoso.com/6-4-2019/policyObject.json",
    "id": "REPLACE_ID",
    "name": "REPLACE_NAME",
    "controls": [
        "1d364e72-26d9-4731-b308-29fee6910e0b"
    ],
    "policyObjects": {
        "audit" : REPLACE_AUDIT,
        "deny" : REPLACE_DENY,
        "remediate" : REPLACE_REMEDIATE,
        "append" : REPLACE_APPEND
    }
}
'@;

$defRefJsonBase = @'
{
    "type" : "builtin",
    "definitionId" : "REPLACE_RESOURCE_ID"
}
'@;

foreach($policyDefinition in $policyDefinitions)
{
    

    $nameParts = $policyDefinition.Properties.displayName.Split(" ");

    $nameBuilder = new-object "System.Text.StringBuilder";

    foreach($namePart in $nameParts)
    {
        $chars = $namePart.ToCharArray();
        
        $nameBuilder.Append([Char]::ToUpperInvariant($chars[0])) | out-null;

        for($i = 1; $i -lt $chars.Length; $i++)
        {
            $nameBuilder.Append([Char]::ToLowerInvariant($chars[$i])) | out-null;
        }
    }

    $objectName = [System.Text.RegularExpressions.Regex]::Replace($nameBuilder.ToString(), "[^A-Za-z0-9\-_]", "");

    $referenceJson = $defRefJsonBase.Replace("REPLACE_RESOURCE_ID", $policyDefinition.ResourceId);
    
    $json = $jsonBase.Replace("REPLACE_ID", [Guid]::NewGuid().ToString());
    $json = $json.Replace("REPLACE_NAME", $objectName);

    $effect = $policyDefinition.Properties.policyRule.then.effect.ToLowerInvariant();

    if($effect.ToLowerInvariant() -eq "[parameters('effect')]")
    {
        write-verbose "effect is parameterized, using default value of parameter definition";

        $effect = $policyDefinition.Properties.parameters.effect.defaultValue;

        write-Verbose "New value is $effect";
    }

    Switch($effect.ToLowerInvariant())
    {
        {$_ -eq "audit" -or $_ -eq "auditifnotexists"} {
            Write-Verbose "This policy is an audit";

            $json = $json.Replace("REPLACE_AUDIT", $referenceJson);
            $json = $json.Replace("REPLACE_DENY", "null");
            $json = $json.Replace("REPLACE_REMEDIATE", "null");
            $json = $json.Replace("REPLACE_APPEND", "null");
            break;
        }
        "deny" {
            Write-Verbose "This policy is a deny";

            $json = $json.Replace("REPLACE_AUDIT", "null");
            $json = $json.Replace("REPLACE_DENY", $referenceJson);
            $json = $json.Replace("REPLACE_REMEDIATE", "null");
            $json = $json.Replace("REPLACE_APPEND", "null");
            break;
        }
        "deployifnotexists" {
            Write-Verbose "This policy is a remediate";

            $json = $json.Replace("REPLACE_AUDIT", "null");
            $json = $json.Replace("REPLACE_DENY", "null");
            $json = $json.Replace("REPLACE_REMEDIATE", $referenceJson);
            $json = $json.Replace("REPLACE_APPEND", "null");
            break;
        }
        "append" {
            Write-Verbose "This policy is an append";

            $json = $json.Replace("REPLACE_AUDIT", "null");
            $json = $json.Replace("REPLACE_DENY", "null");
            $json = $json.Replace("REPLACE_REMEDIATE", "null");
            $json = $json.Replace("REPLACE_APPEND", $referenceJson);
            break;
        }
        Default {
            LogWarning "BAD - '$($policyDefinition.Properties.policyRule.then.effect)' ";

        }

    }

    $subDirectory = [System.IO.Path]::Combine($tempDirectory, $policyDefinition.Properties.metadata.category);
    
    if((Test-Path $subDirectory) -eq $false)
    {
        mkdir $subDirectory | out-null;
    }

    $filePath = [System.IO.Path]::Combine($subDirectory, "$($objectName).json");
    write-Verbose "Output file will be '$($filePath)'"

    LogVerbose $json;

    # conver twice to lazy format json - yolo 
    $json | ConvertFrom-Json | ConvertTo-Json -Depth 100 | WriteFile -Path  $filePath;
}

Write-Verbose "Completed output of files"
pop-location;

& explorer "/select,`"$tempDirectory`"";

