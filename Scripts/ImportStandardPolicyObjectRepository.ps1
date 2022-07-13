[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [string]$StagingInputDirectory,

    [Parameter(Mandatory = $true)]
    [string]$StagingOutputDirectory,

    [switch]$SuperVerbose
)

Function FindFirstTypeDeclaration
{
    param (
        [Parameter()]
        [PSObject]$InputObject
    )

    $type = $InputObject.GetType();

    if($type.IsArray)
    {
        LogVerbose "Object Is Array";

        foreach($subObj in $InputObject)
        {
            $result = FindFirstTypeDeclaration -InputObject $subObj;
            if($result -ne $null)
            {
                return $result;
            }
        }
    }

    if($type.Name -ne "String")
    {
        LogVerbose "Found SubObject";

        # Get Properties
        foreach($property in $($InputObject.PSObject.Properties | ?{ $_.MemberType -eq "NoteProperty"}))
        {
            LogVerbose "Looking at property $($property.Name)";
            if($property.Name -eq "field" -and $property.Value -eq "type")
            {
                LogVerbose "Found type reference. Looking for an equals statement on this object";
                return $InputObject.PSObject.Properties["equals"].Value;
            }

            # it is not field
            if($property.Value.GetType().Name -ne "String")
            {
                $result = FindFirstTypeDeclaration -InputObject $property.Value;
                if($result -ne $null)
                {
                    return $result;
                }
            }
        }
    }

    return $null;    
}

. $PSScriptRoot\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\Core.Scripts\stdio.ps1 -SuperVerbose:$SuperVerbose;

if((Test-Path $StagingInputDirectory) -eq $false)
{
    LogException "Input Directory does not exist";
}

if((Test-Path $StagingOutputDirectory) -eq $false)
{
    LogVerbose "Staging output directory does not exist, creating"
    mkdir $StagingOutputDirectory | Out-Null;
}

$policyOrganization = New-Object 'System.Collections.Generic.Dictionary[string, PSObject[]]'

Push-Location $StagingInputDirectory;
$policyItems = Get-ChildItem "*.json" -Recurse;
Pop-Location;

LogVerbose "Working on $($policyItems.Length) policies";

foreach($policyItem in $policyItems)
{
    $obj = $policyItem | Get-Content | ConvertFrom-Json;

    # Extract 
    $name = $policyItem.Name.Replace(".json", "");
    $id = [System.Guid]::NewGuid().ToString();
    $controls = @();
    $initiative = FindFirstTypeDeclaration -InputObject $obj;
    $initiativeParts = $initiative.Split('/');
    $initiative = $initiativeParts[0];

    $newObject = @{
        "$schema" = "https://schema.toncoso.com/AccentureGovernancePlatform/latest/policyObject.json";
        "id" = $id;
        "name" = $name;
        "controls" = $controls;
        "policyObjects" = @{};
    }

    $foundEffect = $obj.properties.policyRule.then.effect;

    switch ($foundEffect.ToLowerInvariant())
    {
        "audit" { $targetNode = "audit" }
        "auditifnotexists" { $targetNode = "audit"}
        "deny" { $targetNode = "deny" }
        "deployifnotexists" { $targetNode = "remediate"}
        "append" { $targetNode = "append" }
        Default {
            LogWarning "Unrecognized effect ($($foundEffect)), defaulting to audit"
            $targetNode = "audit";
        }
    }

    $newObject["policyObjects"][$targetNode] = $obj;

    if($policyOrganization.ContainsKey($initiative) -eq $false)
    {
        $policyOrganization[$initiative] = @();
    }

    $policyOrganization[$initiative] += $newObject;
}

foreach($orgKey in $policyOrganization.Keys)
{
    $initPath = [System.IO.Path]::Combine($StagingOutputDirectory, $orgKey);

    if((Test-Path $initPath) -eq $false)
    {
        LogVerbose "Path '$initPath' does not exist, creating";
        mkdir $initPath | out-Null;
    }

    foreach($obj in $policyOrganization[$orgKey])
    {
        $filePath = [System.IO.Path]::Combine($initPath, "$($obj.Name).json");
        
        $json = $obj | ConvertTo-Json -Depth 100;

        $json | WriteFile -Path $filePath;

        LogVerbose "Wrote policy to '$($filePath)'";
    }
}
