Param(
    [Parameter(Mandatory = $true)]
    [string]$ControlId,
    
    [Parameter(Mandatory = $true)]
    [string]$ControlUri,
    
    [Parameter(Mandatory = $true)]
    [string]$DisplayName,
    
    [Parameter(Mandatory = $true)]
    [string]$Description
)

$guid = [System.Guid]::NewGuid().ToString();
[string[]]$splitters = @([Environment]::NewLine);

$jsonBase = @'
{
    "id": "REPLACE_ID",
    "controlId": "REPLACE_CONTROLID",
    "controlUri": "REPLACE_CONTROLURI",
    "displayName": "REPLACE_DISPLAYNAME",
    "description": REPLACE_DESCRIPTION
}
'@;

$descriptionParts = $Description.Split($splitters, [System.StringSplitOptions]::RemoveEmptyEntries);
$descriptionPartsLastIndex = $descriptionParts.Length - 1;

$builder = new-object "System.Text.StringBuilder";
$builder.AppendLine("[") | out-null;

for($i = 0; $i -lt $descriptionParts.Length; $i++)
{
    $builder.Append("`"") | out-null;
    $builder.Append($descriptionParts[$i]) | out-null;
    $builder.Append("`"") | out-null;

    if($i -lt $descriptionPartsLastIndex)
    {
        $builder.AppendLine(",") | out-null;
    }
}

$builder.AppendLine() | out-null;
$builder.Append("]") | out-null;

$result = $jsonBase;
$result = $result.Replace("REPLACE_ID", $guid)
$result = $result.Replace("REPLACE_CONTROLID", $ControlId);
$result = $result.Replace("REPLACE_CONTROLURI", $ControlUri);
$result = $result.Replace("REPLACE_DISPLAYNAME", $DisplayName);
$result = $result.Replace("REPLACE_DESCRIPTION", $builder.ToString());

$result | Set-Clipboard;