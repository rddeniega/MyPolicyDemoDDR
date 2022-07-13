Param(
    [switch]$SuperVerbose
)

. $PSScriptRoot\Logging.ps1 -SuperVerbose:$SuperVerbose;

# https://regex101.com/r/0QUKzE/1
$const_jsonParseSingleLineCommentRegex = [System.Text.RegularExpressions.Regex]::new('^\s*\/\/(?<commentText>.*)$', ([System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::Compiled));

# https://regex101.com/r/0QUKzE/2
$const_jsonParseMultiLineCommentRegex = [System.Text.RegularExpressions.Regex]::new('\/\*(?<commentText>.*?)\*\/', ([System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::Compiled));

Function Stringify
{
	Param(
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
		[object]$InputObject,

		[switch]$Minify,
		[switch]$NoLogging
	)

	$typeInfo = $inputObject.GetType();

	if($NoLogging -ne $true)
	{
		LogVerbose "Stringifying and unescaping object of type '$($typeInfo.FullName)'"
	}

	$convertArguments = @{
		"InputObject" = $InputObject;
		"Depth" = 100
	}

	if($Minify -eq $true)
	{
		$convertArguments["Compress"] = $true;
	}

	[string]$result = ConvertTo-Json @convertArguments | %{ [System.Text.RegularExpressions.Regex]::Unescape($_) };

	return $result;
}

Function ParseJson
{
	Param(
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Content
	)

	$Content = $const_jsonParseMultiLineCommentRegex.Replace($Content, "");
	$Content = $const_jsonParseSingleLineCommentRegex.Replace($Content, "");

	$obj = $Content | ConvertFrom-Json;

	return $obj;
}