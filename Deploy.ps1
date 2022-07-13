[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true, ParameterSetName = "SubscriptionId")]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, ParameterSetName = "ManagementGroupName")]
    [string]$ManagementGroupName,

    [Parameter(Mandatory = $false)]
    [string]$TestingSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$TestResultOutputDirectory,

    [Parameter()]
    [string[]]$AdditionalTestingDirectories,

    [Parameter(Mandatory = $true)]
    [ValidateSet('PowerShell', 'KeyVault')]
    [string]$TestingCredentialSource,

    [Parameter(Mandatory = $true)]
    [string]$ParametersFile,

    [Parameter(Mandatory = $true)]
    [string[]]$PolicyDirectories,
    
    [Parameter(Mandatory = $true)]
    [string[]]$ControlDirectories,

    [Parameter(Mandatory = $true)]
    [string]$DocumentationAzureDevOpsOrganization,

    [Parameter(Mandatory = $true)]
    [string]$DocumentationAzureDevOpsProject,

    [Parameter(Mandatory = $true)]
    [string]$DocumentationAzureDevOpsWikiName,

    [Parameter()]
    [string]$DocumentationAccessToken,

    [Parameter()]
    [string]$DocumentationPersonalAccessToken,
    
    [Parameter()]
    [string]$DocumentationKeyVaultName,

    [Parameter()]
    [string]$DocumentationKeyVaultSecretName,

    [Parameter(Mandatory = $true)]
    [string]$DocumentationScopeNickName,

    [Parameter()]
    [string]$AdditionalControlMappingFile = $null,
    
    [Parameter()]
    [string]$AdditionalControlPropertiesFile = $null,

    [Parameter()]
    [string]$ExceptionsFile = $null,

    [Parameter()]
    [string[]]$SkipPolicyFolders = @(),
    
    [Parameter()]
    [string[]]$SkipPolicyNames = @(),

    [Parameter()]
    [ValidateSet("AuditOnly", "AuditDeny", "All")]
    [string]$PolicyExportClass = "All",

    [Parameter()]
    [Switch]$DestroyExistingAssignments = $false,
    
    [Parameter()]
    [Switch]$Authenticate = $false,
    
    [Parameter()]
    [Switch]$SkipServicePrincipalLookup = $false,
    
    [Parameter()]
    [string]$DocumentationOutputDirectory = $null,

     [Parameter()]
    [string]$PermissionsFile,
    
    [Parameter()]
    [Switch]$SuperVerbose
)

DynamicParam {
    if($TestingCredentialSource.ToLowerInvariant() -eq "keyvault")
    {
        $paramAttrib_Type = @{'TypeName'='System.Management.Automation.ParameterAttribute'};
        $attribCollection_Type = @{'TypeName'='System.Collections.ObjectModel.Collection[System.Attribute]'};
        $runtimeParam_Type = @{'TypeName'='System.Management.Automation.RuntimeDefinedParameter'};
        $runtimeParamList_Type = @{'TypeName'='System.Management.Automation.RuntimeDefinedParameterDictionary'};
    
        $paramList = New-Object @runtimeParamList_Type;

        $attrib = New-Object @paramAttrib_Type;
        $attrib.Mandatory = $true;

        $attribCollection = New-Object @attribCollection_Type;
        $attribCollection.Add($attrib);

        $param = New-Object @runtimeParam_Type -ArgumentList "TestingKeyVaultName","String",$attribCollection;
        $paramList.Add("TestingKeyVaultName", $param);

        $param = New-Object @runtimeParam_Type -ArgumentList "TestingAppIdSecretName","String",$attribCollection;
        $paramList.Add("TestingAppIdSecretName", $param);

        $param = New-Object @runtimeParam_Type -ArgumentList "TestingAppSecretSecretName","String",$attribCollection;
        $paramList.Add("TestingAppSecretSecretName", $param);

        return $paramList
    }
}

process
{
    ###################
    # Build integration
    ###################

    if($env:SYSTEM_DEBUG -eq "True" -or $env:SYSTEM_DEBUG -eq "true")
    {
        $SuperVerbose = $true;
    }

    . $PSScriptRoot\Scripts\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose;

    ###################
    # Policy Deployment 
    ###################

    $deployArguments = @{
        "ParametersFile" = $ParametersFile;
        "Verbose" = $VerbosePreference;
        "ErrorAction" = [System.Management.Automation.ActionPreference]::Stop;
        "DestroyExistingAssignments" = $DestroyExistingAssignments;
        "SkipServicePrincipalLookup" = $SkipServicePrincipalLookup;
        "PolicyDirectories" = $PolicyDirectories;
        "SkipPolicyFolders" = $SkipPolicyFolders;
        "SkipPolicyNames" = $SkipPolicyNames;
        "ExceptionsFile" = $ExceptionsFile;
        "PolicyExportClass" = $PolicyExportClass;    
        "AdditionalControlMappingFile" = $AdditionalControlMappingFile;
        "AdditionalControlPropertiesFile" = $AdditionalControlPropertiesFile;
        "PermissionsFile" = $PermissionsFile;
        "SuperVerbose" = $SuperVerbose
    }

    if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
    {
        $deployArguments["SubscriptionId"] = $SubscriptionId; 
    }

    if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
    {
        $deployArguments["ManagementGroupName"] = $ManagementGroupName; # Default for our testing is: 'Toncoso-Policy-Sandbox-AutomationLayer'
    }

    LogVerbose "Running Deployment Script From $PSScriptRoot"

    if([String]::IsNullOrEmpty($DocumentationOutputDirectory) -eq $true)
    {
        $DocumentationOutputDirectory = "C:\t\DocTest\" + [System.DateTime]::UtcNow.ToString("MMddyyyy-HHmmss") + "\";
    }

    if((Test-Path $DocumentationOutputDirectory) -eq $false)
    {
        mkdir $DocumentationOutputDirectory;
    }

    $assignments = $(& $PSScriptRoot\Scripts\Deploy.ps1 @deployArguments);

    #################################
    # Mardown Documentation Rendering 
    #################################

    $markdownCreationArguments = @{
        "DocumentOutputDirectory" = $DocumentationOutputDirectory;
        "Assignments" = $assignments;
        "Verbose" = $VerbosePreference;
        "SuperVerbose" = $SuperVerbose;
    }

    $documentationResult = $(& $PSScriptRoot\Scripts\DocumentAssignmentsToMarkdownFiles.ps1 @markdownCreationArguments);

    #############################
    # Run Unit / Functional Tests
    #############################
        
        Write-Warning "$($TestingCredentialSource) $($PSBoundParameters.TestingKeyVaultName) $($PSBoundParameters.TestingAppIdSecretName) $($PSBoundParameters.TestingAppSecretSecretname)";

    if([System.String]::IsNullOrWhiteSpace($TestingSubscriptionId))
    {
        Write-Warning "TESTING NOT PERFORMED as no testing subscription id is specified";
    }
    else
    {
        $testArguments = @{
            "SubscriptionId" = $TestingSubscriptionId;
            "PolicyDirectories" = $PolicyDirectories;
            "TestResultOutputDirectory" = $TestResultOutputDirectory;
            "SkipPolicyFolders" = $SkipPolicyFolders;
            "SkipPolicyNames" = $SkipPolicyNames;
            "CredentialSource" = $TestingCredentialSource;
            "Verbose" = $VerbosePreference;
            "SuperVerbose" = $SuperVerbose;
        }

        
        if($TestingCredentialSource.ToLowerInvariant() -eq "keyvault")
        {
            $testArguments["TestingKeyVaultName"] = $PSBoundParameters.TestingKeyVaultName;
            $testArguments["TestingAppIdSecretName"] = $PSBoundParameters.TestingAppIdSecretName;
            $testArguments["TestingAppSecretSecretName"] = $PSBoundParameters.TestingAppSecretSecretName;
        }

        if($AdditionalTestingDirectories -ne $null)
        {
            Write-Warning "Additional Testing Directories Supplied. Running These Tests."
            $testArguments["AdditionalTestingDirectories"] = $AdditionalTestingDirectories;
        }

        # $testResults = $(& $PSScriptRoot\test\Framework\RunTests.ps1 @testArguments);
    }
    ##########################
    # Documentation Publishing 
    ##########################

    if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
    {
        $scopeObjectId = $ManagementGroupName;
    }

    if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
    {
        $scopeObjectId = $SubscriptionId;
    }

    $documentationArgs = @{
        "Files" = $documentationResult;
        "Organization" = $DocumentationAzureDevOpsOrganization;
        "Project" = $DocumentationAzureDevOpsProject;
        "WikiName" = $DocumentationAzureDevOpsWikiName;
        "Verbose" = $VerbosePreference;
        "SuperVerbose" = $SuperVerbose;
        "ScopeNickName" = $DocumentationScopeNickName;
    }

    if([System.String]::IsNullOrWhiteSpace($DocumentationAccessToken))
    {
        if([System.String]::IsNullOrWhiteSpace($DocumentationPersonalAccessToken))
        {
            LogVerbose "Using Documentation KeyVault";
            $documentationArgs["AuthenticationVaultName"] = $DocumentationKeyVaultName;
            $documentationArgs["AuthenticationVaultSecretName"] = $DocumentationKeyVaultSecretName;
        }
        else
        {
            LogVerbose "Using Directly Supplied Personal Access Token"
            $documentationArgs["PersonalAccessToken"] = $DocumentationPersonalAccessToken;
        }
    }
    else
    {
        LogVerbose "Using Directly Supplied Bearer Token"
        $documentationArgs["AccessToken"] = $DocumentationAccessToken;
    }

    $documentationDeploymentResult = $(& $PSScriptRoot\Scripts\ADO\UploadPolicyDocumentationToWiki.ps1 @documentationArgs);

    $result = New-Object PSCustomObject;
    $result | Add-Member -Type NoteProperty -Name "Assignments" -Value $assignments;
    $result | Add-Member -Type NoteProperty -Name "Documentation" -Value $documentationResult;
    $result | Add-Member -Type NoteProperty -Name "DocumentationDeployment" -Value $documentationDeploymentResult;
    $result | Add-Member -Type NoteProperty -Name "TestResults" -Value $testResults;
    $result;

}