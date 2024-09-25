<# 
====================================================
|  EoP AllowAll domain Powershell  Script          |
| Created by: LewsTherinSedai                      |
| Contact: github.com/LewsTherinSedai              |
| Revision: 1.1                                    |
====================================================

.AUTHOR
    LewsTherinSedai on Git

.DATE
    2024-09-24
.DESCRIPTION
This script connects to Exchange Online and looks over content filters for 'allowed all' domains and reports it to - by default 
c:\temp\ in a csv
It will include in the csv which policy the domain(s) are listed in, and if you want you can change Unique in the variables to
$True and it will remove duplicates (handy if you're just converting these to a different format)
It will then go through and check the domains for spf/dmarc/dkim on each domain.    
.INPUTS
There are static variables you need to adjust
.NOTES
    GPL v3.0

    REQUIREMENTS
    - Didn't build in logic to ensure c:\temp exists...so, make it
    - It will install modules if you don't have them
    - Uses modern auth so, don't run it on a CLI only machine

#>

# Define customizable variables
$outputPath = "C:\temp\CombinedDomainRecords.csv"
$userPrincipalName = "UPN@fabrikom.com"
$tempFolder = "C:\temp\PolicyReports"  # Temporary folder for individual CSVs
$reportUnique = $false  # Set this to $true to report unique domains only regardless of policy

# Check and install ExchangeOnlineManagement module if missing
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber
}

# Check and install DomainHealthChecker module if missing - https://github.com/T13nn3s/Invoke-SpfDkimDmarc 
if (-not (Get-Module -ListAvailable -Name DomainHealthChecker)) {
    Install-Module -Name DomainHealthChecker -Force -AllowClobber
}

# Connect to Exchange Online
Connect-ExchangeOnline -UserPrincipalName $userPrincipalName

# Initialize an array to store results
$results = @()

# Create a temporary folder for individual CSVs
if (-not (Test-Path -Path $tempFolder)) {
    New-Item -ItemType Directory -Path $tempFolder
}

# Get all content filter policies
$contentFilterPolicies = Get-HostedContentFilterPolicy

foreach ($policy in $contentFilterPolicies) {
    # Get allowed sender domains for the current policy
    $allowedSenderDomains = $policy.AllowedSenderDomains
    $policyResults = @()

    foreach ($domain in $allowedSenderDomains) {
        # Check SPF, DKIM, and DMARC records
        $spfResult = Get-SPFRecord $domain -ErrorAction SilentlyContinue
        $dkimResult = Get-DKIMRecord $domain -ErrorAction SilentlyContinue
        $dmarcResult = Get-DMARCRecord $domain -ErrorAction SilentlyContinue

        # Create an object to store the results
        $result = [PSCustomObject]@{
            Domain       = $domain
            FilterPolicy = $policy.Name
            SPF          = if ($spfResult) { "Configured" } else { "Not Configured" }
            DKIM         = if ($dkimResult) { "Configured" } else { "Not Configured" }
            DMARC        = if ($dmarcResult) { "Configured" } else { "Not Configured" }
        }

        # Add the result to the policy-specific array
        $policyResults += $result
    }

    # Export the policy-specific results to a CSV file
    $policyCsvPath = Join-Path -Path $tempFolder -ChildPath "$($policy.Name)_Domains.csv"
    $policyResults | Select-Object Domain, FilterPolicy, SPF, DKIM, DMARC | Export-Csv -Path $policyCsvPath -NoTypeInformation
}

# Combine all individual CSVs into one final CSV
Get-ChildItem -Path $tempFolder -Filter "*.csv" | 
    ForEach-Object {
        Import-Csv -Path $_.FullName
    } | Export-Csv -Path $outputPath -NoTypeInformation

# Optionally, clean up the temporary folder
Remove-Item -Path $tempFolder -Recurse -Force