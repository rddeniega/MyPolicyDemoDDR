[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [string]$ObjectName,

    [switch]$SuperVerbose
)

. $PSScriptRoot\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose

function AddChildrenToLookup
{
    Param(
        [Parameter(Mandatory = $true)]
        [PSObject]$ManagementGroup,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, string]]$LookupTable
    )

    LogVerbose "Looking at Object '$($ManagementGroup.Name)' which is type '$($ManagementGroup.Type)'";

    $newPath = "$($Path)$($ManagementGroup.Name)/";

    if($ManagementGroup.Children -ne $null -and $ManagementGroup.Children.Count -gt 0)
    {
        LogVerbose "Has $($ManagementGroup.Children.Count) Children";
        
        foreach($child in $ManagementGroup.Children)
        {
            $LookupTable = AddChildrenToLookup -ManagementGroup $child -Path $newPath -LookupTable $LookupTable;
        }
    }

    LogVerbose "Has No Children. Adding to Lookup Table";
    $LookupTable[$managementGroup.Name] = $newPath;
    
    return $LookupTable;
}

$context = Get-AzContext;
$tenantId = $context.Tenant;

LogVerbose "Looking up Management group for tenant $($tenantId)";

$managementGroup = Get-AzManagementGroup -GroupName $tenantId -Expand -Recurse;

LogVerbose "Got ManagementGroup Hierarchy";

$managementGroupsLookup = New-Object 'System.Collections.Generic.Dictionary[string, PSObject]';

LogVerbose "Performing Lookup Population based on Hierarchy."

$managementGroupsLookup = AddChildrenToLookup -ManagementGroup $managementGroup -Path "/" -LookupTable $managementGroupsLookup;

LogVerbose "Created $($managementGroupsLookup.Count) object paths";

LogVerbose "Finding object path for '$($ObjectName)'"

$result = $managementGroupsLookup[$ObjectName].Replace("/$($tenantId)", "")

return $result;