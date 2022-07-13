[CmdletBinding(ConfirmImpact = 'High')]
Param(
    [Parameter(Mandatory = $true, ParameterSetName = "SubscriptionId")]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, ParameterSetName = "ManagementGroupName")]
    [string]$ManagementGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AssignmentName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Json", "Object")]
    [string]$Output,

    [switch]$SuperVerbose,
    [switch]$SkipBuiltIn
)

# Load Scripts
. $PSSCriptRoot\..\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Common\Deployment.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Core.Scripts\Retry.ps1 -SuperVerbose:$SuperVerbose;

$scopeArgs = @{
    "Verbose" = $VerbosePreference;
}

if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
{
    $scopeArgs["SubscriptionId"] = $SubscriptionId;
}

if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
{
    $scopeArgs["ManagementGroupName"] = $ManagementGroupName;
}

$assignmentScope = GetScopeId @scopeArgs;

try 
{
    LogVerbose "Gathering Assignment details for $($AssignmentName) @ $($assignmentScope)"
    $assignment = Get-AzPolicyAssignment -Name $AssignmentName -Scope $assignmentScope -ErrorAction Stop;
    LogVerbose "Found Assignment details for $($AssignmentName) @ $($assignmentScope)"
}
catch
{
    
    if($_.ToString().Contains("PolicyAssignmentNotFound") -eq $true)
    {
        LogWarning "Policy Assignment not found" -AdditionalData $_;
        return;
    }
    else
    {
        LogWarning -Message "Unexpected Exception occured when attempting to get a policy assignment by name" -AdditionalData $_;
        throw $_;
    }
}

if($assignment -eq $null)
{
    LogWarning "Result of getting assignment is NULL - this is unexpected and worrysome. Please investigate.";

    return;
}

$policySetDefinitionId = $assignment.Properties.PolicyDefinitionId;

try
{
    LogVerbose "Gathering Initiative details for '$($policySetDefinitionId)' (Assignment $($AssignmentName) @ $($assignmentScope))"
    $policySet = Get-AzPolicySetDefinition -Id $policySetDefinitionId;
    LogVerbose "Found Initiative details for '$($policySetDefinitionId)' (Assignment $($AssignmentName) @ $($assignmentScope))"
}
catch
{
    if($_.ToString().Contains("PolicyDefinitionSetNotFound") -eq $true)
    {
        LogWarning "Policy Initiative definition not found" -AdditionalData $_;
        return;
    }
    else
    {
        LogWarning -Message "Unexpected Exception occured when attempting to get a policy initiative set by name" -AdditionalData $_;
        throw $_;
    }
}

$policies = @();

foreach($policyDefinition in $policySet.Properties.PolicyDefinitions)
{
    try
    {
        LogVerbose "Gathering Details for Policy Definition: PolicySet '$($policySet.ResourceId)' contains policy definition '$($policyDefinition.policyDefinitionId)'";
        $def = Get-AzPolicyDefinition -Id $policyDefinition.policyDefinitionId;
        LogVerbose "Found details for Policy Definition '$($policyDefinition.policyDefinitionId)'";
    }
    catch
    {
        if($_.ToString().Contains("PolicyDefinitionNotFound") -eq $true)
        {
            LogWarning "Policy Definition not found" -AdditionalData $_;
            return;
        }
        else
        {
            LogWarning -Message "Unexpected Exception occured when attempting to get a policy definition" -AdditionalData $_;
            throw $_;
        }
    }

    if($def.properties.policyType -eq "BuiltIn" -and $SkipBuiltIn -eq $true)
    {
        LogVerbose "Policy $($def.ResourceName) is built in. Not Including";
    }
    else
    {
        $policies += New-Object PSObject -Property @{
            "Id" = $def.ResourceName;
            "ResourceId" = $def.ResourceId;
            "DisplayName" = $def.Properties.DisplayName;
        };
    }
}

$resultProperties = @{
    "Id" = $assignment.ResourceName;
    "ResourceId" = $assignment.ResourceId;
    "DisplayName" = $assignment.Properties.DisplayName;
    "Initiative" = @{
        "Id" = $policySet.ResourceName;
        "ResourceId" = $policySet.ResourceId;
        "DisplayName" = $policySet.Properties.DisplayName;
        "PolicyDefinitions" = $policies;
    }
}

$result = New-Object PSObject -Property $resultProperties;

if($Output.ToLowerInvariant() -eq 'object')
{
    return $result;
}
else
{
    return $result | ConvertTo-Json -Depth 100;
}