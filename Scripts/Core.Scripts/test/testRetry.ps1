[CmdletBinding()]
Param(

)

. $PSScriptRoot\..\Retry.ps1;


Retry -OperationName "Test/Retry/1" -RetryTimeout 1 -ScriptBlock  {
    $bottom = New-Object "System.Exception" "This is the bottom exception";
    $middle = New-Object "System.InvalidOperationException" @("This is the middle exception", $bottom);
    $top = New-Object "System.StackOverflowException" @("This is the top exception", $middle);

    throw $top;
}

Retry -OperationName "Test/Retry/2" -RetryTimeout 1 -ScriptBlock  {
    New-AzKeyVault -Name "tontestperm" -ResourceGroupName SharedServices-RG -Location WestUs2
}