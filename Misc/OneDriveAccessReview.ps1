#Graph API PS is picky as hell - I find it best to uninst/reinst each time
Uninstall-Module Microsoft.Graph -AllVersions -Force
Install-Module Microsoft.Graph -Force
# Connect to Graph - NOTE that I've had issues using DeviceCode auth with this for some reason, so avoid using -DeviceCode
Connect-MgGraph -TenantId "[Tenant ID goes here]" `
  -Scopes "User.Read.All","Reports.Read.All","AuditLog.Read.All" 
# 1) Current unlicensed users
$unlicensed = Get-MgUser -All `
  -Property 'id,userPrincipalName,accountEnabled,assignedLicenses' |
  Where-Object { -not $_.AssignedLicenses -or $_.AssignedLicenses.Count -eq 0 } |
  Select-Object @{n='UPN';e={$_.UserPrincipalName}}, Id, AccountEnabled

# Hash for fast lookups
$unlicensedSet = @{}
$unlicensed | ForEach-Object { $unlicensedSet[$_.UPN.ToLower()] = $true }

# 2) OneDrive usage (D90) -> last 59 days
$csvPath = "C:\temp\TestOneDriveUsage.csv"
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/v1.0/reports/getOneDriveUsageAccountDetail(period='D90')" `
  -OutputFile $csvPath

$cut59 = (Get-Date).AddDays(-59)
$od = Import-Csv $csvPath | Where-Object {
  $_.'Last Activity Date' -and ([datetime]$_.'Last Activity Date') -gt $cut59
}

# 3) Primary join on OPN
$prelim = $od | Where-Object { 
  $_.'Owner Principal Name' -and $unlicensedSet.ContainsKey($_.'Owner Principal Name'.ToLower())
} | Select-Object @{n='UPN';e={$_.'Owner Principal Name'}},
                  @{n='LastActivityDate';e={$_.'Last Activity Date'}},
                  @{n='SiteUrl';e={$_.'Site URL'}}

# 4) Verify owner from Graph using the Site URL
function Convert-UpnToPersonalPath {
    param([Parameter(Mandatory)][string]$Upn)
    # Replace anything not [a-zA-Z0-9] with underscore
    ($Upn -replace '[^a-zA-Z0-9]', '_')
}

# 2) Tenant name before -my.sharepoint.com)
$TenantShortName = "contoso.com" #Real Domain goes here don’t usecontoso you dork   

# 3) If the CSV is missing Site URL, fill it from Owner Principal Name
$od = Import-Csv "C:\temp\TestOneDriveUsage.csv" |
  Where-Object { $_.'Last Activity Date' -and ([datetime]$_.'Last Activity Date') -gt (Get-Date).AddDays(-59) } |
  ForEach-Object {
    $siteUrl = $_.'Site URL'
    $ownerPn = $_.'Owner Principal Name'
    if ([string]::IsNullOrWhiteSpace($siteUrl) -and $ownerPn -and $ownerPn -like '*@*') {
      $personal = Convert-UpnToPersonalPath $ownerPn
      $_.'Site URL' = "https://$TenantShortName-my.sharepoint.com/personal/$personal"
    }
    $_
  }

# 4) Verify the true owner from Graph for each site 
function Get-DriveOwnerUpnFromSiteUrl {
    param([Parameter(Mandatory)][string]$SiteUrl)
    try {
        $u = [Uri]$SiteUrl
        $host = $u.Host
        $serverRel = $u.AbsolutePath.TrimStart('/')
        $site   = Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/sites/{0}:/{1}" -f $host,$serverRel)
        $drive  = Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/sites/{0}/drive?$select=owner" -f $site.id)
        if ($drive.owner.user.email) { $drive.owner.user.email }
        elseif ($drive.owner.user.id) { $drive.owner.user.id }
        else { $null }
    } catch { $null }
}

# 5) Current unlicensed set
$unlicensed = Get-MgUser -All -Property "userPrincipalName,assignedLicenses,accountEnabled" |
  Where-Object { -not $_.AssignedLicenses -or $_.AssignedLicenses.Count -eq 0 } |
  Select-Object @{n='UPN';e={$_.UserPrincipalName}}, AccountEnabled

$unlicensedSet = @{}
$unlicensed | ForEach-Object { if ($_.UPN) { $unlicensedSet[$_.UPN.ToLower()] = $true } }

# 6) Join by (verified owner) OR Owner Principal Name
$matched = foreach ($row in $od) {
  $ownerUpn = if ($row.'Site URL') { Get-DriveOwnerUpnFromSiteUrl -SiteUrl $row.'Site URL' } else { $null }
  if (-not $ownerUpn -and $row.'Owner Principal Name' -like '*@*') { $ownerUpn = $row.'Owner Principal Name' }

  if ($ownerUpn -and $unlicensedSet.ContainsKey($ownerUpn.ToLower())) {
    [pscustomobject]@{
      OwnerUpn         = $ownerUpn
      LastActivityDate = $row.'Last Activity Date'
      SiteUrl          = $row.'Site URL'
    }
  }
}

$matched | Sort-Object LastActivityDate -Descending | Format-Table -Auto
