[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceIdPrefix, 

    [Parameter(Mandatory = $true)]
    [string[]]$PolicyDirectories = $null,

    [Parameter(Mandatory = $true)]
    [string[]]$ControlDirectories = $null,

    [Parameter(Mandatory = $true)]
    [ValidateSet("AuditOnly", "AuditDeny", "All")]
    [string]$PolicyExportClass,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter()]
    [string[]]$SkipPolicyFolders = @(),

    [Parameter()]
    [string[]]$SkipPolicyNames = @(),

    [Switch]$SuperVerbose
)

Function GetPolicyEffectClassificationValue
{
    Param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyEffectClassification
    )

    $lower = $PolicyEffectClassification.ToLowerInvariant();

    switch($lower)
    {
        "audit" { return 10; }
        "auditifnotexists" { return 11; }
        "deny" { return 100; }
        "deployifnotexists" { return 1000; }
        "append" { return 1001; }
        default { return 1002; }

    }
}

# Constants 
$const_policySetMetadataFileName = "policySet.metadata.json";

########################################################################
################################ BEGIN #################################
########################################################################

. $PSScriptRoot\..\Common\Deployment.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Core.Scripts\Retry.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Core.Scripts\stdio.ps1 -SuperVerbose:$SuperVerbose;

if((Test-Path $OutputPath) -eq $false)
{
    throw New-Object 'System.ArgumentNullException' @("OutputPath", "The output path specified must exist before export begins.");
}

switch($PolicyExportClass.ToLowerInvariant())
{
    "auditonly" { $maxEffect = 99; }
    "auditdeny" { $maxEffect = 999; }
    default     { $maxEffect = 9999; }
}

LogVerbose "Maximum Effect Level = $($maxEffect)"

$SkipPolicyFoldersSet = New-Object 'System.Collections.Generic.HashSet[string]';
$SkipPolicyNamesSet = New-Object 'System.Collections.Generic.HashSet[string]';

foreach($skipPolicyFolder in $skipPolicyFolders)
{
    $SkipPolicyFoldersSet.Add($skipPolicyFolder) | out-null;
}

foreach($skipPolicyName in $SkipPolicyNames)
{
    $SkipPolicyNamesSet.Add($skipPolicyName) | out-null;
}


LogVerbose "Running from $($PSScriptRoot)";

if($PolicyDirectories -eq $null)
{
    $defaultPolicyDirectory = [System.IO.Path]::Combine($PSScriptRoot, "..\", "Policy");
    
    LogWarning "PolicyDirectories Not Supplied, using '$defaultPolicyDirectory'";

    $PolicyDirectories = @($defaultPolicyDirectory);
}

if($ControlDirectories -eq $null)
{
    $defaultControlsDirectory = [System.IO.Path]::Combine($PSScriptRoot, "..\", "Controls");

    LogWarning "ControlDirectories Not Supplied, using '$defaultControlsDirectory'";

    $ControlDirectories = @($defaultControlsDirectory);
}

$controls = ImportControls -Directories $ControlDirectories;

if([System.String]::IsNullOrEmpty($AdditionalControlPropertiesFile) -eq $false)
{
    MapAdditionalControlProperties -ControlPropertiesFile $AdditionalControlPropertiesFile -Controls $controls;
}

if([System.String]::IsNullOrEmpty($AdditionalControlMappingFile) -eq $false)
{
    $additionalControls = ParseAdditionalControlMapping -ControlAdditionsFile $AdditionalControlMappingFile;
}

if([System.String]::IsNullOrEmpty($ExceptionsFile) -eq $false)
{
    $exceptions = ParseExceptionsFile -ExceptionsFile $ExceptionsFile;
}

$policyFolders = @();
$totalPolicyCount = 0;
$exportedPolicyCount = 0;

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

# Load, build, and deploy policies and containers.
foreach($policyFolder in $policyFolders)
{
    if($SkipPolicyFoldersSet.Contains($policyFolder.Name) -or $SkipPolicyFolders.Contains($policyFolder.FullName))
    {
        LogVerbose "Skipping all deployments and destructions of objects contained within $($policyFolder.FullName), as it was skip-requested in parameters";
        continue;
    }

    LogVerbose "Indexing into policy folder '$($policyFolder.Name)'";

    $policies = @();

    $filter = [System.IO.Path]::Combine($policyFolder.FullName, "*.json");
    $policyFiles = Get-ChildItem $filter -Recurse;

    foreach($policyFile in $policyFiles)
    {
        # Check to see if the policy file is listed by file name in the skip policies
        if($SkipPolicyNamesSet.Contains($policyFile.Name) -or $SkipPolicyNamesSet.Contains($policyFile.FullName))
        {
            LogVerbose "Skipping PolicyDefinition by file name '$($policyFile.FullName)' per parameters";
            continue;
        }


        # Check to see if the policy file in question is the metadata file
        if($policyFile.Name -eq $const_policySetMetadataFileName)
        {
            LogVerbose "Skipping '$($policyFile.FullName)' as it is the policySet metadata";
            continue;
        }

        LogVerbose "Building policy object from file '$($policyFile.FullName)'";

        $policyJson = $policyFile | Get-Content | ConvertFrom-Json;

        $policyGroup = [PolicyObject]::new($policyJson, $controls, $policyFolder.Name);

        # check if skip policy by name
        if($SkipPolicyNamesSet.Contains($policyGroup.Name))
        {
            LogVerbose "Skipping '$($PolicyFile.FullName) by object group name (json) per parameters";
            continue;
        }

        $subPolicies = $policyGroup.GetAllDefinitions();

        foreach($subPolicy in $subPolicies)
        {    
            $totalPolicyCount++;

            if($SkipPolicyNamesSet.Contains($subPolicy.Name))
            {
                LogVerbose "Skipping '$($subPolicy.Name) by object name (json) per parameters";
                continue;
            }

            $effectValue = GetPolicyEffectClassificationValue -PolicyEffectClassification $subPolicy.PolicyEffectClassification;

            LogVerbose "Pulling '$($subPolicy.Name)' from object '$($policyGroup.Id)' with effect classification value of $($effectValue).";

            if($effectValue -gt $maxEffect)
            {
                LogWarning "Ignoring Policy '$($subPolicy.Name)' from object '$($policyGroup.Id)' as there is an effect mismatch $($effectValue)/$($maxEffect)";
                continue;
            }

            $outputDirectory = [System.IO.Path]::Combine($OutputPath, $policyFolder.Name);

            if((Test-Path $outputDirectory) -eq $false)
            {
                LogVerbose "Output Directory '$($outputDirectory)' does not exist, creating."
                new-item -ItemType Directory -Path $outputDirectory | out-null;
            }

            $fileName = $subPolicy.Name;

            $outputFilePath = [System.IO.Path]::Combine($outputDirectory, "$($fileName).json");

            LogVerbose "Exporting policy '$($subPolicy.Name)' to '$($outputFilePath)'";
            Stringify -InputObject $subPolicy.PolicyObject | WriteFile -Path $outputFilePath -Encoding default -Force;

            $exportedPolicyCount++;
            $assumedResourceId = $ResourceIdPrefix + '/providers/Microsoft.Authorization/policyDefinitions/' + $subPolicy.Name;
            $renderedPolicy = [AzurePolicyDefinition]::new(
                $subPolicy.Name, 
                $assumedResourceId, 
                $subPolicy.Name, 
                'Microsoft.Authorization/policyDefinitions', 
                $null, 
                $subPolicy.PolicyObject, 
                $assumedResourceId,
                $subPolicy);

            $policies += $renderedPolicy;
        }
    }

    $initiative = [PolicySetDefinition]::new($policyFolder.Name, $policies);

    # Policy Set

    if($policies.Count -eq 0)
    {
        LogVerbose "Empty Folder";
        continue;
    }

    $policySetControls = $initiative.GetControls();

	LogVerbose "Found $($policySetControls.Count) controls";

	LogVerbose "PolicySet Description: $policySetDescription";

	$policySetDefinition = Stringify $initiative.GetAzurePolicySet();

	LogVerbose $policySetDefinition;

	$policySetDefinitionParameters = $initiative.GetParameters();

    $outputDirectory = [System.IO.Path]::Combine($OutputPath, $policyFolder.Name);
    $outputDefinitionPath = [System.IO.Path]::Combine($outputDirectory, "initiative.definition.json");
    $outputParametersPath = [System.IO.Path]::Combine($outputDirectory, "initiative.parameters.json");

    LogVerbose "Writing policy set definition for folder '$($policyFolder.Name)' to '$($outputDefinitionPath)'";
    $policySetDefinition | WriteFile -Path $outputDefinitionPath -Force -Encoding UTF-8;

    LogVerbose "Writing policy set parameters for folder '$($policyFolder.Name)' to '$($outputParametersPath)'";
    Stringify $policySetDefinitionParameters | WriteFile -Path $outputParametersPath -Force -Encoding UTF-8;

}