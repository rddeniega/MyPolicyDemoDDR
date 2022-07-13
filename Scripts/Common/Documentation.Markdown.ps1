Param(
    [switch]$SuperVerbose
)

. $PSScriptRoot\..\Core.Scripts\Logging.ps1 -SuperVerbose:$SuperVerbose;
. $PSScriptRoot\..\Core.Scripts\stdio.ps1 -SuperVerbose:$SuperVerbose;

# Constants
[char]$const_DashChar = [char]'-';
[char]$const_ColonChar = [char]':';
[char]$const_SpaceChar = [char]' ';
[string]$const_Space = $const_SpaceChar.ToString();

enum PropertyFormatting {
	None
	Bold
	Italic
	Code
	H1
	H2
	H3
	H4
	H5
	H6
}

enum TableCellAlignment 
{
	Left
	Center
	Right
}

class TableCellFormat {
	[string]$ColumnName;
	[PropertyFormatting]$Formatting;
	[TableCellAlignment]$Alignment;
}

class MarkdownBuilder
{
	hidden $Builder;

	MarkdownBuilder()
	{
		$this.Builder = new-object 'System.Text.StringBuilder'
	}

	[void]Append([string]$appendValue)
	{
		$this.Builder.Append($appendValue);
	}

	[void]Append([char]$appendValue)
	{
		$this.Builder.Append($appendValue);
	}

	[void]AppendLine([string]$appendValue)
	{
		$this.Builder.AppendLine($appendValue);
	}

	[void]AppendLine([char]$appendValue)
	{
		$this.Builder.AppendLine($appendValue);
	}

	[void]AppendLine() 
	{
		$this.Builder.AppendLine();
	}

	[void]AppendLineBr([string]$appendValue)
	{
		$this.Append($appendValue);
		$this.AppendLine("<br />");
	}

	[string]ToString()
	{
		$result = $this.Builder.ToString();

		return $result;
	}
}

Function ConvertPropertyToPlainText
{
    Param(
        [Parameter(Mandatory = $true)]
        [string]$InputObject
    )

    [char[]]$chars = $InputObject.ToCharArray();

    $builder = [MarkdownBuilder]::new();

    foreach($char in $chars)
    {
        if([char]::IsUpper($char) -eq $true)
        {
            $builder.Append(' ');
        }

        $builder.Append($char);
    }

    $result = $builder.ToString().Trim();

    return $result;
}

Function SetColumnMaxWidth 
{
	Param(
		[Parameter(Mandatory = $true)]
		[System.Collections.Generic.Dictionary[string,int]]$Widths,

		[Parameter(Mandatory = $true)]
		[string]$ColumnName,

		[Parameter(Mandatory = $true)]
		[string]$ColumnValue
	)

	if([String]::IsNullOrWhitespace($ColumnValue))
	{
		$length = 0;
	}
	else
	{
		$length = $ColumnValue.Length;
	}
	
	if($Widths.ContainsKey($ColumnName))
	{
		[int]$val = $Widths[$ColumnName];

		if($length -gt $val)
		{
			$Widths[$ColumnName] = $length;

			LogVerbose "Column '$ColumnName' maxWidth has been increased from $val to $length.";
		}
		else
		{
			LogVerbose "Column '$ColumnName' width has not been changed."
		}
	}
	else
	{
		$Widths[$ColumnName] = $length;

		LogVerbose "Column '$ColumnName' has not been seen before and is being set to length $length";
	}
}

Function MakeTableDashes
{
	Param(
		[Parameter(Mandatory = $true)]
		[int]$Length,

		[TableCellAlignment]$Alignment = [TableCellAlignment]::Left
	)

	$chars = New-Object "char[]" $Length;

	if($Alignment -eq [TableCellAlignment]::Left -or $Alignment -eq [TableCellAlignment]::Center)
	{
		$chars[0] = $const_ColonChar;
	}
	else
	{
		$chars[0] = $const_DashChar;
	}

	for($i = 1; $i -lt $($Length - 1); $i++)
	{
		$chars[$i] = $const_DashChar;
	}

	if($Alignment -eq [TableCellAlignment]::Right -or $Alignment -eq [TableCellAlignment]::Center)
	{
		$chars[$Length - 1] = $const_ColonChar;
	}
	else
	{
		$chars[$Length - 1] = $const_DashChar;
	}

	$result = New-Object "System.String" @(,$chars);

	return $result;
}

Function MakeSpaces
{
	Param(
		[Parameter(Mandatory = $true)]
		[int]$Length
	)

	$chars = New-Object "char[]" $Length;

	for($i = 0; $i -lt $Length; $i++)
	{
		$chars[$i] = $const_SpaceChar;
	}

	$result = New-Object "System.String" @(,$chars);

	return $result;
}

Function MakePaddedString
{
	Param(
		[Parameter(Mandatory = $true)]
		[string]$InputObject,

		[Parameter(Mandatory = $true)]
		[int]$TotalLength
	)

	if($InputObject.Length -gt $TotalLength)
	{
		return $InputObject;
	}

	$spaceLength = $TotalLength - $InputObject.Length;
	$spaces = MakeSpaces -Length $spaceLength;

	$result = $InputObject + $spaces;

	return $result;
}

Function CreateMarkdownForAssignment
{
	Param(
		[Parameter(Mandatory = $true)]
		[AzurePolicyAssignment]$PolicyAssignment,

		[Parameter(Mandatory = $true)]
		[string]$OutputDirectory
	)

	$builder = [MarkdownBuilder]::new();

	$builder.Append("# ![Alt PolicyLogo](https://schema.toncoso.com/6-5-2019-dev/Policy.png) ");
	$builder.AppendLine($PolicyAssignment.Source.Source.DisplayName);
	$builder.AppendLine();

	# # # # # Write Details
	# Assignment Scope
	$builder.Append("**Assignment Name**: ");
	$builder.AppendLineBr($PolicyAssignment.AssignmentMoniker);
#	$builder.AppendLine();
	
	# Assignment Scope
	$builder.Append("**Assignment Scope**: ");
	$builder.AppendLineBr("``$($PolicyAssignment.Scope)``");
#	$builder.AppendLine();

	# Assignment Id
	$builder.Append("**Assignment Id**: ");
	$builder.AppendLineBr("``$($PolicyAssignment.ResourceId)``");
#	$builder.AppendLine();

	if([String]::IsNullOrWhitespace($PolicyAssignment.IdentityObjectId) -eq $false)
	{
		$builder.Append("**Managed Identity Service Principal Object**: ");
		$builder.AppendLineBr("``$($PolicyAssignment.IdentityObjectId)``");
	}

	if($PolicyAssignment.ParameterValues -ne $null)
	{
		foreach($pv in $PolicyAssignment.ParameterValues)
		{
			# Ensure that values are in MD inline code for visualization
			# adding spaces after commas to ensure line wrap
			$pv.ParameterValue = "``$($pv.ParameterValue)``".Replace(",", ", ");
		}

		$builder.AppendLine("#### Assigned Parameter Values");
		$tableOutput = CreateObjectTable -Objects $PolicyAssignment.ParameterValues;
		$builder.AppendLine($tableOutput);
	}

	$policySetMarkdown = CreateMarkdownForPolicySet -PolicySet $PolicyAssignment.Source;

	$builder.AppendLine($policySetMarkdown);
	
	$builder.AppendLine();

	$builder.Append("*Documentation created on ");
	$builder.Append([System.DateTimeOffset]::UtcNow.ToString());
	$builder.Append("*");

	$result = $builder.ToString();
	
	$outputFileName = [System.IO.Path]::Combine($OutputDirectory, $($PolicyAssignment.AssignmentMoniker + ".md"));

	$result | WriteFile -Path $outputFileName -Force;

	return $outputFileName;
}

Function CreateMarkdownForPolicySet
{
	Param (
		[Parameter(Mandatory = $true)]
		[AzurePolicySet]$PolicySet
	)

	$builder = [MarkdownBuilder]::new();

	$builder.AppendLine("## ![Alt PolicyLogo](https://schema.toncoso.com/6-5-2019-dev/Policy.png) Policy Set Details - $($PolicySet.Source.DisplayName)");
	$builder.AppendLine();

	# Name
	$builder.Append("**Initiative Name**: ");
	$builder.AppendLineBr($PolicySet.Name);
#	$builder.AppendLine();
	
	# ResourceId
	$builder.Append("**Initiative Resource Id**: ");
	$builder.AppendLineBr("``$($PolicySet.ResourceId)``");
#	$builder.AppendLine();

	# Name
	$builder.Append("**Initiative Description**: ");
	$builder.AppendLineBr("``$($PolicySet.Source.Description)``");
#	$builder.AppendLine();

	$objs = $PolicySet.GetControls();

	if($objs -ne $null -and $objs.Count -ne 0)
	{
		LogVerbose "Policy has controls, rendering control table"; 

		$builder.Append("### Impacted Controls");
		$objsMarkdown = CreateControlsMarkdown -Controls $objs;
	}
	else
	{
		LogVerbose "Policy Set $($PolicySet.Source.Name) has no controls, not rendering control table";
	}

	$builder.AppendLine();
	$builder.AppendLine($objsMarkdown);
	$builder.AppendLine();

	foreach($policy in $PolicySet.Source.Policies)
	{
		$policyMarkdown = CreateMarkdownForPolicy -Definition $policy;

		$builder.AppendLine($policyMarkdown);
		$builder.AppendLine();
	}

	$result = $builder.ToString();

	return $result;
}

Function CreateMarkdownForPolicy {
	Param(
		[Parameter(Mandatory = $true)]
		[AzurePolicyDefinition]$Definition
	)

	$builder = [MarkdownBuilder]::new();

	$builder.Append("## ![Alt PolicyLogo](https://schema.toncoso.com/6-5-2019-dev/Policy.png) Policy Details - ");
	$builder.AppendLineBr($Definition.Source.DisplayName);
#	$builder.AppendLine();

	$builder.Append("**Policy Internal Name**: ");
	$builder.AppendLineBr($Definition.Name);
#	$builder.AppendLine();

	$builder.Append("**Effect**: ");
	$builder.AppendLineBr("``$($Definition.Source.Effect)``");
#	$builder.AppendLine();

	$builder.Append("**Description**: ");
	$builder.AppendLine($Definition.Source.Description);
#	$builder.AppendLine();

	if($Definition.Source.Controls -ne $null -and $Definition.Source.Controls.Count -ne 0)
	{
		$builder.AppendLine("### Impacted Controls");
		$objsMarkdown = CreateControlsMarkdown -Controls $Definition.Source.Controls;
	}
	else
	{
		LogWarning "Policy $($Definition.Source.Name) has no control objects, no controls will be rendered.";
	}

	$builder.AppendLine();
	$builder.AppendLine($objsMarkdown);

	$result = $builder.ToString();

	return $result;
}

Function MarkdownFormat {
	Param(
		[Parameter(Mandatory = $true)]	
		[string]$InputValue,

		[Parameter(Mandatory = $true)]
		[PropertyFormatting]$Formatting
	)

	switch($Formatting)
	{
		Default {
			return $InputValue;
		}
		[PropertyFormatting]::Bold {
			$result = "**$($InputValue)**";
			return $result;
		}
		[PropertyFormatting]::Italic {
			$result = "*$($InputValue)*";
			return $result;
		}
		[PropertyFormatting]::Code {
			$result = "``$($InputValue)``";
			return $result;
		}
		[PropertyFormatting]::H1 {
			$result = "# $($InputValue)";
			return $result;
		}
		[PropertyFormatting]::H2 {
			$result = "## $($InputValue)";
			return $result;
		}
		[PropertyFormatting]::H3 {
			$result = "### $($InputValue)";
			return $result;
		}
		[PropertyFormatting]::H4 {
			$result = "#### $($InputValue)";
			return $result;
		}
		[PropertyFormatting]::H5 {
			$result = "##### $($InputValue)";
			return $result;
		}
		[PropertyFormatting]::H6 {
			$result = "###### $($InputValue)";
			return $result;
		}
	}
}

Function CreateObjectTable {
	Param(
		[Parameter(Mandatory = $true)]
		[Object[]]$Objects,

		[string[]]$SortedPropertyNames = $null,

		[System.Collections.Generic.Dictionary[string, TableCellFormat]]$Formatting = $null
    )

	$builder = [MarkdownBuilder]::new();

	$columnWidths = New-Object 'System.Collections.Generic.Dictionary[string, int]';

	if($SortedPropertyNames -eq $null)
	{
        $members = $Objects[0] | Get-Member;
		$properties = $members | Where-Object{ $_.MemberType -eq "Property" -or $_.MemberType -eq "NoteProperty"} | Select-Object -ExpandProperty Name;
	}
	else 
	{
		$properties = $SortedPropertyNames;
	}
	
	if($Formatting -eq $null)
	{
		$Formatting = New-Object 'System.Collections.Generic.Dictionary[string, TableCellFormat]';
	}

	foreach($property in $properties)
	{
		if($Formatting.ContainsKey($property) -eq $false)
		{
			$tfmt = [TableCellFormat]::new();
			$tfmt.ColumnName = $property;
			$tfmt.Alignment = [TableCellAlignment]::Left;
			$tfmt.Formatting = [PropertyFormatting]::None;
			$Formatting[$property] = $tfmt;
		}
	}

	foreach($property in $properties)
	{
		$columnName = $property;
		$columnNameValue = ConvertPropertyToPlainText($columnName);

		SetColumnMaxWidth -Widths $columnWidths -ColumnName $columnName -ColumnValue $columnNameValue;
	}

	# Set Column Widths
	foreach($obj in $Objects)
	{
		foreach($property in $properties)
		{
			$columnName = $property;

			$columnValue = $obj.PSObject.Properties[$columnName].Value;

			if([Uri]::IsWellFormedUriString($ColumnValue, [UriKind]::Absolute))
			{
				$columnValue = "[Link]($($columnValue))";
			}

			if([string]::IsNullOrEmpty($columnValue) -eq $false)
			{
				$columnValue = $columnValue.Replace([Environment]::NewLine, "<br />");
				[PropertyFormatting]$fmt = $Formatting[$columnName].Formatting;
				$columnValue = MarkdownFormat -InputValue $columnValue -Formatting $fmt;

				SetColumnMaxWidth -Widths $columnWidths -ColumnName $columnName -ColumnValue $columnValue;
			}
		}
	} 

	$builder.Append('|');
	
	foreach($property in $properties)
	{
		$columnName = $property;
		$columnNameValue = ConvertPropertyToPlainText($columnName);

		$builder.Append($const_SpaceChar);

		$val = MakePaddedString -Input $columnNameValue -TotalLength ($columnWidths[$columnName]);
		$builder.Append($val);

		$builder.Append($const_SpaceChar);
		$builder.Append('|');
	}

	# Write final pipe for row
	$builder.AppendLine();

	# Write Header Boarders

	$builder.Append('|');

	foreach($property in $properties)
	{
		$columnName = $property;

		$builder.Append($const_SpaceChar);

		$alignment = $Formatting[$columnName].Alignment
		$val = MakeTableDashes -Length ($columnWidths[$columnName]) -Alignment $alignment;
		$builder.Append($val);

		$builder.Append($const_SpaceChar);
		$builder.Append('|');
	}

	# Write final pipe for row
    $builder.AppendLine();
    
	# ColumnWidths has been established
	foreach($obj in $Objects)
	{
		$builder.Append('|');

		foreach($property in $properties)
		{
			$columnName = $property;
			$columnValue = $obj.PSObject.Properties[$columnName].Value;

			if([string]::IsNullOrEmpty($columnValue) -eq $true)
			{
				$columnValue = $const_Space;
			}
			else
			{						
				if([Uri]::IsWellFormedUriString($ColumnValue, [UriKind]::Absolute))
				{
					$columnValue = "[Link]($($columnValue))";
				}
			
				[PropertyFormatting]$fmt = $Formatting[$columnName].Formatting;
				$columnValue = MarkdownFormat -InputValue $columnValue -Formatting $fmt;
			}

			$builder.Append($const_SpaceChar);

			$columnValue = $columnValue.Replace([Environment]::NewLine, "<br />");
			$val = MakePaddedString -Input $columnValue -TotalLength ($columnWidths[$columnName]);

			$builder.Append($val);

			$builder.Append($const_SpaceChar);
			$builder.Append('|');
		}

		$builder.AppendLine();
	}

	return $builder.ToString();
}
Function CreateControlsMarkdown {
	Param(
		[Parameter(Mandatory = $true)]
		[Control[]]$Controls
	)

	LogVerbose "Gathering Column Widths for Documentation";
	$builder = [MarkdownBuilder]::new();

	$sortedControls = $controls | Sort-Object -Property @("Standard", "ControlId");

	$tableOutput = CreateObjectTable -Objects $sortedControls -SortedPropertyNames @("ControlId", "DisplayName", "Description", "ControlUri", "Standard");

	$builder.Append($tableOutput);

	$result = $builder.ToString();

	return $result;
}