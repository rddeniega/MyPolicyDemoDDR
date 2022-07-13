Param(
    [switch]$SuperVerbose
)

. $PSScriptRoot\Diagnostics.ps1;

Write-Verbose "Logging with `$SuperVerbose = $($SuperVerbose)";

enum LogLevel
{
    Verbose
    Info
    Warning
    Error
    Exception
}

function LogInternal
{
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [LogLevel]$logLevel
    )

    switch($logLevel)
    {
        ([LogLevel]::Verbose) {
            if($DebugPreference -eq "Continue")
            {
                Write-Debug $Message;
            }
            else
            {
                Write-Verbose $Message;    
            }
        }
        ([LogLevel]::Info) {
            Write-Host $Message;
        }
        ([LogLevel]::Warning) {
            Write-Warning $Message;
        }
        ([LogLevel]::Error) {
            Write-Error $Message;
        }
        ([LogLevel]::Exception) {
            Write-Warning "EXCEPTION THROWN: $($Message)";
            throw $message;  
        }
    }
}

function Log 
{
    Param(
		[Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [LogLevel]$LogLevel,

        [Parameter(Mandatory = $true)]
        [bool]$SuperVerboseOutput,

        [object]$AdditionalData
    )

	if($SuperVerbose -ne $true -and $SuperVerboseOutput -ne $true)
	{
        LogInternal -Message $Message -LogLevel $LogLevel;
		return;
	}

    $stack = Get-PSCallStack; 

    [Array]::Reverse($stack);

    $verbose = "/";
    $lastFile = "";

    for ($i = 0; $i -lt $($stack.Count -1); $i++)
    {
        $frame = $stack[$i];
    
        if($frame.Command -eq "<ScriptBlock>" -or $frame.FunctionName -eq "LogError" -or $frame.FunctionName -eq "LogVerbose" -or $frame.FunctionName -eq "LogInfo" -or $frame.FunctionName -eq "LogWarning")
        {
            continue;
        }

        $location = $frame.Location;
        $locationParts = $location.Split(@(":", " "));

        $locationFile = $locationParts[0];
        [Array]::Reverse($locationParts);
        $locationLineNumber = $locationParts[0];

        if($lastFile -ne $locationFile -and $frame.Command -ne $locationFile)
        {
            $section = $frame.Command + ":" + $locationFile + ":" + $locationLineNumber + "/";
        }
        else
        {
            $section = $frame.Command + ":" + $locationLineNumber + "/";
        }

        $lastFile = $locationFile;

        $verbose += $section;
    }

    $verbose += " ";
    
    $verbose += $message;

    if($AdditionalData -ne $null)
    {
        $isException = IsException -InputObject $AdditionalData;
        
        if($isException -eq $true)
        {
            Write-Verbose "Exception";
            $flattenedException = $AdditionalData | FlattenException;
            $additionalDataString = Stringify -NoLogging $flattenedException;
        }
        else
        {
            if($AdditionalData.GetType().FullName -eq 'System.Management.Automation.ErrorRecord')
            {
                $flattenedException =  $AdditionalData.Exception | FlattenException;
                $additionalDataString = Stringify -NoLogging $flattenedException;
            }
            else
            {
                $additionalDataString = $AdditionalData | ConvertTo-Json -Depth 100 | %{ [System.Text.RegularExpressions.Regex]::Unescape($_) };
            }   
        }

        $verbose += "`r`n$($additionalDataString)";
    }

    LogInternal -Message $verbose -LogLevel $LogLevel;
}

function LogVerbose
{
    Param(
		[Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [object]$AdditionalData
    )

    Log -Message $Message -AdditionalData $AdditionalData -LogLevel Verbose -SuperVerboseOutput $false;
}
function LogInfo
{
    Param(
		[Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [object]$AdditionalData
    )

    Log -Message $Message -AdditionalData $AdditionalData -LogLevel Info -SuperVerboseOutput $false;
}
function LogWarning
{
    Param(
		[Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [object]$AdditionalData
    )

    Log -Message $Message -AdditionalData $AdditionalData -LogLevel Warning -SuperVerboseOutput $false;
}
function LogError
{
    Param(
		[Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [object]$AdditionalData
    )

    Log -Message $Message -AdditionalData $AdditionalData -LogLevel Error -SuperVerboseOutput $false;
}

function LogException
{
    Param(
		[Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [object]$AdditionalData
    )

    Log -Message $Message -AdditionalData $AdditionalData -LogLevel Exception -SuperVerboseOutput $true;
}
