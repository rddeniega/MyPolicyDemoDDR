[CmdletBinding(ConfirmImpact = 'High')]
Param(
    [Parameter(Mandatory = $true, ParameterSetName = "SubscriptionId")]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, ParameterSetName = "ManagementGroupName")]
    [string]$ManagementGroupName,

    [switch]$SuperVerbose
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

$assignments = Get-AzPolicyAssignment -Scope $assignmentScope;

foreach($assignment in $assignments)
{
    Retry -OperationName "Utility/Destroy/RemoveAssignment" -ScriptBlock { Remove-AzPolicyAssignment -Id $assignment.ResourceId; } -RetryTimeout 250 -RetryCount 5;
}

$policySetArgs = @{
    "Verbose" = $VerbosePreference;
}

if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
{
    $policySetArgs["SubscriptionId"] = $SubscriptionId;
}

if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
{
    $policySetArgs["ManagementGroupName"] = $ManagementGroupName;
}


$initiatives = Get-AzPolicySetDefinition @policySetArgs -Custom;

foreach($initiative in $initiatives)
{
    write-verbose $($initiative | ConvertTo-Json);

    Retry -OperationName "Utility/Destroy/RemoveInitiativeDefinition" -ScriptBlock { Remove-AzPolicySetDefinition -Id $initiative.ResourceId -Force -Confirm:$false; } -RetryTimeout 250 -RetryCount 5;
}

$definitions = Get-AzPolicyDefinition @policySetArgs -Custom;

foreach($definition in $definitions)
{
    Retry -OperationName "Utility/Destroy/RemovePolicyDefinition" -ScriptBlock { Remove-AzPolicyDefinition -Id $definition.ResourceId -Force -Confirm:$false; } -RetryTimeout 250 -RetryCount 5;
}

