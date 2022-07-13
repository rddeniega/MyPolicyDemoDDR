################################################################
# STDIO                                                        #
#                                                              #
# This file contains extensions and wrappers for IO functions. #
#                                                              #
# STDIO is a throwback to the glory days of c++.               #
# #include <stdio.h>                                           #
#                                                              #
# https://en.wikipedia.org/wiki/C_file_input/output            #
################################################################

Param(
    [switch]$SuperVerbose
)

. $PSScriptRoot\Logging.ps1 -SuperVerbose:$SuperVerbose;

function WriteFile
{
    Param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [switch]$Append,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$NoNewline,

        [Parameter()]
        [switch]$NoClobber
    )

    $cmdArgs = @{
        "FilePath" = $Path;
        "Append" = $Append;
        "Force" = $Force;
        "NoClobber" = $NoClobber;
        "NoNewline" = $NoNewline;
        "Verbose" = $VerbosePreference;
    }

    switch($PSVersionTable.PSEdition)
    {
        "Desktop" {
            $cmdArgs["Encoding"] = "default"
        }
        default {
            $cmdArgs["Encoding"] = "utf8NoBOM"
        }
    }

    $InputObject | Out-File @cmdArgs;
}