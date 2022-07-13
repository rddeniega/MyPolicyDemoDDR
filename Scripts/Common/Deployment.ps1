Param(
    [switch]$SuperVerbose
)

. $PSScriptRoot\..\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Core.Scripts\Retry.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Core.Scripts\Json.ps1 -SuperVerbose:$SuperVerbose;

$hasher = [System.Security.Cryptography.SHA256]::Create();
$random = New-Object 'System.Random';

$Strategy_StandardTransienceDetection = {
    Param($Exception)

	$type = $Exception.GetType();

	switch($type.FullName)
	{
		"System.Management.Automation.ParameterBindingValidationException" {
			return $false;
		}

		"System.Management.Automation.RuntimeException" {
			return $false;
		}
	}

    return $true;

}

enum PolicyDefinitionType 
{
	BuiltIn
	Custom
}

enum TableCellAlignment 
{
	Left
	Center
	Right
}

class PolicySetMetadata
{
	[string]$Description;
	[string]$DisplayName;

	PolicySetMetadata(
		[PSObject]$inputObject
	)
	{
		if($inputObject -eq $null)
		{
			$this.Description = $null;
			$this.DisplayName = $null;
			return;
		}

		if([String]::IsNullOrWhitespace($inputObject.displayName))
		{
			$this.DisplayName = $null;
		}
		else 
		{
			$this.DisplayName =  $inputObject.displayName;
		}

		if([String]::IsNullOrWhitespace($inputObject.description))
		{
			$this.Description = $null;
		}
		else 
		{
			$this.Description = $inputObject.description;
		}
	}

	static [PolicySetMetadata]FromFile([string]$filePath)
	{
		if((Test-Path $filePath) -eq $false)
		{
			LogVerbose "Cannot load metadata, path '$filePath' does not exist";
			return [PolicySetMetadata]::new($null);
		}

		$obj = Get-Item $filePath | Get-Content | ConvertFrom-Json;
		$result = [PolicySetMetadata]::new($obj);

		return $result;
	}
}

class ControlReference 
{
	[string]$Id;
	[string]$Type;
}

class Control 
{
	[string]$Id;
	[string]$ControlFamily;
	[string]$ControlFamilyId;
	[string]$ControlId;
	[string]$ControlUri;
	[string]$DisplayName;
	[string]$Description;
	[string]$Standard;
	[string]$StandardCategory;
	[string]$GrcUri;

	Control(
		[PSObject]$controlObject
	){
		$this.Id = $controlObject.id;
		$this.ControlId = $controlObject.controlId;
		$this.DisplayName = $controlObject.displayName;
		$this.Standard = $controlObject.standard;
		$this.StandardCategory = $controlObject.standardCategory;
		$this.ControlUri = $controlObject.controlUri;
		$this.GrcUri = $controlObject.grcUri;

		# New property, may not be in legacy controls
		if([System.String]::IsNullOrWhitespace($controlObject.family) -eq $false)
		{
			$this.ControlFamily = $controlObject.family;
		}

		if([System.String]::IsNullOrWhitespace($controlObject.familyId) -eq $false)
		{
			$this.ControlFamilyId = $controlObject.familyId;
		}

		if($controlObject.description -ne $null)
		{
			if($controlObject.description.count -gt 0)
			{
				# Should be an array
				$descriptions = $controlObject.description;

				$builder = new-object "System.Text.StringBuilder";

				$lastIndex = $descriptions.count - 1;
				for($i = 0; $i -lt $descriptions.count; $i ++)
				{
					if($i -lt $lastIndex)
					{
						$builder.AppendLine($descriptions[$i]) | out-null;
					}
					else 
					{
						$builder.Append($descriptions[$i]) | Out-Null;	
					}
				}

				$this.Description = $builder.ToString();				
			}
			else
			{
				LogException "Malformed Control - Please ensure json is valid - No Description";
			}
		}
		else
		{
			LogException "Malformed Control - Please ensure json is valid - No Description";
		}
	}
}

class PolicyBase {
	[string]$Name;
	[string]$DisplayName;
	[string]$Description;
}

class AzurePolicyBase : PolicyBase
{
	[string]$ResourceId;
	[string]$ResourceName; 
	[string]$ResourceType;
	[string]$SubscriptionId;
	[object]$Properties;
}

class PolicyParameter 
{
	[string]$Name;
	[PSCustomObject]$Parameter;
}

class PolicyDefinition : PolicyBase
{
	[string]$Effect;
	[object]$Metadata;
	[object]$PolicyRule;
	[string]$PolicyMode;
	[System.Collections.Generic.List[PolicyParameter]]$Parameters;
	[System.Collections.Generic.HashSet[string]]$GlobalParameterNames;
	[System.Collections.Generic.HashSet[string]]$UniversalParameterNames;
	[bool]$IsParameterized;
	[bool]$IsTemplateDeployment;
	[System.Collections.Generic.List[Control]]$Controls;
	[string[]]$RoleDefinitionIds;
	[PolicyDefinitionType]$PolicyType;
	[string]$ExternalDefinitionId;
	hidden [string]$PolicyEffectClassification;
	hidden [string]$PolicySetName;
	hidden [object]$PolicyObject

	PolicyDefinition() {
	
	}

	PolicyDefinition(
		[PSObject]$inputObject,
		[string]$name,
		[bool]$IsTemplateDeployment,
		[System.Collections.Generic.List[Control]]$controls,
		[System.Collections.Generic.HashSet[string]]$globalParameterNames,
		[System.Collections.Generic.HashSet[string]]$universalParameterNames,
		[string]$classification,
		[string]$policySetName
	)
	{
		$this.Name = $name;
		$this.Controls = $controls;
		$this.IsTemplateDeployment = $isTemplateDeployment;
		$this.GlobalParameterNames = $globalParameterNames;
		$this.UniversalParameterNames = $universalParameterNames;
		$this.PolicyEffectClassification = $classification;
		$this.PolicySetName = $policySetName;
		
		$pol = $null;
		if($inputObject.type -ne $null)
		{
			LogVerbose "PolicyObject is a 'built-in' reference (Microsoft Provided)."
			$this.ExternalDefinitionId = $inputObject.definitionId;
			$this.PolicyType = [PolicyDefinitionType]::BuiltIn
			
			LogVerbose "Looking up builtin policy details";
			$externalPolicy = Get-AzPolicyDefinition -Id $this.ExternalDefinitionId;

			$pol = $externalPolicy;
		}
		else
		{
			$this.PolicyType = [PolicyDefinitionType]::Custom;

			if($inputObject.properties -eq $null)
			{
				LogException "The Policy Definition must have a properties element."
			}

			if([string]::IsNullOrWhitespace($inputObject.properties.displayName))
			{
				LogException "The Policy Definition must have a 'properties.displayName' element."
			}

			if([string]::IsNullOrWhitespace($inputObject.properties.description))
			{
				LogException "The Policy Definition must have a 'properties.description' element."
			}

			if($inputObject.properties.metadata -eq $null)
			{
				LogException "Metadata for the object must be specified in 'properties.metadata'";
			}

			if($inputObject.properties.policyRule -eq $null)
			{
				LogException "The Object must have a policy rule. This is the core policy definition. This is specified in 'properties.metadata'";
			}
			
			$pol = $inputObject;
		}

		$this.DisplayName = $pol.properties.displayName;
		$this.Description = $pol.properties.description;
		$this.Metadata = $pol.properties.metadata;
		$this.PolicyRule = $pol.properties.policyRule;

		if([string]::IsNullOrWhitespace($pol.properties.mode))
		{
			LogVerbose "Policy does not contain mode declaration, using default value of 'All'";
			$this.PolicyMode = "All";
		}
		else
		{
			LogVerbose "Policy Mode will be $($pol.properties.mode)";
			$this.PolicyMode = $pol.properties.mode;
		}

		if($pol.properties.parameters -eq $null)
		{
			$pol.properties | Add-Member -Type NoteProperty -Name 'parameters' -Value $(New-Object PSObject);
		}

		if($this.IsTemplateDeployment -eq $true)
		{
			LogVerbose "Policy is Template Deployment. Searching for Role Definition Ids"

			if($pol.properties.policyRule.then -ne $null)
			{
				if($pol.properties.policyRule.then.details -ne $null)
				{
					if($pol.properties.policyRule.then.details.roleDefinitionIds)
					{
						$this.RoleDefinitionIds = @();
						foreach($roleDefinitionId in $pol.properties.policyRule.then.details.roleDefinitionIds)
						{
							LogVerbose "Role Definition found ($($roleDefinitionId))";
						
							$this.RoleDefinitionIds += $roleDefinitionId;
						}
					}
					else
					{
						LogException "The policy definition does not contain 'properties.policyRule.then.details.roleDefinitionIds'";
					}
				}
				else
				{
					LogException "The policy definition does not contain 'properties.policyRule.then.details'";
				}
			}
			else
			{
				LogException "The Policy definition does not contain a 'then' clause. (properties.policyRule.then)";
			}
		}

		if($pol.properties.policyRule.then -ne $null)
		{
			if($pol.properties.policyRule.then.effect -ne $null)
			{
				$this.Effect = $pol.properties.policyRule.then.effect;
			}
			else
			{
				LogException "Policy Rule is missing an Effect. This policy rule will fail validation."
			}
		}
		else
		{
			LogException "The Policy definition does not contain a 'then' clause. (properties.policyRule.then)";
		}

		$this.IsParameterized = $true;
		$this.Parameters = New-Object "System.Collections.Generic.List[PolicyParameter]";

		$foundEffectParameter = $false;

		foreach($parameter in $pol.properties.parameters.PSObject.Properties)
		{
			if($parameter.Name -eq "effect")
			{
				$foundEffectParameter = $true;
			}

			LogVerbose "Found new Parameter '$parameter.Name'";
			$newParameter = [PolicyParameter]::new();
			$newParameter.Name = $parameter.Name;
			$newParameter.Parameter = $parameter.Value;

			$this.Parameters.Add($newParameter);
		}

		if($foundEffectParameter -eq $false)
		{
			if($this.PolicyType -eq [PolicyDefinitionType]::Custom)
			{
				LogVerbose "Effect Parameter Not Found - Adding";

				$paramObject = New-Object PSCustomObject;

				# Set Type field = string
				$paramObject | Add-Member -Type NoteProperty -Name "type" -Value "String";

				$paramMetadataObject = New-Object PSCustomObject;
				$paramMetadataObject | Add-Member -Type NoteProperty -Name "description" -Value "Enable or disable the execution of the policy. Enabling the Policy is specifing the expected effect (i.e. 'append' or 'deployIfNotExists'). 'disabled' will publish the policy and include it as a member of the policy set, but it will affect any resources or compliance reporting.";
				$paramMetadataObject | Add-Member -Type NoteProperty -Name "displayName" -Value "$($this.Name) > Effect";
				
				# Add Metadata to parameter
				$paramObject | Add-Member -Type NoteProperty -Name "metadata" -Value $paramMetadataObject;

				$allowedValueTypes = @($this.PolicyEffectClassification, "disabled");
				
				
				if($classification.ToLowerInvariant() -eq "audit")
				{
					$allowedValueTypes += "auditIfNotExists";
					$defaultValueOrigin = $pol.properties.policyRule.then.effect;
				}
				else
				{
					$defaultValueOrigin = $this.PolicyEffectClassification;
				}

				# Ensure that the defaultValue casing is correct
				# This allows control authors to write "audit" or "audit"
				# Or if they are really Creative "AuDiT" like they 
				# are from the 90s on AIM
				$defaultValue = $null;
				switch($defaultValueOrigin.ToLowerInvariant())
				{
					"audit" {
						$defaultValue = "audit";
						break;
					}
					"auditifnotexists" {
						$defaultValue = "auditIfNotExists";
						break;
					}
					"append" {
						$defaultValue = "append";
						break;
					}
					"deny" {
						$defaultValue = "deny";
						break;
					}
					"deployifnotexists" {
						$defaultValue = "deployIfNotExists";
						break;
					}
					"modify" {
						$defaultValue = "modify";
						break;
					}
					"disabled" {
						$defaultValue = "disabled";
						break;
					}
					Default {
						LogVerbose "Unexpected value for the default value pulled from the policy '$($defaultValueOrigin)'";
						$defaultValue = "disabled"
					}
				}

				# Add the default value computed above.
				$paramObject | Add-Member -Type NoteProperty -Name "defaultValue" -Value $defaultValue;

				$paramObject | Add-Member -Type NoteProperty -Name "allowedValues" -Value $allowedValueTypes;

				$effectParameter = [PolicyParameter]::new();
				$effectParameter.Name = "effect";
				$effectParameter.Parameter = $paramObject;

				$this.Parameters.Add($effectParameter);

				# The policy given may not have a parameter member. Ensure that the member is added.
				if($pol.properties.PSObject.Properties["parameters"] -eq $null)
				{
					LogVerbose "Parameters field Missing from Original Policy object, adding";
					$pol.properties | Add-Member -Type NoteProperty -Name "parameters" -value $(New-Object PSObject);
				}

				$pol.properties.parameters | Add-Member -Type NoteProperty -Name "effect" -Value $paramObject;

				# force effect to be a parameter
				$pol.properties.policyRule.then.effect = "[parameters('effect')]"
			}
		}
		
		$this.PolicyObject = $pol;
	}

	[string]GetPolicySetParameterName([string]$localParameterName)
	{
		$setName = [System.Text.RegularExpressions.Regex]::Replace($this.PolicySetName, "[^a-zA-Z0-9_]", "_");

		if($this.UniversalParameterNames.Contains($localParameterName) -eq $true)
		{
			LogVerbose "Found that '$localParameterName' is a Universal Parameter, which is expected to be present across initiatives";
			$parameterSetParameterName = $localParameterName;
		}
		elseif($this.GlobalParameterNames.Contains($localParameterName) -eq $true)
		{
			LogVerbose "Found that '$localParameterName' is in the global list of parameters, not transforming name";
			$parameterSetParameterName = $setName + "_" + $localParameterName;
		}
		else
		{
			$parameterSetParameterName = $setName + "_" + $this.Name + "_" + $localParameterName;
		}

		return $parameterSetParameterName;
	}

	[PolicyParameter[]]GetPolicySetParameterization()
	{
		if($this.IsParameterized -eq $false)
		{
			return $null;
		}

		$outputParameters = @();

		foreach($parameter in $this.Parameters)
		{
			$parameterObject = new-Object PSCustomObject;
			$parameterObject | Add-Member -Type NoteProperty -Name "type" -Value $parameter.Parameter.type;
			$parameterObject | Add-Member -Type NoteProperty -Name "metadata" -Value $parameter.Parameter.metadata;

			if($parameter.Parameter.defaultValue -ne $null)
			{
				$parameterObject | Add-Member -Type NoteProperty -Name "defaultValue" -Value $parameter.Parameter.defaultValue;
			}

			if($parameter.Parameter.allowedValues -ne $null)
			{
				$parameterObject | Add-Member -Type NoteProperty -Name "allowedValues" -Value $parameter.Parameter.allowedValues;
			}

			$parameterSetParameterName = $this.GetPolicySetParameterName($parameter.Name);
			
			$p = [PolicyParameter]::new();
			$p.Name = $parameterSetParameterName;
			$p.Parameter = $parameterObject;

			$outputParameters += $p;
		}

		return $outputParameters;
	}

	[PSCustomObject]GetParameters()
	{
		if($this.IsParameterized -eq $false)
		{
			return $null;
		}

		$outputParameters = new-object PSCustomObject;

		foreach($parameter in $this.Parameters)
		{
			$outputParameters | Add-Member -Type NoteProperty -Name $parameter.Name -Value $parameter.Parameter;
		}

		return $outputParameters;
	}

	[PSCustomObject]GetPolicySetValueParameterization()
	{
		if($this.IsParameterized -eq $false)
		{
			return $null;
		}

		$parametersObject = New-Object PSCustomObject;

		foreach($parameter in $this.Parameters)
		{
			$parameterSetParameterName = $this.GetPolicySetParameterName($parameter.Name);
			$parameterizedValue = "[parameters('$($parameterSetParameterName)')]";

			$parameterValueObject = new-Object PSCustomObject;
			$parameterValueObject | Add-Member -Type NoteProperty -Name "value" -Value $parameterizedValue;
			
			$parametersObject | Add-Member -Type NoteProperty -Name  $parameter.Name -Value $parameterValueObject;
		}

		return $parametersObject;
	}

	[string[]]GetParameterNames()
	{
		$result = @();

		foreach($parameter in $this.Parameters)
		{
			$result += $parameter.Name;
		}

		return $result;
	}

	[string[]]GetPolicySetParameterNames() 
	{
		$result = @();

		foreach($parameter in $this.Parameters)
		{
			$result += $this.GetPolicySetParameterName($parameter.Name);
		}

		return $result;
	}
}

class PolicyObject
{
	[string]$Id;
	[string]$Name;
	[System.Collections.Generic.List[Control]]$Controls;
	[PolicyDefinition]$AuditPolicy;
	[PolicyDefinition]$AppendPolicy;
	[PolicyDefinition]$DenyPolicy;
	[PolicyDefinition]$RemediatePolicy;
	[PolicyDefinition]$ModifyPolicy;
	[PolicyDefinition]$GuestConfigurationPrerequisites;

	PolicyObject(
		[PSObject]$inputObject,
		[System.Collections.Generic.Dictionary[string, Control]]$controlLibrary,
		[string]$policySetName
	){
		if([String]::IsNullOrWhitespace("name"))
		{
			LogException "Name for policy must be supplied";
		}

		if($inputObject.id -eq $null)
		{
			LogException "No 'id' element found on the input object";
		}

		if($inputObject.controls -eq $null)
		{
			LogException "No 'controls' elemet found on the input object";
		}

		if($inputObject.controls.Count -eq 0)
		{
			LogWarning "No control references have been defined for the input object";
		}

		if($inputObject.policyObjects -eq $null)
		{
			LogException "No 'policyObjects' element found on the input object";
		}

		$this.Id = $inputObject.id;
		$this.Name = $inputObject.name;

		# Set the name to the name of the file that created
		# this object but strip out the .json
		$this.Controls = New-Object 'System.Collections.Generic.List[Control]';

		foreach($controlId in $inputObject.controls)
		{
			if($controlLibrary.ContainsKey($controlId) -eq $false)
			{
				LogWarning "$($this.Name) ($($this.Id)) No control with id '$controlid' exists in the supplied controls. Please ensure that this control has been defined in one of the control library files.";
				continue;
			}

			$this.Controls.Add($controlLibrary[$controlId]);
		}

		$globalParameterNames = New-Object "System.Collections.Generic.HashSet[string]";

		if($inputObject.globalParameterNames -ne $null)
		{
			LogVerbose "This Policy Object has global ParameterNames";
			foreach($globalParameterName in $inputObject.globalParameterNames)
			{
				LogVerbose "Adding '$globalParameterName' to the list of global parameters";
				$globalParameterNames.Add($globalParameterName);
			}
		}

		$universalParameterNames = New-Object "System.Collections.Generic.HashSet[string]";

		if($inputObject.universalParameterNames -ne $null)
		{
			LogVerbose "This Policy Object has Universal ParameterNames";
			foreach($universalParameterName in $inputObject.universalParameterNames)
			{
				LogVerbose "Adding '$universalParameterName' to the list of Universal parameters";
				$universalParameterNames.Add($universalParameterName);
			}
		}

		$hasAnyPolicies = $false;
		if($inputObject.policyObjects.audit -ne $null)
		{
			$this.AuditPolicy = [PolicyDefinition]::new($inputObject.policyObjects.audit, $this.Name + "_audit", $false, $this.Controls, $globalParameterNames, $universalParameterNames, "audit", $policySetName);
			$hasAnyPolicies = $true;
		}

		if($inputObject.policyObjects.append -ne $null)
		{
			$this.AppendPolicy = [PolicyDefinition]::new($inputObject.policyObjects.append, $this.Name + "_append", $false, $this.Controls, $globalParameterNames, $universalParameterNames, "append", $policySetName);
			$hasAnyPolicies = $true;
		}

		if($inputObject.policyObjects.deny -ne $null)
		{
			$this.DenyPolicy = [PolicyDefinition]::new($inputObject.policyObjects.deny, $this.Name + "_deny", $false, $this.Controls, $globalParameterNames, $universalParameterNames, "deny", $policySetName);
			$hasAnyPolicies = $true;
		}

		if($inputObject.policyObjects.remediate -ne $null)
		{
			$this.RemediatePolicy = [PolicyDefinition]::new($inputObject.policyObjects.remediate, $this.Name + "_remediate", $true, $this.Controls, $globalParameterNames, $universalParameterNames, "deployIfNotExists", $policySetName);
			$hasAnyPolicies = $true;
		}

		if($inputObject.policyObjects.modify -ne $null)
		{
			$this.ModifyPolicy = [PolicyDefinition]::new($inputObject.policyObjects.modify, $this.Name + "_modify", $true, $this.Controls, $globalParameterNames, $universalParameterNames, "modify", $policySetName);
			$hasAnyPolicies = $true;
		}

		if($inputObject.policyObjects.guestConfigurationPrerequisites -ne $null)
		{
			$this.GuestConfigurationPrerequisites = [PolicyDefinition]::new($inputObject.policyObjects.guestConfigurationPrerequisites, $this.Name + "_gcPreReq", $true, $this.Controls,  $globalParameterNames, $universalParameterNames, "deployIfNotExists", $policySetName);
			$hasAnyPolicies = $true;
		}
	}

	[PolicyDefinition[]]GetAllDefinitions()
	{
		$result = @();

		if($this.AuditPolicy -ne $null)
		{
			$result += $this.AuditPolicy;
		}

		if($this.AppendPolicy -ne $null)
		{
			$result += $this.AppendPolicy;
		}

		if($this.DenyPolicy -ne $null)
		{
			$result += $this.DenyPolicy;
		}

		if($this.RemediatePolicy -ne $null)
		{
			$result += $this.RemediatePolicy;
		}

		if($this.ModifyPolicy -ne $null)
		{
			$result += $this.ModifyPolicy;
		}

		if($this.GuestConfigurationPrerequisites -ne $null)
		{
			$result += $this.GuestConfigurationPrerequisites;
		}

		return $result;
	}
}

class AzurePolicyDefinition : AzurePolicyBase
{

	[string]$PolicyDefinitionId;
	[bool]$IsParameterized;
	[PolicyDefinition]$Source;

	AzurePolicyDefinition($createdPolicyObject, $policyDefinition){ 
		$this.Name = $createdPolicyObject.Name;
		$this.ResourceId = $createdPolicyObject.ResourceId;
		$this.ResourceName = $createdPolicyObject.ResourceName;
		$this.ResourceType = $createdPolicyObject.ResourceType;
		$this.SubscriptionId = $createdPolicyObject.SubscriptionId;
		$this.Properties = $createdPolicyObject.Properties;
		$this.PolicyDefinitionId = $createdPolicyObject.PolicyDefinitionId;
		$this.Source = $policyDefinition;
	}
	AzurePolicyDefinition($name, $resourceId, $ResourceName, $ResourceType, $SubscriptionId, $Properties, $PolicyDefinitionId, $policyObject)
	{
		$this.Name = $Name;
		$this.ResourceId = $ResourceId;
		$this.ResourceName = $ResourceName;
		$this.ResourceType = $ResourceType;
		$this.SubscriptionId = $SubscriptionId;
		$this.Properties = $Properties;
		$this.PolicyDefinitionId = $PolicyDefinitionId;
		$this.Source = $policyObject;
	}
}

class AzurePolicySet : AzurePolicyBase 
{
	[PolicySetDefinition]$Source;
	[string]$PolicySetDefinitionId;
	[bool]$RequiresManagedIdentity;
	[System.Collections.Generic.HashSet[string]]$RoleDefinitionIds;
	[PSCustomObject]$PolicySetResult;
	[string[]]$ParameterNames;

	AzurePolicySet(
		[PolicySetDefinition]$source,
		[PSCustomObject]$policySetResult
	) {
		if($source -eq $null)
		{
			LogException "The source Policy set must not be null";
		}

		if($policySetResult -eq $null)
		{
			LogException "The policy set result must not be null"
		}

		$this.Source = $source;
		$this.Name = $policySetResult.Name;
		$this.ResourceId = $policySetResult.ResourceId;
		$this.ResourceName = $policySetResult.ResourceName;
		$this.ResourceType = $policySetResult.ResourceType;
		$this.SubscriptionId = $policySetResult.SubscriptionId;
		$this.Properties = $policySetResult.Properties;
		$this.PolicySetDefinitionId = $policySetResult.PolicySetDefinitionId;
		$this.RoleDefinitionIds = New-Object 'System.Collections.Generic.HashSet[string]';
		$this.RequiresManagedIdentity = $false;
		$this.PolicySetResult = $policySetResult;

		$this.ParameterNames = $this.Source.GetParameterNames();

		foreach($policyDefinition in $source.Policies)
		{
			if($policyDefinition.Source.IsTemplateDeployment)
			{
				LogVerbose "found Managed identity";
				$this.RequiresManagedIdentity = $true;

				foreach($roleDefinitionId in $policyDefinition.Source.RoleDefinitionIds)
				{
					LogVerbose "adding '$roleDefinitionId' to set list";

					$this.RoleDefinitionIds.Add($roleDefinitionId);
				}
			}
		}
	}

    [Control[]]GetControls()
    {
        $controls = $this.Source.GetControls();

        return $controls;
    }

	[PolicyParameter[]]GetParameterList()
	{
		$result = $this.Source.GetParameterList();

		return $result;
	}
}

class AzurePolicyAssignmentParameterPair
{
	[string]$ParameterName;
	[string]$ParameterValue;

	AzurePolicyAssignmentParameterPair(
		[string]$name,
		[PSCustomObject]$value
	)
	{
		$this.ParameterName = $name;
		
		if($value.Value -ne $null)
		{
			if($value.Value.GetType().FullName -eq "System.String")
			{
				$this.ParameterValue = $value.Value;
			}
			else 
			{
				$val = Stringify -InputObject $value.Value -Minify;
				$this.ParameterValue = $val;
			}
		}
	}


}

class AzurePolicyAssignment : AzurePolicyBase
{
    [AzurePolicySet]$Source;
    [PSCustomObject]$AssignmentResult;
    [string]$IdentityObjectId;
    [System.Collections.Generic.HashSet[string]]$RoleDefinitionIds;
	[string]$Scope;
	[AzurePolicyAssignmentParameterPair[]]$ParameterValues;
	[string]$AssignmentMoniker;

    AzurePolicyAssignment(
	    [AzurePolicySet]$source,
	    [PSCustomObject]$assignment,
        [string]$scope,
		[string]$assignmentMoniker
	) {
		if($source -eq $null)
		{
			LogException "The source Policy set must not be null";
		}

		if($assignment -eq $null)
		{
			LogException "The policy set result must not be null"
		}

		$this.Source = $source;
		$this.Name = $assignment.Name;
		$this.ResourceId = $assignment.ResourceId;
		$this.ResourceName = $assignment.ResourceName;
		$this.ResourceType = $assignment.ResourceType;
		$this.SubscriptionId = $assignment.SubscriptionId;
		$this.Properties = $assignment.Properties;
        $this.RoleDefinitionIds = $this.Source.RoleDefinitionIds;
        $this.Scope = $scope;
		$this.AssignmentMoniker = $assignmentMoniker; 

		# $this.PolicySetDefinitionId = $policySetResult.PolicySetDefinitionId;
		$this.AssignmentResult = $assignment;

        if($assignment.Identity -ne $null)
        {
            if($assignment.Identity.principalId -ne $null)
            {
                $this.IdentityObjectId = $assignment.Identity.principalId;

                LogVerbose "Principal '$($assignment.Identity.tenantId)/$($this.IdentityObjectId)' created";
            } 
        }
	}

    [Control[]]GetControls()
    {
        $controls = $this.Source.GetControls();

        return $controls;
    }
}

class PolicySetDefinition : PolicyBase
{
	[AzurePolicyDefinition[]]$Policies;

	PolicySetDefinition(
		[string]$name,
		[AzurePolicyDefinition[]]$policies
	){
		LogVerbose "Creating AzurePolicySet object with $($policies.Count) policies";

		if([string]::IsNullOrWhitespace($name))
		{
			LogException "The policy Set Definition must have a name";
		}

		if($policies -eq $null -or $policies.Count -eq 0)
		{
			LogException "The Policies to define the set must not be null or empty"
		}

		$this.Name = $name;
		$this.Policies = $policies;
	}

	[Control[]]GetControls()
	{
		$dictionary = new-object "System.Collections.Generic.Dictionary[string, Control]";
	
		foreach($policy in $this.Policies)
		{
			LogVerbose "Looking at policy '$($policy.Source.Name)'";

			if($policy.Source.Controls -eq $null -or $policy.Source.Controls.Count -eq 0)
			{
				LogVerbose "No controls found on policy";
			}
			else
			{
				foreach($control in $policy.Source.Controls)
				{
					LogVerbose "Found Control id '$($control.Id)' in policy '$($policy.Source.Name)'";
					if($dictionary.ContainsKey($control.Id) -eq $false)
					{
						$dictionary[$control.Id] = $control;
					}
				}
			}
		}

		[Control[]]$result = @();
		
		foreach($key in $dictionary.Keys)
		{
			$result += $dictionary[$key];
		}
		
		return $result;
	}

	[PSCustomObject]GetParameters()
	{
		LogVerbose "Getting Parameters";

		$obj = new-Object PSCustomObject;
		$hasParameters = $false;
		
		foreach($policy in $this.Policies)
		{
			$parameters = $policy.Source.GetPolicySetParameterization();

			if($parameters -ne $null -and $parameters.Count -gt 0)
			{
				foreach($parameter in $parameters)
				{
					$obj | Add-Member -Type NoteProperty -Name $parameter.Name -Value $parameter.Parameter -Force;
					$hasParameters = $true;	
				}
			}
		}

		if($hasParameters -eq $false)
		{
			return $null;
		}

		return $obj;
	}

	[PolicyParameter[]]GetParameterList()
	{
		LogVerbose "Generating ParameterList";

		$dictionary = new-object "System.Collections.Generic.Dictionary[string,PolicyParameter]";

		foreach($policy in $this.Policies)
		{
			$parameters = $policy.Source.GetPolicySetParameterization();

			foreach($parameter in $parameters)
			{
				if($dictionary.ContainsKey($parameter.Name) -eq $false)
				{
					$dictionary.Add($parameter.Name,$parameter);
				}
			}
		}

		$result = @();

		foreach($key in $dictionary.Keys)
		{
			$result += $dictionary[$key];
		}

		return $result;
	}

	[PSCustomObject[]]GetAzurePolicySet()
	{
		LogVerbose "Begin Generation of AzurePolicySet ($($this.Policies.Count) Policies)";

		$policiesOutput = @();
		foreach($policy in $this.Policies)
		{
			LogVerbose "Generating object for Policy Resource Id '$($policy.PolicyDefinitionId)'";

			$obj = new-object PSCustomObject;
			$obj | Add-Member -Type NoteProperty -Name "policyDefinitionId" -Value $policy.PolicyDefinitionId;
			
			$parameters = $policy.Source.GetPolicySetValueParameterization();

			if($parameters -ne $null)
			{
				$obj | Add-Member -Type NoteProperty -Name "parameters" -Value $parameters;
			}

			$policiesOutput += $obj;
		}
		
		return $policiesOutput;
	}

	[string[]]GetParameterNames()
	{
		LogVerbose "Getting ParameterNames ('GetParameterNames')";

		$result = @();

		$uniqueParameterNames = new-object 'System.Collections.Generic.HashSet[string]';

		foreach($policy in $this.Policies)
		{
			LogVerbose "Getting ParameterNames for policy '$($policy.Name)'";

			$policyParameters = $policy.Source.GetPolicySetParameterNames();

			if($policyParameters -ne $null)
			{
				foreach($policySetParameterName in $policyParameters)
				{
					LogVerbose "Found ParameterName '$policySetParameterName'";
					$uniqueParameterNames.Add($policySetParameterName);
				}
			}
			else
			{
				LogVerbose "No parameterNames for '$($policy.Name)'"
			}
		}

		foreach($p in $uniqueParameterNames)
		{
			$result += $p;
		}

		return $result;
	}
}

Function MapAndReturnDesiredParameter
{
    param(
        [string]$SuppliedParameter,
        [string[]]$AllowedValueParameters
        )
    
    if ($($AllowedValueParameters -ne $null) -and $($AllowedValueParameters.Count -gt 0))
    {
        foreach($AllowedValue in $AllowedValueParameters)
        {
            if(($SuppliedParameter.ToLowerInvariant() -eq $AllowedValue.ToLowerInvariant()))
            {
                return $AllowedValue
            }
        }
    }
    else
    {
        return $SuppliedParameter
    }
}

function ImportControls
{
	Param(
		[string[]]$Directories
	)

	$controls = new-object "System.Collections.Generic.Dictionary[string, Control]";

	LogVerbose "Importing Control Files";

	$controlFiles = @();
	
	foreach($directory in $Directories)
	{
		$directoryInfo = Get-Item $directory;

		LogVerbose "Looking in Directory $($directoryInfo.FullName) for control files";

		Push-Location $directoryInfo.FullName;

		$filter = "*.json";

		$directoryFiles = Get-ChildItem $filter -Recurse;

		Pop-Location;

		foreach($directoryFile in $directoryFiles)
		{
			LogVerbose "Found control file $($directoryFile.FullName)";

			$controlFiles += $directoryFile;
		}
	}

	foreach($controlFileInfo in $controlFiles)
	{
		LogVerbose "Getting content for $($controlFileInfo.FullName)";

		# Get the file content
		$content = $controlFileInfo | Get-Content;

		# parse the file content into an object.
		$controlSet = $content | ConvertFrom-Json;

		LogVerbose "Performing File Validation"
		
		if($controlSet.standard -eq $null)
		{
			LogException "$($controlFileInfo.FullName) is an invalid controls file, no Standard is specified";
		}

		if($controlSet.controls -eq $null)
		{
			LogException "$($controlFileInfo.FullName) is an invalid controls file, no controls section is specified";
		}

		if($controlSet.controls.count -eq 0)
		{
			LogWarning "$($controlFileInfo.FullName) is empty and will not contribute controls";
		}



		foreach($control in $controlSet.controls)
		{
			if($controls.ContainsKey($control.id))
			{
				LogException "$($controlFileInfo.FullName) is an invalid controls file, found control without an 'id' property. This property is used to link controls to policies";
			}

			$control | add-member -type NoteProperty -name "standard" -value $controlSet.standard;
			$control | add-member -type NoteProperty -name "standardCategory" -value $controlSet.standardCategory;

			$controlObj = [Control]::new($control);

			LogVerbose "Adding '$($control.standard)' control '$($control.controlId)' '$($control.displayName)' to available controls ($($control.id))";

			$controls.Add($control.id, $controlObj);
		}
	}

	LogVerbose "Imported $($controls.Count) controls";

	return $controls;
}

function MapAdditionalControlProperties
{
	Param(
		[Parameter(Mandatory = $true)]
		[string]$ControlPropertiesFile,

		[Parameter(Mandatory = $true)]
		[System.Collections.Generic.Dictionary[string, Control]]$Controls
	)

	if((Test-Path $ControlPropertiesFile) -eq $false)
	{
		LogException "The file '$ControlPropertiesFile' does not exist and cannot be imported. Please check your deployment configuration";
	}

	$content = Get-Content $ControlPropertiesFile;
	$mapping = $content | ConvertFrom-Json;

	if($mapping.controls -eq $null)
	{
		LogException "Additional Control Mapping file does not contain required element '/controls'";
	}

	if($mapping.controls.Count -eq 0)
	{
		LogWarning "Additional Control Mapping File contains no addiontal controls. Please add mappings or check your configuration. This message should be unexpected if additional mappings are specified";
	}

	# Set type for parse
	$guid = [System.Guid]::Empty;

	foreach($mapping in $mapping.controls)
	{
		if([System.String]::IsNullOrWhitespace($mapping.id) -eq $true)
		{
			LogException "Invalid identifier in a control mapping (null or empty) id '/controls[*]/id'";
		}	

		if([System.Guid]::TryParse($mapping.id, [ref]$guid) -eq $false)
		{
			LogException "Invalid Guid for control Id";
		}

		if($Controls.ContainsKey($mapping.id) -eq $false)
		{
			LogWarning "Mapping with id '$($mapping.id)' does not map to a currently imported control. Please ensure that you are importing the expected control libraries. No changes have been made";

			# skip this mapping 
			# this is a plausible condition
			continue;
		}

		# Get all mapping properties with the exception of 
		# the control ID.
		# We do not wish to import this.
		$mappingProperties = $mapping.PSObject.Properties | ?{ $_ -ne 'id' };

		foreach($property in $mappingProperties)
		{
			if($Controls[$mapping.id].PSObject.Properties[$property.Name])
			{
				LogVerbose "Overwriting Property name '$($property.Name)' on control '$($mapping.id)'";

				$Controls[$mapping.id].PSObject.Properties[$property.Name].Value = $property.Value;
			}
			else {
				LogVerbose "Adding property '$($property.Name)' to control '$($mapping.id)'. This property does not exist on the control";

				$controls[$mapping.id] | Add-Member -Type NoteProperty -Name $property.Name -Value $property.Value;
			}
		}
	}
}

function AddAdditionalMappedControlsToPolicyObject
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[PSCustomObject]$ParsedPolicyObject,

		[Parameter(Mandatory = $true)]
		[System.Collections.Generic.Dictionary[string, Control]]$Controls,

		[Parameter(Mandatory = $true)]
		[System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]$AdditionalMapping
	)
	
	if($AdditionalMapping.ContainsKey($ParsedPolicyObject.id) -eq $false)
	{
		LogVerbose "No additional Mappings found for $($ParsedPolicyObject.id)";
		return;
	}

	[System.Collections.Generic.List[string]]$mapping = $AdditionalMapping[$ParsedPolicyObject.id];
	
	foreach($controlMapping in $mapping)
	{
		$ParsedPolicyObject.controls += $controlMapping;
	}
}

function ParseAdditionalControlMapping
{
	Param(
		[Parameter(Mandatory = $true)]
		[string]$ControlAdditionsFile
	)

	if((Test-Path $ControlAdditionsFile) -eq $false)
	{
		LogException "The file '$ControlAdditionsFile' does not exist and cannot be imported. Please check your deployment configuration";
	}

	$mappings = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]';

	$content = Get-Content $ControlAdditionsFile -Raw;
	$json = $content | ConvertFrom-Json;

	if($json.mappings -eq $null)
	{
		LogException "The '/mappings' element is missing from the control additions file";
	}

	foreach($mapping in $json.mappings)
	{
		if($mapping.policyObjectId -eq $null)
		{
			LogException "missing or null element '/mappings[*]/policyObjectId";
		}

		if($mapping.controlId -eq $null)
		{
			LogException "missing or null element '/mappings[*]/controlId";
		}

		if($mappings.ContainsKey($mapping.policyObjectId) -eq $false)
		{
			$newList = New-Object 'System.Collections.Generic.List[string]';
			$newList.Add($mapping.controlId)

			$mappings[$mapping.PolicyObjectId] = $newList;
		}
		else
		{
			$mappings[$mapping.PolicyObjectId].Add($mapping.controlId);	
		}
	}

	return $mappings;
}

function ParseExceptionsFile
{
	[CmdletBinding()]
	param (
		[Parameter()]
		[string]$ExceptionsFile
	)

	if((Test-Path $ExceptionsFile) -eq $false)
	{
		LogException "The file '$($ExceptionsFile)' cannot be found."
	}

	$content = Get-Content $ExceptionsFile -Raw;
	$json = $content | ConvertFrom-Json;

	if($json.exceptions -eq $null)
	{
		LogException "Exceptions file is missing the element '/exceptions'";
	}

	$mappings = New-Object 'System.Collections.Generic.Dictionary[string, string[]]';

	foreach($property in $json.exceptions.PSObject.Properties)
	{
		if($mappings.ContainsKey($property.Name))
		{
			LogException "Duplicate Exception list detected for '$($property.Name)'"
		}

		$mappings[$property.Name] = [string[]]$property.Value;
	}

	return $mappings;
}

function RenderControlsDescriptionPartial 
{
	Param(
		[System.Collections.Generic.IEnumerable[Control]]$Controls
	)

	LogVerbose "Building Text for $($Controls.Count) controls."

	$builder = new-Object System.Text.StringBuilder;
		
	$builder.Append("   Impacted Controls: [") | Out-Null;

	for($i = 0; $i -lt $Controls.Count; $i++)
	{
		$control = $Controls[$i];

		$builder.Append($control.StandardCategory) | Out-Null;
		$builder.Append(" / ") | Out-Null;
		$builder.Append($control.Standard) | Out-Null;
		$builder.Append(" / ") | Out-Null;
		$builder.Append($control.ControlId) | Out-Null;

		if($i -ne ($Controls.Count -1))
		{
			$builder.Append(', ') | out-null;
		}
	}

	$builder.Append(']') | out-null;

	return $builder.ToString();
}

function RenderPolicyDescription
{
	Param (
		[PolicyDefinition]$Policy
	)

	LogVerbose "Generating Description for policy '$($Policy.Name)'";

	if($Policy.Controls.Count -gt 0)
	{
		LogVerbose "Policy has controls, building description";

		$controlsPartial = RenderControlsDescriptionPartial -Controls $Policy.Controls -Verbose:$verbosePreference;

		[string]$description = $Policy.Description + $controlsPartial;

		return $description;
	}
	else
	{
		LogVerbose "Policy has no controls. using module provided description with no editing";

		return $Policy.Description;
	}
}

Function CreatePolicyDefinition
{
	Param (
		[Parameter(Mandatory = $true, ParameterSetName = "SubscriptionScope")]
		[string]$SubscriptionId,

		[Parameter(Mandatory = $true, ParameterSetName = "ManagementGroupScope")]
		[string]$ManagementGroupName,

		[Parameter(Mandatory = $true)]
		[PolicyDefinition]$Policy
	)

	LogVerbose "Begin Creating Azure Policy Definition";

	LogVerbose "Policy Type: $($Policy.PolicyType)"

	if($Policy.PolicyType -eq [PolicyDefinitionType]::BuiltIn)
	{
		LogVerbose "Builtin Policy"
		$def = Get-AzPolicyDefinition -Id $Policy.ExternalDefinitionId;

		LogVerbose "Policy Parameterization: $($Policy.IsParameterized)";
		
		$azurePolicyDefinition = [AzurePolicyDefinition]::new($def, $Policy);
	}
	else
	{
		LogVerbose "Custom Policy"

		$policyRule = Stringify $Policy.PolicyRule;
		$policyMetadata = Stringify $Policy.Metadata;
		$policyDescription = RenderPolicyDescription -Policy $Policy;

		$arguments = @{
			# required parameters first
			"Name" = $Policy.Name;
			"Policy" = $policyRule;

			# optional parameters
			"DisplayName" = $Policy.DisplayName;
			"Description" = $policyDescription;
			"Metadata" = $policyMetadata;
			"Verbose" = $verbosePreference;
			"Mode" = $Policy.PolicyMode;
		};

		$getArguments = @{
			"Name" = $Policy.Name;
		}

		# Check if parameters 
		if($policy.IsParameterized -eq $true)
		{
			LogVerbose "Policy is parameterized, adding parameters to definition";
			$policyParameters = Stringify $Policy.GetParameters();

			# LogVerbose $policyParameters;

			$arguments["Parameter"] = $policyParameters;
		}

		# Check Scope
		if($PSCmdlet.ParameterSetName -eq "SubscriptionScope")
		{
			LogVerbose "Executing against the SubscriptionScope '$($SubscriptionId)'";

			$arguments["SubscriptionId"] = $SubscriptionId;
			$getArguments["SubscriptionId"] = $SubscriptionId;
		}

		if($PSCmdlet.ParameterSetName -eq "ManagementGroupScope")
		{
			LogVerbose "Executing against the Management Group Scope '$($ManagementGroupName)'";

			$arguments["ManagementGroupName"] = $ManagementGroupName;
			$getArguments["ManagementGroupName"] = $ManagementGroupName;
		}

        # Check for existing definition to prevent collisions due to parameter differences.
        $existingDefinition = Get-AzPolicyDefinition @getArguments -ErrorAction SilentlyContinue
        if($existingDefinition -ne $null)
        {
            LogVerbose "WARNING: Policy Definition [$($arguments["Name"])] already exists. Skipping to prevent collisions."
            $azurePolicyDefinition = [AzurePolicyDefinition]::new($existingDefinition, $Policy);
        }
        else
        {
		    $createdPolicyDefinition = New-AzPolicyDefinition @arguments;
            $azurePolicyDefinition = [AzurePolicyDefinition]::new($createdPolicyDefinition, $Policy);
        }
	}

	return $azurePolicyDefinition;
}

Function CreatePolicySetDefinition 
{
	Param (
		[Parameter(Mandatory = $true, ParameterSetName = "SubscriptionScope")]
		[string]$SubscriptionId,

		[Parameter(Mandatory = $true, ParameterSetName = "ManagementGroupScope")]
		[string]$ManagementGroupName,

		[Parameter(Mandatory = $true)]
		[AzurePolicyDefinition[]]$Policies,

		[Parameter(Mandatory = $true)]
		[string]$Name,

		[string]$DisplayName = $null,
		[string]$Description = $null
	)

	[PolicySetDefinition]$policySet = [PolicySetDefinition]::new($Name, $Policies);

	$policySetControls = $policySet.GetControls();

	LogVerbose "Found $($policySetControls.Count) controls";

	LogVerbose "PolicySet Description: $policySetDescription";

	$policySetDefinition = Stringify $policySet.GetAzurePolicySet();

	LogVerbose $policySetDefinition;

	$policySetDefinitionParameters = $policySet.GetParameters();

	$arguments = @{
		"Name" = $Name;
		"PolicyDefinition" = $policySetDefinition;
		"Verbose" = $verbosePreference;
	}

	# Try and use Display Name for better Readability
	if([String]::IsNullOrWhitespace($DisplayName))
	{
		LogVerbose "DisplayName not provided, using short name";
		$arguments["DisplayName"] = $Name;
		$policySet.DisplayName = $Name;
	}
	else 
	{
		$arguments["DisplayName"] = $DisplayName;
		$policySet.DisplayName = $DisplayName;	
	}

	$arguments["Description"] = $Description;	
	$policySet.Description = $Description;

	if($policySetDefinitionParameters -ne $null)
	{
		$setParameters = Stringify $policySetDefinitionParameters;
		
		$arguments["Parameter"] = $setParameters;
	}

	# Check Scope
	if($PSCmdlet.ParameterSetName -eq "SubscriptionScope")
	{
		LogVerbose "Executing against the SubscriptionScope '$($SubscriptionId)'";

		$arguments["SubscriptionId"] = $SubscriptionId;
	}

	if($PSCmdlet.ParameterSetName -eq "ManagementGroupScope")
	{
		LogVerbose "Executing against the Management Group Scope '$($ManagementGroupName)'";

		$arguments["ManagementGroupName"] = $ManagementGroupName;
	}

	$policyResult = New-AzPolicySetDefinition @arguments;

	$set = [AzurePolicySet]::new($policySet, $policyResult);

	return $set;
}

Function GetScopeId 
{
	Param(
		[Parameter(Mandatory = $true, ParameterSetName = "ResourceGroup")]
		[Parameter(Mandatory = $true, ParameterSetName = "SubscriptionId")]
		[string]$SubscriptionId,

		[Parameter(Mandatory = $true, ParameterSetName = "ResourceGroup")]
		[string]$ResourceGroupName,

		[Parameter(Mandatory = $true, ParameterSetName = "ManagementGroupName")]
		[string]$ManagementGroupName
	)

	if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
	{
		return "/subscriptions/" + $SubscriptionId;
	}

	if($PSCmdlet.ParameterSetName -eq "ResourceGroup")
	{
		return "/subscriptions/$($SubscriptionId)/resourceGroups/$($ResourceGroupName)"
	}

	if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
	{
		return "/providers/Microsoft.Management/managementGroups/$($ManagementGroupName)";
	}
}

Function ExtractPolicySetParameters
{
	Param(
		[Parameter(Mandatory = $true)]
		[AzurePolicySet]$PolicySet,

		[Parameter(Mandatory = $true)]
		[PSCustomObject]$GlobalParameters
	)

	$filteredParameters = New-Object PSCustomObject;

	LogVerbose "Getting Policy Parameter List";

	$policySetParameters  = $PolicySet.GetParameterList();

	LogVerbose "Extracting '$($policySetParameters.Count)' parameters"

	foreach($p in $policySetParameters)
	{
		LogVerbose "Attempting Extraction of parameter '$($p.Name)'";
		$paramObject = $GlobalParameters.PSObject.Properties[$p.Name].Value;

        if($paramObject -ne $null)
        {
        	LogVerbose "Found parameter '$($p.Name)' in supplied parameters, utilizing value supplied.";
            
			# Removed due to bug
			# $paramObject = MapAndReturnDesiredParameter -SuppliedParameter$GlobalParameters.PSObject.Properties[$p.Name].Value -AllowedParameters $p.Parameter.allowedValues

            $filteredParameters | add-Member -Type NoteProperty -Name $p.Name -Value $paramObject;
        }
        else
        {
            LogVerbose "Parameter '$($p.Name)' Missing from supplied parameters, checking for default value";
			
			if($p.Parameter.defaultValue -ne $null)
			{
				LogWarning "Found Default value in policy definition for '$($p.Name)'. Since this value was not supplied in the global parameter list, the default value will be used. This may cause unexpected behavior"
			
				$newObj = new-object PSCustomObject;
				$newObj | Add-Member -Type NoteProperty -Name "value" -Value $p.Parameter.defaultValue;

				$filteredParameters | Add-Member -Type NoteProperty -Name $p.Name -Value $newObj;
			}
        }
	}

	return $filteredParameters;
}

Function ValidateParametersExist
{
	Param(
		[Parameter(Mandatory = $true)]
		[string[]]$RequiredParameters,

		[Parameter(Mandatory = $true)]
		[PSCustomObject]$Parameters
	)

	$parameterProperties = $Parameters.PSObject.Properties | select Name;

	LogVerbose "Checking to ensure that $($parameterProperties.Count) exist within the supplied parameters file.";

	$missingParameters = @();
	$isMissingParameters = $false;

	foreach($param in $RequiredParameters)
	{
		LogVerbose "Looking for parameter '$($param)'"
		$found = $false;

		foreach($property in $parameterProperties)
		{
			if($param -eq $property.Name)
			{
				LogVerbose "Found parameter '$($param)' in supplied parameter set."
				$found = $true;
			}
		}

		if($found -eq $false)
		{
			$isMissingParameters = $true;
			$missingParameters += $param;
			LogWarning  "Missing expected parameter '$($param)'";
		}
	}

	if($isMissingParameters -eq $true)
	{
		$mp = Stringify $missingParameters -Minify;
		LogException "Missing $($missingParameters.Count) parameters: $($mp);"
	}
}

Function DestructiveDelete
{
	Param (
		[Parameter(Mandatory = $true)]
		[string]$AssignmentName,
		
		[Parameter(Mandatory = $true)]
		[string]$InitiativeDefinitionName,
		
		[Parameter(Mandatory = $true)]
		[string[]]$PolicyDefinitionNames,

		[Parameter(Mandatory = $true, ParameterSetName = "SubscriptionId")]
		[string]$SubscriptionId,

		[Parameter(Mandatory = $true, ParameterSetName = "ManagementGroupName")]
		[string]$ManagementGroupName        
	)

	LogWarning "REMOVING POLICY ASSIGNMENT AND CHILDREN (v2): $($AssignmentName) @ $($Scope)"

	$scopeArgs = @{};
	if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
	{
		$scopeArgs["SubscriptionId"] = $SubscriptionId;
	}

	if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
	{
		$scopeArgs["ManagementGroupName"] = $ManagementGroupName;
	}

	$scope = GetScopeId @scopeArgs;

	try 
	{
		LogVerbose "Gathering Assignment details for $($AssignmentName) @ $($scope)"
		$assignment = Get-AzPolicyAssignment -Name $AssignmentName -Scope $scope -ErrorAction Stop;
		LogVerbose "Found Assignment details for $($AssignmentName) @ $($scope)"

		LogVerbose $($assignment | Stringify);
	}
	catch
	{
		
		if($_.ToString().Contains("PolicyAssignmentNotFound") -eq $true)
		{
			LogWarning "Policy Assignment not found for deletion, skipping" -AdditionalData $_;
			return;
		}
		else
		{
			LogWarning -Message "Unexpected Exception occured when attempting to get a policy assignment by name" -AdditionalData $_;
			throw $_;
		}
	}

	if($assignment -eq $null)
	{
		LogVerbose "Result of getting assignment is NULL - this is unexpected and worrysome. Please investigate.";
	}
	else
	{
		try
		{
			try 
			{
				$existingRoleAssignments = Get-AzRoleAssignment -Scope $scope -ObjectId $assignment.Identity.principalId -Verbose:$VerbosePreference;
				LogVerbose "Removing $($existingRoleAssignments.count) role assigments at scope '$($scope)' for principal '$($assignment.Identity.principalId)'";

				$existingRoleAssignments | Remove-AzRoleAssignment -Verbose:$verbosePreference;
				
				LogVerbose "Finished removing $($existingRoleAssignments.count) role assigments at scope '$($scope)' for principal '$($assignment.Identity.principalId)'";

			}
			catch
			{
				LogVerbose $(FlattenException -Exception $_.Exception | Stringify);
				LogVerbose "Failed to remove role assigments at scope '$($scope)' for principal '$($assignment.Identity.principalId)'";
			}

			LogVerbose "Remove Policy assignment '$($assignment.ResourceId)'";
			$removeAssignmentResult = Remove-AzPolicyAssignment -Id $assignment.ResourceId -Confirm:$false -Verbose:$VerbsosePreference;
			LogInfo "RemoveAssignment '$($assignment.ResourceId)' Result = $removeAssignmentResult";		

			try 
			{
				$elderRoleAssignments = Get-AzRoleAssignment -Scope $scope -Verbose:$VerbosePreference | ?{ $_.ObjectType -eq "Unknown" };
				LogVerbose "Removing $($elderRoleAssignments.count) elder role assigments at scope '$($scope)' for previous policy deployments";

				$elderRoleAssignments | Remove-AzRoleAssignment -Verbose:$verbosePreference;
				
				LogVerbose "Finished removing $($elderRoleAssignments.count) elder role assigments at scope '$($scope)' for previous policy deployments'";
			}
			catch
			{
				LogVerbose $(FlattenException -Exception $_.Exception | Stringify);
				LogVerbose "Failed to remove elder role assigments at scope '$($scope)'";
			}	
		}
		catch
		{
			LogWarning -Message "Unexpected Exception occured when attempting to DELETE a policy assignment" -AdditionalData $_;
			throw $_;	
		}
	}

	$skipPolicySet = $false;

	try
	{
		$getPolicySetDefinitionArgs = @{
			"Name" = $InitiativeDefinitionName;
		}

		if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
		{
			$getPolicySetDefinitionArgs["SubscriptionId"] = $SubscriptionId;
		}

		if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
		{
			$getPolicySetDefinitionArgs["ManagementGroupName"] = $ManagementGroupName;
		}

		LogVerbose "Gathering Initiative details for '$($policySetDefinitionId)' (Initiative $($InitiativeDefinitionName) @ $($Scope))"
		$policySet = Get-AzPolicySetDefinition @getPolicySetDefinitionArgs;
		LogVerbose "Found Initiative details for '$($policySetDefinitionId)' (Initiative $($InitiativeDefinitionName) @ $($Scope))"
	}
	catch
	{
		if($_.ToString().Contains("PolicyDefinitionSetNotFound") -eq $true)
		{
			LogVerbose "Policy Initiative definition not found for deletion, skipping" -AdditionalData $_;
			$skipPolicySet = $true;
		}
		else
		{
			LogWarning -Message "Unexpected Exception occured when attempting to get a policy initiative set by name" -AdditionalData $_;
			throw $_;
		}
	}

	if($skipPolicySet -eq $false)
	{
		try 
		{
			LogVerbose "Remove policy set definition '$($policySet.ResourceId)'";
			$removeInitiativeResult = Remove-AzPolicySetDefinition -Id $policySet.ResourceId -Confirm:$false -Verbose:$VerbsosePreference -Force;
			LogInfo "RemoveInitiative '$($policySet.ResourceId)' Result = $removeInitiativeResult"
		}
		catch
		{
			LogWarning -Message "Unexpected Exception occured when attempting to DELETE a policy initiative definition" -AdditionalData $_;
			throw $_;			
		}
	}

	foreach($policyDefinitionName in $PolicyDefinitionNames)
	{
		try
		{
			$getPolicyDefinitionArgs = @{
				"Name" = $policyDefinitionName;
			}

			if($PSCmdlet.ParameterSetName -eq "SubscriptionId")
			{
				$getPolicyDefinitionArgs["SubscriptionId"] = $SubscriptionId;
			}

			if($PSCmdlet.ParameterSetName -eq "ManagementGroupName")
			{
				$getPolicyDefinitionArgs["ManagementGroupName"] = $ManagementGroupName;
			}

			LogVerbose "Gathering Details for Policy Definition (Policy $($policyDefinitionName) @ $($scope))";
			$def = Get-AzPolicyDefinition @getPolicyDefinitionArgs;
			LogVerbose "Found details for Policy Definition (Policy $($policyDefinitionName) @ $($scope))";
		}
		catch
		{
			if($_.ToString().Contains("PolicyDefinitionNotFound") -eq $true)
			{
				LogVerbose "Policy Definition '$($policyDefinitionName)' not found for deletion" -AdditionalData $_;
				continue;
			}
			else
			{
				LogWarning -Message "Unexpected Exception occured when attempting to get a policy definition" -AdditionalData $_;
				throw $_;
			}
		}

		if($def.properties.policyType -eq "BuiltIn")
		{
			LogVerbose "Policy is built in, will not attempt delete.";
		}
		else
		{
			try 
			{
				LogVerbose "Deleting Custom Policy definition '$($def.ResourceId)'";
				$removeDefinitionResult = Remove-AzPolicyDefinition -Id $def.ResourceId -Confirm:$false -Verbose:$VerbosePreference -Force;
				LogVerbose "Remove Definition $($policyDefinitionName) @ $($Scope) Successful"
			}
			catch
			{
				LogWarning -Message "Unexpected Exception occured when attempting to DELETE a policy definition" -AdditionalData $_;
				throw $_;	
			}

			if($removeDefinitionResult -ne $true)
			{
				LogException "Failed to Remove the policy definition '$($policyDefinition.ResourceId)'";
			}
		}
	}
}


Function DeletePolicyAssignmentAndChildren 
{
	Param (
		[Parameter(Mandatory = $true)]
		[string]$Name,

		[Parameter(Mandatory = $true)]
		[string]$Scope
	)

	$Name = CreateAssignmentName -Name $Name;

	LogWarning "REMOVING POLICY ASSIGNMENT AND CHILDREN: $($Name) @ $($Scope)"

	try 
	{
		LogVerbose "Gathering Assignment details for $($Name) @ $($Scope)"
		$assignment = Get-AzPolicyAssignment -Name $Name -Scope $Scope -ErrorAction Stop;
		LogVerbose "Found Assignment details for $($Name) @ $($Scope)"
	}
	catch
	{
		
		if($_.ToString().Contains("PolicyAssignmentNotFound") -eq $true)
		{
			LogWarning "Policy Assignment not found for deletion, skipping" -AdditionalData $_;
			return;
		}
		else
		{
			LogWarning -Message "Unexpected Exception occured when attempting to get a policy assignment by name" -AdditionalData $_;
			throw $_;
		}
	}

	if($assignment -eq $null)
	{
		LogWarning "Result of getting assignment is NULL - this is unexpected and worrysome. Please investigate.";

		return;
	}

	$policySetDefinitionId = $assignment.Properties.PolicyDefinitionId;

	try
	{
		LogVerbose "Gathering Initiative details for '$($policySetDefinitionId)' (Assignment $($Name) @ $($Scope))"
		$policySet = Get-AzPolicySetDefinition -Id $policySetDefinitionId;
		LogVerbose "Found Initiative details for '$($policySetDefinitionId)' (Assignment $($Name) @ $($Scope))"
	}
	catch
	{
		if($_.ToString().Contains("PolicyDefinitionSetNotFound") -eq $true)
		{
			LogWarning "Policy Initiative definition not found for deletion, skipping" -AdditionalData $_;
			return;
		}
		else
		{
			LogWarning -Message "Unexpected Exception occured when attempting to get a policy initiative set by name" -AdditionalData $_;
			throw $_;
		}
	}

	try
	{
		LogVerbose "Remove Policy assignment '$($assignment.ResourceId)'";
		$removeAssignmentResult = Remove-AzPolicyAssignment -Id $assignment.ResourceId -Confirm:$false -Verbose:$VerbsosePreference;
		LogVerbose "RemoveAssignment Result = $removeAssignmentResult"
	}
	catch
	{
		LogWarning -Message "Unexpected Exception occured when attempting to DELETE a policy assignment" -AdditionalData $_;
		throw $_;	
	}

	if($removeAssignmentResult -ne $true)
	{
		LogException "Failed to Remove the assignment $($assignment.ResourceId)";
	}

	try 
	{
		LogVerbose "Remove policy set definition '$($policySet.ResourceId)'";
		$removeInitiativeResult = Remove-AzPolicySetDefinition -Id $policySet.ResourceId -Confirm:$false -Verbose:$VerbsosePreference -Force;
		LogVerbose "RemoveInitiative Result = $removeInitiativeResult"
	}
	catch
	{
		LogWarning -Message "Unexpected Exception occured when attempting to DELETE a policy initiative definition" -AdditionalData $_;
		throw $_;			
	}

	if($removeInitiativeResult -ne $true)
	{
		LogException "Failed to Remove the initiative definition '$($policySet.ResourceId)'";
	}

	foreach($policyDefinition in $policySet.Properties.PolicyDefinitions)
	{
		try
		{
			LogVerbose "Gathering Details for Policy Definition: PolicySet '$($policySet.ResourceId)' contains policy definition '$($policyDefinition.policyDefinitionId)'";
			$def = Get-AzPolicyDefinition -Id $policyDefinition.policyDefinitionId;
			LogVerbose "Found details for Policy Definition '$($policyDefinition.policyDefinitionId)'";
		}
		catch
		{
			if($_.ToString().Contains("PolicyDefinitionNotFound") -eq $true)
			{
				LogWarning "Policy Definition not found for deletion, skipping" -AdditionalData $_;
				return;
			}
			else
			{
				LogWarning -Message "Unexpected Exception occured when attempting to get a policy definition" -AdditionalData $_;
				throw $_;
			}
		}

		if($def.properties.policyType -eq "BuiltIn")
		{
			LogVerbose "Policy is built in, will not attempt delete.";
		}
		else
		{
			try 
			{
				LogVerbose "Deleting Custom Policy definition '$($policyDefinition.policyDefinitionId)'";
				$removeDefinitionResult = Remove-AzPolicyDefinition -Id $policyDefinition.policyDefinitionid -Confirm:$false -Verbose:$VerbosePreference -Force;
				LogVerbose "Remove Definition Result = $removeDefinitionResult"
			}
			catch
			{
				LogWarning -Message "Unexpected Exception occured when attempting to DELETE a policy definition" -AdditionalData $_;
				throw $_;	
			}

			if($removeDefinitionResult -ne $true)
			{
				LogException "Failed to Remove the policy definition '$($policyDefinition.policyDefinitionid)'";
			}
		}
	}
}

Function CreateAssignmentName
{
	Param(
		[Parameter(Mandatory = $true)]
		[string]$Name
	)

	# Check if name is too long
	if($Name.Length -gt 24)
	{
		$oldName = $Name;
		$nameBytes = [System.Text.Encoding]::Default.GetBytes($Name);
		$hash = $hasher.ComputeHash($nameBytes);
		$Name = [System.BitConverter]::ToString($hash).Replace('-', '').SubString(0,24);
	}

	return $Name;
}

Function AssignPolicySet
{
	Param(
		[Parameter(Mandatory = $true)]
		[string]$Name,

		[Parameter(Mandatory = $true)]
		[string]$Scope,

		[Parameter(Mandatory = $true)]
		[AzurePolicySet]$PolicySet,

		[string]$IdentityLocation,

		[string[]]$NotScopes,

		[PSCustomObject]$Parameters,

		[string]$DisplayName = $null,
		[string]$Description = $null
		
	)

	LogVerbose "Name of policy = '$($Name)' @ $($Name.Length) characters";
	
	$AssignmentResourceId = CreateAssignmentName -Name $Name;

	$controls = $PolicySet.Source.GetControls();
	$parameterProperties = $Parameters.PSObject.Properties | select Name;

	if($PolicySet.ParameterNames.Count -gt 0)
	{
	    ValidateParametersExist -RequiredParameters $PolicySet.ParameterNames -Parameters $Parameters;
    }
    else
    {
        LogVerbose "No Parameters found in set, no parameter validation will occur";
    }

	$arguments = @{
		"Name" = $AssignmentResourceId;
		"Scope" = $Scope;
		"PolicySetDefinition" = $PolicySet.PolicySetResult;
		"Verbose" = $VerbosePreference;
	}

	if($NotScopes -ne $null)
	{
		if($NotScopes.count -gt 0)
		{
			LogVerbose "The assignment '$($AssignmentResourceId)' ($($Name)) will be created with exceptions!";
			$arguments["notScope"] = $NotScopes;
		}
	}

	# Try and use Display Name for better Readability
	if([String]::IsNullOrWhitespace($DisplayName))
	{
		LogVerbose "DisplayName not provided, using short name";
		$arguments["DisplayName"] = $Name;
	}
	else 
	{
		$arguments["DisplayName"] = $DisplayName;	
	}

	# Try and use Description for better readability
	if([String]::IsNullOrWhitespace($Description))
	{
		LogVerbose "Description for policy set not provided, rendering control names";
		$initiativeDescription = RenderControlsDescriptionPartial -Controls $controls;
		$arguments["Description"] = $initiativeDescription;
	}
	else
	{
		$arguments["Description"] = $Description;	
	}

	if($PolicySet.RequiresManagedIdentity -eq $true)
	{
		LogVerbose "Policy Set requires a Managed Identity.";

		$arguments["AssignIdentity"] = $true;

		if([string]::IsNullOrWhitespace($IdentityLocation))
		{
			LogException "This policy set contains a Template Deployment, and therefore requires a managed identity. An Identity must be created in a defined region.";
		}
		
		$arguments["Location"] = $IdentityLocation;
	}

	if($PolicySet.ParameterNames.Count -gt 0)
	{
		$parametersJson = Stringify $Parameters;
		$arguments["PolicyParameter"] = $parametersJson;

		$paramValues = @();

		foreach($property in $Parameters.PSObject.Properties)
		{
			$pair = [AzurePolicyAssignmentParameterPair]::new($property.Name, $property.Value);
			$paramValues += $pair;
		}
	}

	$assignmentResult = New-AzPolicyAssignment @arguments;

    $result = [AzurePolicyAssignment]::new($PolicySet, $assignmentResult, $Scope, $Name);
	
	if($paramValues.count -gt 0)
	{
		$result.ParameterValues = $paramValues;
	}

    return $result;
}

Function CheckManagedIdentityReplication
{
    Param (
        [Parameter(Mandatory = $true)]
        [string]$PrincipalId
    )

	$checkBlock = {

        $principal = Get-AzADServicePrincipal -ObjectId $PrincipalId;

        if($principal -ne $null)
        {
            LogVerbose "Principal Found. Waiting 10 seconds due to odd AzureAd Replication issues";

            Start-Sleep 10;

            return $principal;
		}
	}

	$result = Retry -OperationName "Deploy/Policy/CheckManagedIdentityReplication" -ScriptBlock $checkBlock;

	return $result;
}

Function AssignRequiredRoles
{
    Param(
        [Parameter(Mandatory = $true)]
        [AzurePolicyAssignment]$Assignment
    )

    LogVerbose "Assigning $($Assignment.RoleDefinitionIds.Count) role definitions @ $($Assignment.Scope) to Principal $($Assignment.IdentityObjectId)";

    foreach($roleDefinition in $Assignment.RoleDefinitionIds)
    {
        LogVerbose "Assigning $($roleDefinition)@$($Assignment.Scope):$($Assignment.IdentityObjectId)";

		# Required Roles in Azure Policy are fully qualified by their resource id.
        $roleDefinitionParts = $roleDefinition.Split('/');
        [Array]::Reverse($roleDefinitionParts);
        $roleDefinitionId = $roleDefinitionParts[0];

		AssignRole -Scope $Assignment.Scope -PrincipalObjectId $Assignment.IdentityObjectId -RoleDefinitionId $roleDefinitionId;
    }
}

Function AssignRole {
	Param(
		[Parameter(Mandatory = $true)]
		[string]$Scope,

		[Parameter(Mandatory = $true)]
		[string]$PrincipalObjectId,

		[Parameter(Mandatory = $true)]
		[string]$RoleDefinitionId
	)

	$roleAssignment = Get-AzRoleAssignment -ObjectId $PrincipalObjectId -Scope $Scope -RoleDefinitionId $RoleDefinitionId -Verbose:$VerbosePreference;

	if($roleAssignment -ne $null)
	{
		LogVerbose "Found that role definition $($RoleDefinitionId)@$($Scope):$($PrincipalObjectId) already exists at this scope.";
	}
	else 
	{
		New-AzRoleAssignment -ObjectId $PrincipalObjectId -Scope $Scope -RoleDefinitionId $RoleDefinitionId -Verbose:$VerbosePreference | out-null;
		LogVerbose "Assigned role $($RoleDefinitionId)@$($Scope):$($PrincipalObjectId).";
	}
}

Function GetScopeHierarchy
{
	Param(
		[Parameter(Mandatory = $true, ParameterSetName = "SubscriptionId")]
		[string]$SubscriptionId,

		[Parameter(Mandatory = $true, ParameterSetName = "ManagementGroupName")]
		[string]$ManagementGroupName
	)

	$managementGroups = Get-AzManagementGroup;
	$reference = New-Object "System.Collections.Generic.Dictionary[string, PSManagementGroupInfo]";

	foreach($mg in $managementGroups)
	{
		$emg = Get-AzManagementGroup -GroupName $mg.Name -Expand;

		$reference[$emg.Name] = $emg;
	}
}

Function AssignAdditionalPermissions
{
	Param(
		[Parameter(Mandatory = $true)]
        [AzurePolicyAssignment]$Assignment,

		[Parameter(Mandatory = $true)]
		[PSObject]$AdditionalPermissionsMap
	)

	# Assign custom permissions
	LogVerbose "Begin assigning custom permissions for assignment '$($Assignment.ResourceId)'";


	# Validate that required properties exist
	if($AdditionalPermissionsMap.global -eq $null)
	{
		LogVerbose "No Globally assigned additional permissions found";
	}
	else
	{
		$globalAssignments = $AdditionalPermissionsMap.global.PSObject.Properties;

		foreach($permissionAssignmentScope in $globalAssignments)
		{
			$permissionScope = $permissionAssignmentScope.Name;
			$permissionEntries = $permissionAssignmentScope.Value;

			if($permissionEntries -eq $null)
			{
				throw "Malformed permssions scope. Null Value Not expected. Please review your permission file";
			}

			if($permissionEntries.count -eq 0)
			{
				LogVerbose "No Permission Entries found for global scope '$($permissionScope)'";
			}

			foreach($permissionEntry in $permissionEntries)
			{
				AssignAdditionalPermissionEntry -Assignment $Assignment -PermissionEntry $permissionEntry -PermissionScope $permissionScope;
			}
		}
	}

	# Get Global Permission
	LogVerbose "Begin assigning permissions that apply to only this initiative for assignment '$($Assignment.AssignmentMoniker)' ('$($Assignment.ResourceName)')";

	if($AdditionalPermissionsMap.initiatives -eq $null)
	{
		LogVerbose "No Initiative Section in the permissions map";
	}
	else
	{
		if($AdditionalPermissionsMap.initiatives.PSObject.Properties[$Assignment.AssignmentMoniker] -eq $null)
		{
			LogVerbose "No Entry found for initiative with moniker '$($Assignment.AssignmentMoniker)' found in the permission entries. If this is unexpected: This value is case sensitive, please ensure your permission file matches folder names.";
		}
		elseif($AdditionalPermissionsMap.initiatives.PSObject.Properties[$Assignment.AssignmentMoniker].Value -eq $null)
		{
			throw "Malformed initiative section. Null Value Not expected. Please review your permission file";
		}
		else
		{
			$initiativeAssignments = $AdditionalPermissionsMap.initiatives.PSObject.Properties[$Assignment.AssignmentMoniker].Value.PSObject.Properties;

			foreach($permissionAssignmentScope in $initiativeAssignments)
			{
				$permissionScope = $permissionAssignmentScope.Name;
				$permissionEntries = $permissionAssignmentScope.Value;

				if($permissionEntries -eq $null)
				{
					throw "Malformed permssions scope. Null Value Not expected. Please review your permission file";
				}

				if($permissionEntries.count -eq 0)
				{
					LogVerbose "No Permission Entries found for global scope '$($permissionScope)'";
				}

				foreach($permissionEntry in $permissionEntries)
				{
					AssignAdditionalPermissionEntry -Assignment $Assignment -PermissionEntry $permissionEntry -PermissionScope $permissionScope	;
				}
			}
		}
	}
}

Function AssignAdditionalPermissionEntry
{
	Param(
		[Parameter(Mandatory = $true)]
        [AzurePolicyAssignment]$Assignment,

		[Parameter(Mandatory = $true)]
		[PSObject]$PermissionEntry,

		[Parameter(Mandatory = $true)]
		[string]$PermissionScope
	)

	if($PermissionEntry.principalObjectId -eq "{{current}}")
	{ 
		LogVerbose "Found permission entry targeting MI of newly created assignment.";
		$objectId = $Assignment.IdentityObjectId;
	}
	else
	{
		$objectId = $PermissionEntry.principalObjectId;
	}

	$roleDefinitionId = $PermissionEntry.roleDefinitionId;

	AssignRole -RoleDefinitionId $roleDefinitionId -PrincipalObjectId $objectId -Scope $PermissionScope;
}

Function GetPolicyEffectClassificationValue
{
    Param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyEffectClassification
    )

    $lower = $PolicyEffectClassification.ToLowerInvariant();

    switch($lower)
    {
        "audit" { return 10; }
        "auditifnotexists" { return 11; }
        "deny" { return 100; }
        "deployifnotexists" { return 1000; }
		"modify" { return 1002; }
        "append" { return 1003; }
        default { return 1004; }

    }
}

