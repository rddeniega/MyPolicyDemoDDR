[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [object[]]$assignments,

	[string]$DocumentOutputDirectory = $null,
	
	[switch]$SuperVerbose
)

. $PSScriptRoot\Common\Deployment.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\Common\Documentation.Markdown.ps1 -SuperVerbose:$SuperVerbose;

$filesCreated = @();

if($DocumentOutputDirectory -eq $null)
{
	$defaultOutputDirectory = [System.IO.Path]::Combine($PSScriptRoot, "..\", "Documentation");

	LogWarning "Documentation Output Directory is not supplied, using '$defaultOutputDirectory'";

	$DocumentOutputDirectory = $defaultOutputDirectory;
}

if($(Test-Path $DocumentOutputDirectory) -eq $false)
{
	LogVerbose "Documentation Output Directory '$DocumentOutputDirectory' does not exist, creating.";
	
	mkdir $DocumentOutputDirectory | out-null;
}

foreach($assignment in $assignments)
{
	$outputFileName = CreateMarkdownForAssignment -PolicyAssignment $assignment -OutputDirectory $DocumentOutputDirectory;

	LogVerbose "Created Assignment Documentation File '$outputFileName'";

	$filesCreated += $outputFileName;
}

return $filesCreated;
