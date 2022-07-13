$typeException = $(new-object 'System.Exception' 'test').GetType();

Function IsException
{
    Param(
        [Parameter(ValueFromPipeline = $true)]
        [object]$InputObject
    )

    if($InputObject -eq $null)
    {
        return $false;
    }

    return $typeException.IsAssignableFrom($InputObject.GetType());
}

function FlattenException {
    Param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [System.Exception]$Exception,

        [Parameter()]
        [string]$CurrentPath
    )

    Write-Verbose "Start Inspection exception @ $($CurrentPath) - $($Exception.GetType().Fullname)";

    if($Exception -eq $null)
    {
        $ex = New-Object System.ArgumentNullException "Exception";

        throw $ex;
    }

    if([System.String]::IsNullOrEmpty($CurrentPath))
    {
        $CurrentPath = '/';
    }

    $result = @();
    if($Exception.InnerException -ne $null)
    {
        $_result = $Exception.InnerException | FlattenException -CurrentPath ($CurrentPath + "InnerException" + "/");
        $result += $_result;
    }

    if($Exception.InnerExceptions -ne $null -and $Exception.InnerExceptions)
    {
        for($i = 0; $i -lt $Exception.InnerExceptions.Count; $i++)
        {
            $innerException = $Exception.InnerExceptions[$i];
        
            $_result = $innerException | FlattenException -CurrentPath ($CurrentPath + "InnerExceptions[$($i)]" + "/");
            $result += $_result;
        }
    }

    $obj = New-Object PSObject;

    foreach($property in $Exception.PSObject.Properties)
    {
        if($property.Name -eq "InnerException" -or $property.Name -eq "InnerExceptions")
        {
            # Inner Exceptions are handled above
            continue;    
        }

        if($property.Name -eq "TargetSite")
        {
            # Target site is practically useless data 
            # for powershell debugging. We are not debugging
            # the framework itself.
            continue;
        }        

        if($property.Value -ne $null)
        {
            $type = $property.Value.GetType();

            Write-Verbose "Inspecting Exception property @ $($CurrentPath)$($property.Name) - $($type.FullName)";

            if($type.Name -eq "ListDictionaryInternal" -or $type.name -eq "InvocationInfo" -or $type.Name -eq "ErrorRecord")
            {
                Write-Verbose "Found unserializable data @ $($CurrentPath)$($property.Name) ($($type.FullName))"
                # Target site is practically useless data 
                # for powershell debugging. We are not debugging
                # the framework itself.
                continue;
            }

            if($type.FullName -eq "System.RuntimeType" -or $type.FullName -eq "System.Type")
            {
                Write-Verbose "Found that property $($CurrentPath)$($property.Name) is a type, replacing with type name ($($type.FullName))";
                $obj | Add-Member -Type NoteProperty -Name $property.Name -Value $type.FullName;

                continue;
            }

            $propertyJson = $property.Value | ConvertTo-Json -Depth 100;

            Write-Verbose $propertyJson;

            $obj | Add-Member -Type NoteProperty -Name $property.Name -Value $property.Value;
        }
    }

    if($result -ne $null -and $result.Length -ne 0)
    {
        $obj | Add-Member -Type NoteProperty -Name "InnerExceptions" -Value $result;
    }

    return $obj;
}