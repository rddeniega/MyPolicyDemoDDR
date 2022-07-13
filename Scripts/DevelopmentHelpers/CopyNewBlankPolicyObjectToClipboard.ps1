Param(
    [Parameter(Mandatory = $true)]
    [string]$PolicyName
)

$guid = [System.Guid]::NewGuid().ToString();

$jsonBase = @'
{
    "$schema": "https://schema.toncoso.com/6-4-2019/policyObject.json",
    "id": "REPLACE_ID",
    "name": "REPLACE_NAME",
    "controls": [
        "1d364e72-26d9-4731-b308-29fee6910e0b"
    ],
    "policyObjects": {
        "audit" : null,
        "deny" : null,
        "remediate" : null
    }
}
'@;

$result = $jsonBase.Replace("REPLACE_ID", $guid).Replace("REPLACE_NAME", $PolicyName);

$result | Set-Clipboard;