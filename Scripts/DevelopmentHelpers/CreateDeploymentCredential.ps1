[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $DisplayName,

    [Parameter()]
    [string]
    $IdentifierUri,

    [switch]$SuperVerbose
)

# # # Constants

# Key size in bytes
$const_keySize = 32;

# Import Logging Library
. $PSScriptRoot\..\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose;

if([System.String]::IsNullOrWhiteSpace($IdentifierUri) -eq $true)
{
    $IdentifierUri = "agp-deployment://$([System.Guid]::NewGuid().ToString())";
    LogWarning "IdentifierUri is not specified, using generated uri '$($IdentifierUri)'";
}

LogVerbose "Creating Azure AD Application;"
$application = New-AzADApplication -DisplayName $DisplayName -IdentifierUris $IdentifierUri -AvailableToOtherTenants:$false -Verbose:$VerbosePreference;

LogVerbose "Created Azure AD Application $($application.ApplicationId)";

Logverbose "Creating $($const_keySize * 8) bit credential for Service Principal Secret";

LogVerbose "Instantiating Cryptographic Random Number Generator";
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create();

$bytes = New-Object "System.Byte[]" $const_keySize;

LogVerbose "Generating Key";
$rng.GetBytes($bytes);

$key = [System.Convert]::ToBase64String($bytes);
$date = [System.DateTime]::UtcNow;
$endDate = $date.AddYears(5);

LogVerbose "Assigning password to Application Registration";
$securePassword = ConvertTo-SecureString -String $key -AsPlainText -Force;
$credential = New-AzADAppCredential -ObjectId $application.ObjectId -Password $securePassword -StartDate $date -EndDate $endDate;
LogVerbose "Assigned Application Credential";

LogVerbose "Creating Service Principal";
$servicePrincipal = New-AzADServicePrincipal -ApplicationId $application.ApplicationId
LogVerbose "Created Service principal $($servicePrincipal.id)";

$result = New-Object PSObject;
$result | Add-Member -Type NoteProperty -Name "ApplicationId" -Value $application.ApplicationId;
$result | Add-Member -Type NoteProperty -Name "ApplicationObjectId" -Value $application.ObjectId;
$result | Add-Member -Type NoteProperty -Name "ApplicationSecret" -Value $key;
$result | Add-Member -Type NoteProperty -Name "ApplicationSecretExpiry" -Value $endDate;
$result | Add-Member -Type NoteProperty -Name "ServicePrincipalId" -Value $servicePrincipal.Id;

LogWarning "The ServicePrincipalSecret is not accessible after this instance, please ensure you copy it for deposit into Azure DevOps for Service Connection creation."

return $result;

