[CmdletBinding()]
Param()

$resourceDictionary = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]';

$subs = Get-AzSubscription;

foreach($subscription in $subs)
{
    Select-AzSubscription -SubscriptionObject $subscription -Verbose:$verbosePreference | out-null;

    $resources = Get-AzResource;

    foreach($resource in $resources)
    {
        if($resourceDictionary.ContainsKey($resource.ResourceType) -eq $false)
        {
            $newList = New-Object 'System.Collections.Generic.List[object]';
            $resourceDictionary.Add($resource.ResourceType, $newList);

            Write-Verbose "Resource type '$($resource.ResourceType)' not seen before, creating new list."
        }

        $resourceDictionary[$resource.ResourceType].Add($resource);

        Write-Verbose "Current Count of '$($resource.ResourceType)' = $($resourceDictionary[$resource.ResourceType].Count)";
    }
}

$r = @();
foreach($key in $resourceDictionary.Keys)
{
    $o = New-Object PSCustomObject;
    $o | Add-Member -Type NoteProperty -Name "ResourceType" -Value $key;
    $o | Add-Member -Type NoteProperty -Name "Count" -Value $resourceDictionary[$key].Count;
    $o; 
}