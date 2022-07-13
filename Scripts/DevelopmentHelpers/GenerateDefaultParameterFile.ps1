[CmdletBinding()]
Param(        
    [string[]]$ControlDirectories = $null,
    [string[]]$PolicyDirectories = $null,
    [switch]$RequiredParametersOnly,
    
    [Parameter()]
    [ValidateSet("Objects", "JSON")]
    [string]$OutputType = "JSON",

    [Parameter()]
    [string]$CurrentParameterFile,

    [switch]$ExcludeComments,
    [switch]$SuperVerbose
)

# Constants 
$const_policySetMetadataFileName = "policySet.metadata.json";

$const_commentReplaceString = [System.Text.RegularExpressions.Regex]::new('\"__COMMENT\s(?<commentText>.+)\"\:\s+\"\"\,', ([System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::Compiled));


########################################################################
################################ BEGIN #################################
########################################################################

. $PSScriptRoot\..\Core.Scripts\Json.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Common\Deployment.ps1 -SuperVerbose:$SuperVerbose;

LogVerbose "Running from $($PSScriptRoot)";

if($PolicyDirectories -eq $null)
{
    $defaultPolicyDirectory = [System.IO.Path]::Combine($PSScriptRoot, "..\", "Policy");
    
    write-Warning "PolicyDirectories Not Supplied, using '$defaultPolicyDirectory'";

    $PolicyDirectories = @($defaultPolicyDirectory);
}

if($ControlDirectories -eq $null)
{
    $defaultControlsDirectory = [System.IO.Path]::Combine($PSScriptRoot, "..\", "Controls");

    write-Warning "ControlDirectories Not Supplied, using '$defaultControlsDirectory'";

    $ControlDirectories = @($defaultControlsDirectory);
}

if([String]::IsNullOrEmpty($CurrentParameterFile) -eq $false)
{
    Write-Warning "Current Parameter file specified";
    Write-Warning "Output will be a differential between current and new parameters";

    if((Test-Path $CurrentParameterFile) -eq $false)
    {
        throw "Parameter File specified does not exist";
    }
}

$controls = ImportControls -Directories $ControlDirectories;

$policyFolders = @();

# Flatten Policy folders into one list.
# This will allow us to specify multiple independent 
# policy directories to use.
# This does not impact if the default policy directory is used. 
foreach($policyDirectory in $PolicyDirectories)
{
    LogVerbose "Looking in $policyDirectory for Policy Folders";
    $innerDirectories = Get-ChildItem $policyDirectory -Directory;

    foreach($innerDirectory in $innerDirectories)
    {
        LogVerbose "Adding policy folder $($innerDirectory.FullName)";
        $policyFolders += $innerDirectory;
    }
}

$params = New-Object "System.Collections.Generic.Dictionary[string, PolicyParameter]";

$policyCount = 0;
$parameterCount = 0;
$skippedParameterCount = 0;

# Load, build, and deploy policies and containers.
foreach($policyFolder in $policyFolders)
{
    LogVerbose "Indexing into policy folder '$($policyFolder.Name)'";

    if($policyFolder.Name -eq '.vs')
    {
        LogVerbose "Skipping .vs folder as it is for VisualStudio metadata.";
        continue;
    }

    $filter = [System.IO.Path]::Combine($policyFolder.FullName, "*.json");
    $policyFiles = Get-ChildItem $filter -Recurse;

    foreach($policyFile in $policyFiles)
    {
        # Check to see if the policy file in question is the metadata file
        if($policyFile.Name -eq $const_policySetMetadataFileName)
        {
            LogVerbose "Skipping '$($policyFile.FullName)' as it is the policySet metadata";
            continue;
        }
        
        LogVerbose "Building policy object from file '$($policyFile.FullName)'";

        $policyJson = $policyFile | Get-Content | ConvertFrom-Json;
        $policyGroup = [PolicyObject]::new($policyJson, $controls, $policyFolder.Name);

        $subPolicies = $policyGroup.GetAllDefinitions();

        foreach($subPolicy in $subPolicies)
        {
            LogVerbose "Pulling '$($subPolicy.Name)' from object '$($policyGroup.Id)' and creating policy definition.";

            $subPolicyParameters = $subPolicy.GetPolicySetParameterization();

            foreach($subPolicyParameter in $subPolicyParameters)
            {
                if($params.ContainsKey($subPolicyParameter.Name) -eq $false)
                {
                    $params.Add($subPolicyParameter.Name, $subPolicyParameter);
                }
            }

            $policyCount++;
        }
    }
}

$result = New-Object PSCustomObject;

foreach($key in $params.Keys)
{
    $parameter = $params[$key];

    $p = New-Object PSCustomObject;

    if($parameter.Parameter.defaultValue -ne $null)
    {
        if($RequiredParametersOnly -eq $false)
        {
            if($ExcludeComments -eq $false)
            {
                $p | Add-Member -MemberType NoteProperty -Name "__COMMENT Display Name: '$($Parameter.Parameter.metadata.displayName)'" -Value "";
                $p | Add-Member -MemberType NoteProperty -Name "__COMMENT Description: '$($Parameter.Parameter.metadata.description)'" -Value "";
                $p | Add-Member -MemberType NoteProperty -Name "__COMMENT Default Value: '$($Parameter.Parameter.defaultValue)'" -Value "";
                $p | Add-Member -MemberType NoteProperty -Name "__COMMENT Type: '$($Parameter.Parameter.type)'" -Value "";

                if($Parameter.Parameter.allowedValues -ne $null -and $Parameter.Parameter.allowedValues.count -ne 0)
                {
                    $p | Add-Member -MemberType NoteProperty -Name "__COMMENT Allowed Values: $($($Parameter.Parameter.allowedValues) | ConvertTo-Json -Depth 10 -Compress)" -Value "";
                }
    
                if([System.String]::IsNullOrWhiteSpace($Parameter.Parameter.metadata.strongType) -eq $false)
                {
                    $p | Add-Member -MemberType NoteProperty -Name "__COMMENT Strong Type: $($Parameter.Parameter.metadata.strongType)" -Value "";
                }
            }

            $p | Add-Member -MemberType NoteProperty -Name "value" -Value $Parameter.Parameter.defaultValue;

            $parameterCount++;

            $result | Add-Member -MemberType NoteProperty -Name $parameter.Name -Value $p;
        }
        else
        {
            Write-Verbose "Skipping Parameter '$key' as it has a default value ($($Parameter.Parameter.defaultValue))";
            $skippedParameterCount++;
        }
    }
    else
    {
        if($ExcludeComments -eq $false)
        {
            $p | Add-Member -MemberType NoteProperty -Name "__COMMENT Display Name: '$($Parameter.Parameter.metadata.displayName)'" -Value "";
            $p | Add-Member -MemberType NoteProperty -Name "__COMMENT Description: '$($Parameter.Parameter.metadata.description)'" -Value "";
            $p | Add-Member -MemberType NoteProperty -Name "__COMMENT Type: '$($Parameter.Parameter.type)'" -Value "";

            if($Parameter.Parameter.allowedValues -ne $null -and $Parameter.Parameter.allowedValues.count -ne 0)
            {
                $result | Add-Member -MemberType NoteProperty -Name "__COMMENT Allowed Values: $($($Parameter.Parameter.allowedValues) | ConvertTo-Json -Depth 10 -Compress)" -Value "";
            }

            if([System.String]::IsNullOrWhiteSpace($Parameter.Parameter.metadata.strongType) -eq $false)
            {
                $p | Add-Member -MemberType NoteProperty -Name "__COMMENT Strong Type: $($Parameter.Parameter.metadata.strongType)" -Value "";
            }
        }

        $p | Add-Member -MemberType NoteProperty -Name "value" -Value "__REPLACE_WITH_COMMENT__";
        
        $parameterCount++;

        $result | Add-Member -MemberType NoteProperty -Name $parameter.Name -Value $p;
    }
}

if([String]::IsNullOrEmpty($CurrentParameterFile) -eq $false)
{
    Write-Verbose "Reading Current Parameter File";
    $cp = ParseJson $(Get-Content $CurrentParameterFile -Raw);

    foreach($property in $cp.PSObject.Properties)
    {
        if($result.PSObject.Properties[$property.Name] -ne $null)
        {
            Write-Verbose "Found that the existing parameter File contains parameter '$($property.Name)'. This parameter will not be included in the output.";
            $result.PSObject.Properties.Remove($property.Name);
        }
    }
}

if($OutputType.ToLowerInvariant() -eq "json")
{
    $json = Stringify $result;
    $json = $json.Replace('"__REPLACE_WITH_COMMENT__"', "/* INSERT VALUE HERE - THIS PARAMETER IS REQUIRED AND DOES NOT HAVE A DEFAULT VALUE. Without this parameter, this policy will fail to deploy */");
    $json = $json -replace '\"__COMMENT\s(?<commentText>.+)\"\:\s+\"\"\,', '// $1'

    Write-Verbose "Indexed $policyCount policies";
    Write-Verbose "Found $parameterCount parameters";

    if($skippedParameterCount -gt 0)
    {
        Write-Verbose "Skipped $skippedParameterCount parameters with default value due to RequiredParametersOnly switch presence";
    }


    return $json;
}
else
{
    return $result; 
}