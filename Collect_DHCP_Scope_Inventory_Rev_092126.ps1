#requires -Version 5.1
#requires -Modules DhcpServer
<#
.SYNOPSIS
Collects IPv4 DHCP scope configuration and utilization from multiple DHCP servers.

.DESCRIPTION
Reads DHCP server names from a CSV, queries each server with the DhcpServer module,
and writes one combined CSV row per scope per source DHCP server. If both partners in
a failover relationship are listed, the same scope is intentionally reported once from
each partner and distinguished by SourceDhcpServer, which is always the final column.

The input CSV must contain one of these columns: DHCPServer, Server, ComputerName,
HostName, or Name.

.EXAMPLE
.\Get-DhcpScopeInventory.ps1 -ServerListPath .\DhcpServers.csv -OutputPath .\DhcpScopeInventory.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ServerListPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath ("DhcpScopeInventory_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))),

    [Parameter(Mandatory = $false)]
    [string]$ErrorLogPath = (Join-Path -Path (Get-Location) -ChildPath ("DhcpScopeInventory_Errors_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')))
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module DhcpServer -ErrorAction Stop

function ConvertTo-Text {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,
        [string]$Separator = '; '
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        return (($Value | ForEach-Object { [string]$_ }) -join $Separator)
    }
    return [string]$Value
}

function Get-PropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string[]]$Name
    )

    if ($null -eq $InputObject) { return $null }
    foreach ($propertyName in $Name) {
        $property = $InputObject.PSObject.Properties[$propertyName]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Get-OptionText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Options,
        [Parameter(Mandatory = $true)]
        [int]$OptionId
    )

    $option = $Options | Where-Object { $_.OptionId -eq $OptionId } | Select-Object -First 1
    if ($null -eq $option) { return $null }
    return ConvertTo-Text -Value $option.Value
}

function Convert-LeaseDuration {
    [CmdletBinding()]
    param([AllowNull()][object]$LeaseDuration)

    if ($null -eq $LeaseDuration) { return $null }
    if ($LeaseDuration -is [TimeSpan]) { return $LeaseDuration.ToString() }
    return [string]$LeaseDuration
}

$serverRows = @(Import-Csv -LiteralPath $ServerListPath)
if ($serverRows.Count -eq 0) {
    throw "The server list CSV contains no data rows: $ServerListPath"
}

$acceptedColumns = @('DHCPServer', 'Server', 'ComputerName', 'HostName', 'Name')
$availableColumns = @($serverRows[0].PSObject.Properties.Name)
$serverColumn = $acceptedColumns | Where-Object { $availableColumns -contains $_ } | Select-Object -First 1
if (-not $serverColumn) {
    throw "The input CSV must contain one of these columns: $($acceptedColumns -join ', '). Found: $($availableColumns -join ', ')"
}

$servers = @(
    $serverRows |
        ForEach-Object { [string]($_.$serverColumn) } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)
if ($servers.Count -eq 0) {
    throw "No DHCP server names were found in column '$serverColumn'."
}

$results = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]

foreach ($server in $servers) {
    Write-Host "Querying DHCP server: $server" -ForegroundColor Cyan

    try {
        $scopes = @(Get-DhcpServerv4Scope -ComputerName $server -ErrorAction Stop)
    }
    catch {
        $errors.Add([pscustomobject]@{
            Timestamp        = Get-Date
            SourceDhcpServer = $server
            ScopeId          = $null
            Operation        = 'Get-DhcpServerv4Scope'
            ErrorMessage     = $_.Exception.Message
        })
        Write-Warning "Unable to enumerate scopes on $server. $($_.Exception.Message)"
        continue
    }

    foreach ($scope in $scopes) {
        $scopeId = [string]$scope.ScopeId
        Write-Verbose "Collecting scope $scopeId from $server"

        $options = @()
        $dnsSetting = $null
        $statistics = $null
        $failover = $null

        try {
            $options = @(Get-DhcpServerv4OptionValue -ComputerName $server -ScopeId $scope.ScopeId -ErrorAction Stop)
        }
        catch {
            $errors.Add([pscustomobject]@{ Timestamp = Get-Date; SourceDhcpServer = $server; ScopeId = $scopeId; Operation = 'Get-DhcpServerv4OptionValue'; ErrorMessage = $_.Exception.Message })
        }

        try {
            $dnsSetting = Get-DhcpServerv4DnsSetting -ComputerName $server -ScopeId $scope.ScopeId -ErrorAction Stop
        }
        catch {
            $errors.Add([pscustomobject]@{ Timestamp = Get-Date; SourceDhcpServer = $server; ScopeId = $scopeId; Operation = 'Get-DhcpServerv4DnsSetting'; ErrorMessage = $_.Exception.Message })
        }

        try {
            $statistics = Get-DhcpServerv4ScopeStatistics -ComputerName $server -ScopeId $scope.ScopeId -Failover -ErrorAction Stop
        }
        catch {
            try {
                $statistics = Get-DhcpServerv4ScopeStatistics -ComputerName $server -ScopeId $scope.ScopeId -ErrorAction Stop
            }
            catch {
                $errors.Add([pscustomobject]@{ Timestamp = Get-Date; SourceDhcpServer = $server; ScopeId = $scopeId; Operation = 'Get-DhcpServerv4ScopeStatistics'; ErrorMessage = $_.Exception.Message })
            }
        }

        try {
            $failover = Get-DhcpServerv4Failover -ComputerName $server -ScopeId $scope.ScopeId -ErrorAction Stop
            if ($failover -is [array]) { $failover = $failover | Select-Object -First 1 }
        }
        catch {
            # A non-failover scope is expected to return no relationship. Record only unexpected errors.
            if ($_.Exception.Message -notmatch 'not.*failover|not found|does not exist|not part') {
                $errors.Add([pscustomobject]@{ Timestamp = Get-Date; SourceDhcpServer = $server; ScopeId = $scopeId; Operation = 'Get-DhcpServerv4Failover'; ErrorMessage = $_.Exception.Message })
            }
        }

        $inUse = Get-PropertyValue -InputObject $statistics -Name @('InUse', 'AddressesInUse')
        $available = Get-PropertyValue -InputObject $statistics -Name @('Free', 'AddressesFree', 'Available')
        $reserved = Get-PropertyValue -InputObject $statistics -Name @('Reserved', 'AddressesReserved')
        $pending = Get-PropertyValue -InputObject $statistics -Name @('Pending', 'AddressesPending')
        $total = Get-PropertyValue -InputObject $statistics -Name @('Total', 'TotalAddresses')
        $percentage = Get-PropertyValue -InputObject $statistics -Name @('PercentageInUse')

        $results.Add([pscustomobject][ordered]@{
            ScopeId                         = $scopeId
            ScopeName                       = [string]$scope.Name
            ScopeDescription                = [string]$scope.Description
            ScopeState                      = [string]$scope.State
            SubnetMask                      = [string]$scope.SubnetMask
            StartRange                      = [string]$scope.StartRange
            EndRange                        = [string]$scope.EndRange
            LeaseDuration                   = Convert-LeaseDuration -LeaseDuration $scope.LeaseDuration
            GatewayOption003                = Get-OptionText -Options $options -OptionId 3
            DnsServersOption006             = Get-OptionText -Options $options -OptionId 6
            DnsDomainNameOption015          = Get-OptionText -Options $options -OptionId 15
            DnsNbtNodeTypeOption046         = Get-OptionText -Options $options -OptionId 46
            DnsUpdateOption081              = Get-OptionText -Options $options -OptionId 81
            DnsDynamicUpdates               = ConvertTo-Text (Get-PropertyValue -InputObject $dnsSetting -Name @('DynamicUpdates'))
            DnsDeleteDnsRROnLeaseExpiry     = Get-PropertyValue -InputObject $dnsSetting -Name @('DeleteDnsRROnLeaseExpiry')
            DnsUpdateDnsRRForOlderClients   = Get-PropertyValue -InputObject $dnsSetting -Name @('UpdateDnsRRForOlderClients')
            DnsDisableDnsPtrRRUpdate        = Get-PropertyValue -InputObject $dnsSetting -Name @('DisableDnsPtrRRUpdate')
            DnsNameProtection               = Get-PropertyValue -InputObject $dnsSetting -Name @('NameProtection')
            DnsSettingPolicyName            = ConvertTo-Text (Get-PropertyValue -InputObject $dnsSetting -Name @('PolicyName'))
            FailoverEnabled                 = [bool]($null -ne $failover)
            FailoverRelationshipName        = ConvertTo-Text (Get-PropertyValue -InputObject $failover -Name @('Name'))
            FailoverMode                    = ConvertTo-Text (Get-PropertyValue -InputObject $failover -Name @('Mode'))
            FailoverServerRole              = ConvertTo-Text (Get-PropertyValue -InputObject $failover -Name @('ServerRole'))
            FailoverPartnerServer           = ConvertTo-Text (Get-PropertyValue -InputObject $failover -Name @('PartnerServer'))
            FailoverState                   = ConvertTo-Text (Get-PropertyValue -InputObject $failover -Name @('State'))
            FailoverReservePercent          = Get-PropertyValue -InputObject $failover -Name @('ReservePercent')
            FailoverLoadBalancePercent      = Get-PropertyValue -InputObject $failover -Name @('LoadBalancePercent')
            FailoverMaxClientLeadTime       = ConvertTo-Text (Get-PropertyValue -InputObject $failover -Name @('MaxClientLeadTime'))
            FailoverStateSwitchInterval     = ConvertTo-Text (Get-PropertyValue -InputObject $failover -Name @('StateSwitchInterval'))
            CurrentLeasesIssued             = $inUse
            CurrentAddressesAvailable       = $available
            ReservedAddresses               = $reserved
            PendingAddresses                = $pending
            TotalAddresses                  = $total
            PercentageInUse                 = $percentage
            CollectedAt                     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            SourceDhcpServer                = $server
        })
    }
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

if ($results.Count -gt 0) {
    $results | Sort-Object SourceDhcpServer, ScopeId | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($results.Count) scope record(s) to: $OutputPath" -ForegroundColor Green
}
else {
    Write-Warning 'No scope records were collected. Review connectivity, permissions, and the error log.'
}

if ($errors.Count -gt 0) {
    $errorDirectory = Split-Path -Path $ErrorLogPath -Parent
    if ($errorDirectory -and -not (Test-Path -LiteralPath $errorDirectory)) {
        New-Item -ItemType Directory -Path $errorDirectory -Force | Out-Null
    }
    $errors | Export-Csv -LiteralPath $ErrorLogPath -NoTypeInformation -Encoding UTF8
    Write-Warning "Completed with $($errors.Count) query error(s). Error log: $ErrorLogPath"
}
else {
    Write-Host 'Completed without query errors.' -ForegroundColor Green
}

# Return collected rows to the pipeline for optional downstream processing.
$results
