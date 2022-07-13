[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true, ParameterSetName = "SubscriptionId")]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, ParameterSetName = "ManagementGroupName")]
    [string]$ManagementGroupName,
        
    [Parameter(Mandatory = $true)]
    [string]$ParametersFile,

    [Parameter()]
    [ValidateSet("AuditOnly", "AuditDeny", "All")]
    [string]$PolicyExportClass = "All",

    [string[]]$PolicyDirectories = $null,
    [string[]]$ControlDirectories = $null,

    [string]$AdditionalControlMappingFile = $null,
    [string]$AdditionalControlPropertiesFile = $null,
    [string]$ExceptionsFile = $null,

    [string[]]$SkipPolicyFolders = @(),
    [string[]]$SkipPolicyNames = @(),

    [Parameter()]
    [string]$PermissionsFile,

    [Switch]$DestroyExistingAssignments,
    [Switch]$SkipServicePrincipalLookup,

    [Switch]$SuperVerbose
)

# Constants 
$const_policySetMetadataFileName = "policySet.metadata.json";

########################################################################
################################ BEGIN #################################
########################################################################

# Load Libraries
. $PSScriptRoot\Common\Deployment.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\Core.Scripts\Retry.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose;

# set export class to ensure policy deployment
# mode matches. 
# 
# This mode will enable a deployment of the class
# such as 'Audit Only'
switch($PolicyExportClass.ToLowerInvariant())
{
    "auditonly" { $maxEffect = 99; }
    "auditdeny" { $maxEffect = 999; }
    default     { $maxEffect = 9999; }
}

# Build Collection and management collections
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

if([string]::IsNullOrEmpty($PermissionsFile))
{
    LogVerbose "No Permission File applied, no additional permissions will be applied";
    $additionalPermissions = $null;
}
else
{
    if((Test-Path $PermissionsFile) -eq $false)
    {
        throw "Cannot find a part of the path '$($PermissionsFile)'. If you wish to not specify a permission file, omit this parameter";
    }

    try
    {
        Logverbose "Attempting to load and parse the permissions file."
        $permissionsContent = Get-Content $PermissionsFile -Raw;
        $additionalPermissions = ParseJson $permissionsContent;

        LogVerbose "Successfully loaded additional permissions file." 
    }
    catch
    {
        LogWarning "An unexpected error has occured when attempting to load the permissions file. Please see the following error for more details.";
        throw $_;
    }
}

# Read Control files and import list into a flat 
# library that will be used for searching to apply
# controls to policies.
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

LogVerbose "Loading Full Parameters File";
$parametersContent = get-item $ParametersFile | get-content -Raw;
$parameters = ParseJson $parametersContent;

# Assignments that have been created.
# This is the result of this script.
$assignments = @();

# Setup arguments based on parameter set
# to obtain assignment and role assignment scope
$scopeArgs = @{};

if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
{
    $scopeArgs["SubscriptionId"] = $SubscriptionId;
}

if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
{
    $scopeArgs["ManagementGroupName"] = $ManagementGroupName;
}

$assignmentScope = GetScopeId @scopeArgs;

# Load, build, and deploy policies and containers.
foreach($policyFolder in $policyFolders)
{
    if($SkipPolicyFoldersSet.Contains($policyFolder.Name) -or $SkipPolicyFolders.Contains($policyFolder.FullName))
    {
        LogVerbose "Skipping all deployments and destructions of objects contained within $($policyFolder.FullName), as it was skip-requested in parameters";
        continue;
    }

    if($DestroyExistingAssignments -eq $true)
    {
        LogInfo "Destructive Delete Enabled - Deleting All scheduled definitions and assignments in scope";
    
        $deletePolicyDefinitions = @();
        $deleteInitiativeDefinitionName = $policyFolder.Name;
        $deleteAssignmentName = CreateAssignmentName -Name $deleteInitiativeDefinitionName;

        $deleteFilter = [System.IO.Path]::Combine($policyFolder.FullName, "*.json");
        $deletePolicyFiles = Get-ChildItem $deleteFilter -Recurse;

        foreach($deletePolicyFile in $deletePolicyFiles)
        {
            LogVerbose "Inspecting '$($deletePolicyFile.Name)' for Policies";
            # Check to see if the policy file is listed by file name in the skip policies
            if($SkipPolicyNamesSet.Contains($deletePolicyFile.Name) -or $SkipPolicyNamesSet.Contains($deletePolicyFile.FullName))
            {
                LogVerbose "Skipping PolicyDefinition by file name '$($deletePolicyFile.FullName)' per parameters";
                continue;
            }


            # Check to see if the policy file in question is the metadata file
            if($deletePolicyFile.Name -eq $const_policySetMetadataFileName)
            {
                LogVerbose "Skipping '$($deletePolicyFile.FullName)' as it is the policySet metadata";
                continue;
            }

            LogVerbose "Building policy object from file '$($deletePolicyFile.FullName)'";

            $policyJson = $deletePolicyFile | Get-Content | ConvertFrom-Json;
            $policyGroup = [PolicyObject]::new($policyJson, $controls, $policyFolder.Name);

            # check if skip policy by name
            if($SkipPolicyNamesSet.Contains($policyGroup.Name))
            {
                LogVerbose "Skipping '$($deletePolicyFile.FullName) by object group name (json) per parameters";
                continue;
            }

            $subPolicies = $policyGroup.GetAllDefinitions();

            foreach($subPolicy in $subPolicies)
            {
                LogVerbose "Scheduling Policy '$($subPolicy.Name)' for deletion";
                $deletePolicyDefinitions += $subPolicy.Name;
            }
        }

        $DeploymentScopeType = $PSCmdlet.ParameterSetName;
        if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
        {
            $DeploymentScopeValue = $SubscriptionId;
        }

        if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
        {
            $DeploymentScopeValue = $ManagementGroupName;
        }
        
        $destructionBlock = {
            $destructiveDeleteArgs = @{
                "AssignmentName" = $deleteAssignmentName;
                "InitiativeDefinitionName" = $deleteInitiativeDefinitionName;
                "PolicyDefinitionNames" = $deletePolicyDefinitions;
                "$($DeploymentScopeType)" = $DeploymentScopeValue;
            };

            LogVerbose "Starting Destructive Delete for policy folder '$($policyFolder.Name)'";
            LogVerbose $(Stringify -InputObject $destructiveDeleteArgs);
            DestructiveDelete @destructiveDeleteArgs;
            LogVerbose "Finished Destructive Delete for policy folder '$($policyFolder.Name)'"
        }

        Retry -OperationName "Deploy/Policy/DestroyExistingAssignments" -ScriptBlock $destructionBlock -TransientErrorDetectionDelegate $Strategy_StandardTransienceDetection;;
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

        if([System.String]::IsNullOrEmpty($AdditionalControlMappingFile) -eq $false)
        {
            # Map any additional controls to this policy Object
            AddAdditionalMappedControlsToPolicyObject -ParsedPolicyObject $policyJson -Controls $controls -AdditionalMapping $additionalControls;
        }

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
            if($SkipPolicyNamesSet.Contains($subPolicy.Name))
            {
                LogVerbose "Skipping '$($subPolicy.Name) by object name (json) per parameters";
                continue;
            }

            $effectValue = GetPolicyEffectClassificationValue -PolicyEffectClassification $subPolicy.PolicyEffectClassification;
            if($effectValue -gt $maxEffect)
            {
                LogWarning "Ignoring Policy '$($subPolicy.Name)' from object '$($policyGroup.Id)' as there is an effect mismatch $($effectValue)/$($maxEffect)";
                continue;
            }

            LogVerbose "Pulling '$($subPolicy.Name)' from object '$($policyGroup.Id)' and creating policy definition.";

            $createPolicyDefinitionArgs = @{
                "Policy" = $subPolicy;
                "Verbose" = $verbosePreference;
            }

            if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
            {
                $createPolicyDefinitionArgs["SubscriptionId"] = $SubscriptionId;
            }
            
            if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
            {
                $createPolicyDefinitionArgs["ManagementGroupName"] = $ManagementGroupName;

            }
            $policyCreationBlock = {
                $azPolicyDefinition = CreatePolicyDefinition @createPolicyDefinitionArgs;

                LogVerbose "Policy Created ('$($azPolicyDefinition.ResourceId)')";

                $azPolicyDefinition;
            }

            $azPolicyDefinition = Retry -OperationName "Deploy/Policy/CreateOrUpdatePolicyDefinition" -ScriptBlock $policyCreationBlock -TransientErrorDetectionDelegate $Strategy_StandardTransienceDetection;

            $policies += $azPolicyDefinition;
        }
    }

    # Policy Set
    
    LogVerbose "Completed indexing of policy folder '$($policyFolder.Name)'";

    if($policies.Count -eq 0)
    {
        LogVerbose "Empty Folder";
        continue;
    }

    $policySetArgs = @{
        "Name" = $policyFolder.Name;
        "Policies" = $policies;
    }

    $metadataFilePath = [System.IO.Path]::Combine($policyFolder.FullName, $const_policySetMetadataFileName);

    if((Test-Path $metadataFilePath) -eq $true)
    {
        LogVerbose "Trying to load policy metadata from '$metadataFilePath'";
        $setMetadata = [PolicySetMetadata]::FromFile($metadataFilePath);

        $policySetArgs["DisplayName"] = $setMetadata.DisplayName;
        $policySetArgs["Description"] = $setMetadata.Description;
    }
    else
    {
        LogWarning "METADATA MISSING - Cannot find a metadata file for initiative folder $($policyFolder.FullName)";
        $setMetadata = [PolicySetMetadata]::FromFile($metadataFilePath);

        $policySetArgs["DisplayName"] = "[SCGL] - METADATA MISSING - $($policyFolder.Name)";
        $policySetArgs["Description"] = "[SCGL] - METADATA MISSING - $($policyFolder.Name)";
    }

    if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
    {
        $policySetArgs["SubscriptionId"] = $SubscriptionId;
    }
    
    if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
    {
        $policySetArgs["ManagementGroupName"] = $ManagementGroupName;
    }

    LogVerbose "Creating PolicySet from $($policies.Count)";
    
    $policySetCreationBlock= {
        [AzurePolicySet]$azPolicySet = CreatePolicySetDefinition @policySetArgs;

        $azPolicySet;
    }

    [AzurePolicySet]$azPolicySet = Retry -OperationName "Deploy/Policy/CreateOrUpdateInitiativeDefinition" -ScriptBlock $policySetCreationBlock -TransientErrorDetectionDelegate $Strategy_StandardTransienceDetection;;

    $extractedParameters = ExtractPolicySetParameters -PolicySet $azPolicySet -GlobalParameters $parameters;

    LogVerbose "Creating Assignment '$($policyFolder.Name)'";

    $assignmentArguments = @{
        "Name" = $policyFolder.Name;
        "Scope" = $assignmentScope;
        "PolicySet" = $azPolicySet;
        "Parameters" = $extractedParameters;
        "IdentityLocation" = "West US 2";
        "DisplayName" = $setMetadata.DisplayName;
        "Description" = $setMetadata.Description;
    }

    if([System.String]::IsNullOrEmpty($ExceptionsFile) -eq $false)
    {
        if($exceptions.ContainsKey($policyFolder.Name))
        {
            $assignmentArguments["notScopes"] = $exceptions[$policyFolder.Name];
        }
    }

    $assignmentCreationBlock = {
        $azAssignment = AssignPolicySet @assignmentArguments;
        $azAssignment;
    }

    $azAssignment = Retry -OperationName "Deploy/Policy/CreateOrUpdateAssignment" -ScriptBlock $assignmentCreationBlock -TransientErrorDetectionDelegate $Strategy_StandardTransienceDetection;;


    if($azAssignment.IdentityObjectId -ne $null)
    {
        LogVerbose "Assignment has created a managed identity, Checking replication and assigning roles";

        if($SkipServicePrincipalLookup -eq $true)
        {
            LogVerbose "Skipping managed identity check sleeping 20 seconds";
            Start-Sleep 40;

        }
        else
        {
            LogVerbose "Performing managed identity check";
            CheckManagedIdentityReplication -PrincipalId $azAssignment.IdentityObjectId | out-null;
        }

        $assignmentBlock = {
            AssignRequiredRoles -Assignment $azAssignment;
        }

        Retry -OperationName "Deploy/Policy/AssignRequiredRoles" -ScriptBlock $assignmentBlock -TransientErrorDetectionDelegate $Strategy_StandardTransienceDetection;

        if($additionalPermissions -eq $null)
        {
            LogVerbose "No additional roles file specified - No Additional Permissions will be assigned."
        }
        else
        {
            $permissionsBlock = {
                AssignAdditionalPermissions -Assignment $azAssignment -AdditionalPermissionsMap $additionalPermissions;
            }

            Retry -OperationName "Deploy/Policy/AssignAdditionalRoles" -ScriptBlock $permissionsBlock -TransientErrorDetectionDelegate $Strategy_StandardTransienceDetection;
        }
    }

    


    LogVerbose "Policy Folder $($policyFolder.Name) has been created";


    $assignments += $azAssignment;
}

return $assignments;

