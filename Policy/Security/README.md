# Introduction 
TODO: Give a short introduction of your project. Let this section explain the objectives or the motivation behind this project. 

# Getting Started
TODO: Guide users through getting your code up and running on their own system. In this section you can talk about:
1.	Installation process
2.	Software dependencies
3.	Latest releases
4.	API references

# Build and Tests
TODO: Describe and show how to build your code and run the tests. 

# Contribute
TODO: Explain how other users and developers can contribute to make your code better.

# Policy Naming, Descriptions, & Notes
## 1. Names of policies should begin with the type of effect and should concisely explain what the policy is enforcing
> ***Example***
>
> **Built-In**: Web Application should only be accessible over HTTPS
> 
> **Current**: Audit App Service where 'HTTPS Only' is not enabled
> 
> **New Format Ex. 1**: Audit - App Services should only be accessible over HTTPS
> 
> **New Format Ex. 2**: Deny - App Services should only be accessible over HTTPS
> 
> **New Format Ex. 3**: Remediate - App Services should only be accessible over HTTPS

## 2. Descriptions should explain what security vulnerability or exploit the policy will solve, along with what the configuration settings should be set to and explain the resulting effect if it is not met. Descriptions should begin with "This policy…"
> ***Example***
>
> **Built-In**: Use of HTTPS ensures server/service authentication and protects data in transit from network layer eavesdropping attacks.
> 
> **Current**: This policy audits App Services that do not have 'HTTPS Only' enabled. If not configured properly, you will be out of compliance.
> 
> **New Format Ex. 1**: This policy audits App Services that are not using HTTPS to ensure authentication and protect data in transit. Within the TLS/SSL Settings blade, ensure that HTTPS Only is set to 'On'. If this is not configured properly, you will be out of compliance.
> 
> **New Format Ex. 2**: This policy denies App Services that are not using HTTPS to ensure authentication and protect data in transit. Within the TLS/SSL Settings blade, ensure that HTTPS Only is set to 'On'. If it is disabled, you will be denied the creation or changing of this setting.
> 
> **New Format Ex. 3**: This policy remediates App Services that are not using HTTPS to ensure authentication and protect data in transit. Within the TLS/SSL Settings blade, ensure that HTTPS Only is set to 'On'. If HTTPS Only is disabled in any App Service, this policy will enable it.

## 3. Other Notes
Name (within the file) should match the File Name

Name and File Name should be camelCase

Category: "[SCGL]: _appropriate category name_"
> **Example**: "[SCGL]: Storage"

Display Names & Descriptions follow Schema

Character Count Limits (includes spaces):

&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;128 characters for the  displayName

&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;512 characters for the description



-----

If you want to learn more about creating good readme files then refer the following [guidelines](https://docs.microsoft.com/en-us/azure/devops/repos/git/create-a-readme?view=azure-devops). You can also seek inspiration from the below readme files:
- [ASP.NET Core](https://github.com/aspnet/Home)
- [Visual Studio Code](https://github.com/Microsoft/vscode)
- [Chakra Core](https://github.com/Microsoft/ChakraCore)