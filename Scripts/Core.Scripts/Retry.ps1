Param(
    [switch]$SuperVerbose
)

. $PSScriptRoot\Logging.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\Json.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\Diagnostics.ps1;

$const_newlineSplit = [string[]]@("`r`n", "`r", "`n");

$Strategy_AllErrorsAreTransient = {
    Param(
        [Parameter(Mandatory = $True)]
        [Exception]$Exception
    )

    return $true;
}

function Retry
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ScriptBlock]$ScriptBlock,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$OperationName,

        [Parameter()]
        [int]$RetryTimeout = 10000,

        [Parameter()]
        [int]$RetryCount = 10,

        [Parameter()]
        [ScriptBlock]$TransientErrorDetectionDelegate
    )

    LogVerbose "Begin Operation $($OperationName)";

    $previousErrorAction = $global:ErrorActionPreference;
    $global:ErrorActionPreference = "Stop";

    $currentRetryTimeout = $RetryTimeout;   

    $success = $false;

    $lastException = $null;

    for($currentRetryCount = 0; $currentRetryCount -lt $RetryCount; $currentRetryCount++)
    {

        try {
            $result = Invoke-Command -ScriptBlock $ScriptBlock;
            LogVerbose "Operation $($OperationName) Successful";
            $success = $true;

            break;
        }
        catch {
            $lastException = $_.Exception;
            
            $more = "";
            if($_ -ne $null -and $_.Exception -ne $null)
            {
                $flattenedException = FlattenException -Exception $_.Exception;
                $flattenedJson = Stringify -NoLogging $flattenedException;
                $more =  $flattenedJson; 
            }
            else
            {
                $more =  "No additional exception data available."
            }

            
            $outputMessage = "Operation $($OperationName) Failed, sleeping for $currentRetryTimeout milliseconds.$([System.Environment]::NewLine)Operation failed with message '$($Error[0].Exception.Message)'.$([System.Environment]::NewLine)$($more)";
            LogVerbose $outputMessage;

            if($TransientErrorDetectionDelegate -ne $null)
            {
                $transienceResult = Invoke-Command -ScriptBlock $TransientErrorDetectionDelegate -ArgumentList @($_.Exception);

                if($transienceResult -eq $false)
                {
                    LogVerbose "Error '$($_.Exception.GetType().Fullname)' is non-transient, exiting retry loop.";
                    break;
                }
            }
            else
            {
                ####################################################
                # Using warnign to detect issues with 
                # developers forgetting to use the transience 
                # detection. 
                # 
                # This error should **NEVER** appear in production
                # This is an issue with utilizing the retry function 
                # from before transience detection was provided
                Write-Warning "NO TRANSIENCE DETECTION STRATEGY PROVIDED - ALL ERRORS ARE CONSIDERED TRANSIENT!!!";
            }

            Start-Sleep -Milliseconds $currentRetryTimeout;

            $currentRetryTimeout += $RetryTimeout;
        }
    }

    $global:ErrorActionPreference = $previousErrorAction;

    if($success -eq $false)
    {
        # If the retry does not succeed within parameters, LogException
        # the last error;
        throw $lastException;
    }
    else {
        $result;
    }

    LogVerbose "End Operation $($OperationName)";
}


function RunOperation
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ScriptBlock]$ScriptBlock,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$OperationName,

        [Parameter()]
        [int]$RetryTimeout = 10000,

        [Parameter()]
        [int]$RetryCount = 10,

        [Parameter()]
        [ScriptBlock]$TransientErrorDetectionDelegate = $Strategy_AllErrorsAreTransient
    )

    LogVerbose "Begin Operation $($OperationName)";

    $previousErrorAction = $global:ErrorActionPreference;
    $global:ErrorActionPreference = "Stop";


    try {
        $result = Invoke-Command -ScriptBlock $ScriptBlock;

        LogVerbose "Operation $($OperationName) Successful";
        
        
    }
    catch {

        $more = "";
        if($_ -ne $null -and $_.Exception -ne $null)
        {
            $flattenedException = FlattenException -Exception $_.Exception;
            $flattenedJson = Stringify -NoLogging $flattenedException;
            $more =  $flattenedJson; 
        }
        else
        {
            $more =  "No additional exception data available."
        }

        
        $outputMessage = "Operation $($OperationName) Failed, sleeping for $currentRetryTimeout milliseconds.$([System.Environment]::NewLine)Operation failed with message '$($Error[0].Exception.Message)'.$([System.Environment]::NewLine)$($more)";

        throw $_;
    }
    
    $global:ErrorActionPreference = $previousErrorAction;

    LogVerbose "End Operation $($OperationName)";

    $result;
}