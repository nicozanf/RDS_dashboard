param(
    [string]$BaseUrl = 'https://localhost',
    [string]$SessionToken,
    [string]$CookieName = 'RDSAUTH',
    [System.Management.Automation.PSCredential]$Credential,
    [string]$HistoryServerName = '',
    [int]$MinimumFarmRowsLast8Days = 1,
    [int]$MinimumServerRowsLast1Hour = 0,
    [int]$ZeroSessionsConsecutiveThreshold = 0,
    [int]$ZeroSessionsCheckCount = 3,
    [int]$ZeroSessionsCheckDelaySeconds = 5,
    [int]$TimedOutServersConsecutiveThreshold = 0,
    [int]$TimedOutServersMinimum = 1,
    [int]$TimedOutServersCheckCount = 3,
    [int]$TimedOutServersCheckDelaySeconds = 5,
    [switch]$SkipSqliteChecks,
    [string]$CsrfToken = '',
    [switch]$InvokeRestartCheck,
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
$script:OriginalSecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol
$script:OriginalCertificateCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
$script:InvokeWebRequestSupportsSkipCertificateCheck = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')
$script:EffectiveSkipCertificateCheck = $false

function Initialize-WebRequestEnvironment {
    param([switch]$SkipCertificateCheck)

    $script:EffectiveSkipCertificateCheck = [bool]$SkipCertificateCheck

    try {
        $tls12 = [System.Net.SecurityProtocolType]::Tls12
        if (($script:OriginalSecurityProtocol -band $tls12) -eq 0) {
            [System.Net.ServicePointManager]::SecurityProtocol = ($script:OriginalSecurityProtocol -bor $tls12)
        }
    }
    catch {}

    if ($SkipCertificateCheck -and -not $script:InvokeWebRequestSupportsSkipCertificateCheck) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
}

function Restore-WebRequestEnvironment {
    [System.Net.ServicePointManager]::SecurityProtocol = $script:OriginalSecurityProtocol
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $script:OriginalCertificateCallback
}

function Get-FriendlyWebExceptionMessage {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match 'trust relationship for the SSL/TLS secure channel') {
        return 'TLS certificate validation failed. Re-run the script with -SkipCertificateCheck when testing the isolated server certificate.'
    }

    return $message
}

function Test-IsTlsTrustError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    return ($message -match 'trust relationship for the SSL/TLS secure channel')
}

function Invoke-WebRequestCompat {
    param(
        [Parameter(Mandatory = $true)][hashtable]$InvokeParams,
        [switch]$SkipCertificateCheck
    )

    $useSkipCertificateCheck = ($SkipCertificateCheck -or $script:EffectiveSkipCertificateCheck)
    if ($useSkipCertificateCheck -and $script:InvokeWebRequestSupportsSkipCertificateCheck) {
        $InvokeParams.SkipCertificateCheck = $true
    }
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('UseBasicParsing')) {
        $InvokeParams.UseBasicParsing = $true
    }

    try {
        return (Invoke-WebRequest @InvokeParams)
    }
    catch {
        if (-not $useSkipCertificateCheck -and (Test-IsTlsTrustError -ErrorRecord $_)) {
            Write-Warning 'TLS trust failed; retrying once with certificate validation disabled for this validation run.'
            Initialize-WebRequestEnvironment -SkipCertificateCheck
            if ($script:InvokeWebRequestSupportsSkipCertificateCheck) {
                $InvokeParams.SkipCertificateCheck = $true
            }
            return (Invoke-WebRequest @InvokeParams)
        }

        throw (Get-FriendlyWebExceptionMessage -ErrorRecord $_)
    }
}

function Assert-HasProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$ContextLabel
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$PropertyName]) {
        throw "$ContextLabel is missing required property '$PropertyName'."
    }
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory = $true)][securestring]$SecureValue)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Assert-TextContains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$ContextLabel
    )

    if ([string]::IsNullOrWhiteSpace($Text) -or -not $Text.Contains($Expected)) {
        throw "$ContextLabel does not contain expected text '$Expected'."
    }
}

function Get-CsrfTokenFromHtml {
    param([Parameter(Mandatory = $true)][string]$Html)

    $patterns = @(
        "const\s+csrfToken\s*=\s*'([^']*)'",
        'const\s+csrfToken\s*=\s*"([^"]*)"',
        "const\s+csrfToken\s*=\s*\`'([^\`']*)\`'",
        'const\s+csrfToken\s*=\s*`"([^`"]*)`"',
        "const\s+csrfToken\s*=\s*['\`]([^'\`]*)['\`]"
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Html, $pattern)
        if ($match.Success) {
            return [string]$match.Groups[1].Value
        }
    }

    return ''
}

function Invoke-TextGet {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)]$WebSession,
        [switch]$SkipCertificateCheck
    )

    $invokeParams = @{
        Uri = $Url
        Method = 'GET'
        WebSession = $WebSession
    }

    return (Invoke-WebRequestCompat -InvokeParams $invokeParams -SkipCertificateCheck:$SkipCertificateCheck)
}

function Invoke-Login {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)]$WebSession,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [switch]$SkipCertificateCheck
    )

    $password = ConvertTo-PlainText -SecureValue $Credential.Password
    try {
        $body = 'username={0}&password={1}' -f [System.Uri]::EscapeDataString($Credential.UserName), [System.Uri]::EscapeDataString($password)
        $invokeParams = @{
            Uri = ("{0}/login" -f $BaseUrl.TrimEnd('/'))
            Method = 'POST'
            WebSession = $WebSession
            Body = $body
            ContentType = 'application/x-www-form-urlencoded'
        }

        $response = Invoke-WebRequestCompat -InvokeParams $invokeParams -SkipCertificateCheck:$SkipCertificateCheck
        return $response
    }
    finally {
        $password = $null
    }
}

function Get-SessionCookieValue {
    param(
        [Parameter(Mandatory = $true)]$WebSession,
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)][string]$CookieName
    )

    $cookies = @($WebSession.Cookies.GetCookies($Uri) | Where-Object { $_.Name -eq $CookieName })
    if ($cookies.Count -gt 0) {
        return [string]$cookies[0].Value
    }

    return ''
}

function Invoke-JsonGet {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)]$WebSession,
        [switch]$SkipCertificateCheck
    )

    $invokeParams = @{
        Uri = $Url
        Method = 'GET'
        WebSession = $WebSession
        Headers = @{ Accept = 'application/json' }
    }

    $response = Invoke-WebRequestCompat -InvokeParams $invokeParams -SkipCertificateCheck:$SkipCertificateCheck
    return ($response.Content | ConvertFrom-Json)
}

function Invoke-JsonPost {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)]$WebSession,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [string]$Body = '',
        [switch]$SkipCertificateCheck
    )

    # Add Referer header for CSRF validation (same-origin check)
    $urlObj = [Uri]$Url
    $referer = "$($urlObj.Scheme)://$($urlObj.Host)$(if ($urlObj.Port -ne 80 -and $urlObj.Port -ne 443) { ":$($urlObj.Port)" })/health"
    
    $invokeParams = @{
        Uri = $Url
        Method = 'POST'
        WebSession = $WebSession
        Headers = $Headers + @{ Referer = $referer }
        Body = $Body
        ContentType = 'application/x-www-form-urlencoded'
    }

    $response = Invoke-WebRequestCompat -InvokeParams $invokeParams -SkipCertificateCheck:$SkipCertificateCheck
    return ($response.Content | ConvertFrom-Json)
}

try {
    Initialize-WebRequestEnvironment -SkipCertificateCheck:$SkipCertificateCheck

    $normalizedBaseUrl = $BaseUrl.TrimEnd('/')
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $uri = [Uri]$normalizedBaseUrl
    $authMode = 'cookie'

    if (-not [string]::IsNullOrWhiteSpace($SessionToken)) {
        $cookie = New-Object System.Net.Cookie($CookieName, $SessionToken, '/', $uri.Host)
        $session.Cookies.Add($cookie)
    }
    else {
        if ($null -eq $Credential) {
            $Credential = Get-Credential -Message ('Enter dashboard credentials for {0}' -f $normalizedBaseUrl)
        }

        if ($null -eq $Credential) {
            throw 'Authentication was cancelled. Provide a SessionToken or valid credentials.'
        }

        $loginResponse = Invoke-Login -BaseUrl $normalizedBaseUrl -WebSession $session -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck
        $sessionTokenFromLogin = Get-SessionCookieValue -WebSession $session -Uri $uri -CookieName $CookieName
        if ([string]::IsNullOrWhiteSpace($sessionTokenFromLogin)) {
            $statusCode = if ($null -ne $loginResponse) { [int]$loginResponse.StatusCode } else { -1 }
            throw "Login did not yield an authenticated $CookieName cookie (HTTP $statusCode). Check credentials and dashboard reachability."
        }

        $SessionToken = $sessionTokenFromLogin
        $authMode = 'login'
    }

    $dashboardUrl = "$normalizedBaseUrl/dashboard"
    $healthPageUrl = "$normalizedBaseUrl/health"
    $healthUrl = "$normalizedBaseUrl/api/health"
    $dataUrl = "$normalizedBaseUrl/api/data"
    $historyUrl = "$normalizedBaseUrl/api/history-debug"
    if (-not [string]::IsNullOrWhiteSpace($HistoryServerName)) {
        $historyUrl = "$historyUrl?name=$([System.Uri]::EscapeDataString($HistoryServerName))"
    }

    $dashboardPage = Invoke-TextGet -Url $dashboardUrl -WebSession $session -SkipCertificateCheck:$SkipCertificateCheck
    if ([int]$dashboardPage.StatusCode -ne 200) {
        throw "Dashboard page returned HTTP $($dashboardPage.StatusCode)."
    }
    Assert-TextContains -Text ([string]$dashboardPage.Content) -Expected 'Signed in as' -ContextLabel 'Dashboard page'
    Assert-TextContains -Text ([string]$dashboardPage.Content) -Expected 'Health status' -ContextLabel 'Dashboard page'

    $healthPage = Invoke-TextGet -Url $healthPageUrl -WebSession $session -SkipCertificateCheck:$SkipCertificateCheck
    if ([int]$healthPage.StatusCode -ne 200) {
        throw "Health page returned HTTP $($healthPage.StatusCode)."
    }
    Assert-TextContains -Text ([string]$healthPage.Content) -Expected 'Service Health' -ContextLabel 'Health page'
    Assert-TextContains -Text ([string]$healthPage.Content) -Expected 'Restart collector' -ContextLabel 'Health page'

    $effectiveCsrfToken = [string]$CsrfToken
    if ([string]::IsNullOrWhiteSpace($effectiveCsrfToken)) {
        $effectiveCsrfToken = Get-CsrfTokenFromHtml -Html ([string]$healthPage.Content)
    }
    if ([string]::IsNullOrWhiteSpace($effectiveCsrfToken)) {
        $effectiveCsrfToken = Get-CsrfTokenFromHtml -Html ([string]$dashboardPage.Content)
    }

    $health = Invoke-JsonGet -Url $healthUrl -WebSession $session -SkipCertificateCheck:$SkipCertificateCheck
    Assert-HasProperty -Object $health -PropertyName 'Collector' -ContextLabel 'Health payload'
    Assert-HasProperty -Object $health -PropertyName 'Snapshot' -ContextLabel 'Health payload'
    Assert-HasProperty -Object $health -PropertyName 'Sqlite' -ContextLabel 'Health payload'
    Assert-HasProperty -Object $health.Collector -PropertyName 'HealthState' -ContextLabel 'Health payload Collector'
    Assert-HasProperty -Object $health.Collector -PropertyName 'StatusText' -ContextLabel 'Health payload Collector'
    Assert-HasProperty -Object $health.Collector -PropertyName 'Restart' -ContextLabel 'Health payload Collector'
    Assert-HasProperty -Object $health.Collector.Restart -PropertyName 'CooldownRemainingSeconds' -ContextLabel 'Health payload Collector.Restart'
    Assert-HasProperty -Object $health.Collector.Restart -PropertyName 'WarningActive' -ContextLabel 'Health payload Collector.Restart'
    Assert-HasProperty -Object $health.Collector.Restart -PropertyName 'WarningReason' -ContextLabel 'Health payload Collector.Restart'
    Assert-HasProperty -Object $health.Snapshot -PropertyName 'AgeSeconds' -ContextLabel 'Health payload Snapshot'
    Assert-HasProperty -Object $health.Snapshot -PropertyName 'TimedOutServersCount' -ContextLabel 'Health payload Snapshot'
    Assert-HasProperty -Object $health.Sqlite -PropertyName 'Enabled' -ContextLabel 'Health payload Sqlite'
    Assert-HasProperty -Object $health.Sqlite -PropertyName 'DatabaseExists' -ContextLabel 'Health payload Sqlite'

    $timedOutServersSamples = @()
    $timedOutServersConsecutiveCount = 0
    $timedOutServersMaxConsecutiveCount = 0
    $timedOutServersThresholdTriggered = $false
    $effectiveTimedOutServersMinimum = [math]::Max(1, $TimedOutServersMinimum)
    $previousHealthSnapshotTs = ''

    if ($TimedOutServersConsecutiveThreshold -gt 0) {
        $effectiveTimedOutCheckCount = [math]::Max($TimedOutServersConsecutiveThreshold, [math]::Max(1, $TimedOutServersCheckCount))
        $effectiveTimedOutCheckDelaySeconds = [math]::Max(1, $TimedOutServersCheckDelaySeconds)
        $healthSample = $health

        for ($sampleIndex = 1; $sampleIndex -le $effectiveTimedOutCheckCount; $sampleIndex++) {
            if ($sampleIndex -gt 1) {
                Start-Sleep -Seconds $effectiveTimedOutCheckDelaySeconds
                $healthSample = Invoke-JsonGet -Url $healthUrl -WebSession $session -SkipCertificateCheck:$SkipCertificateCheck
            }

            $sampleGeneratedAt = ''
            $sampleTimedOutCount = 0
            try {
                $sampleGeneratedAt = [string]$healthSample.Snapshot.GeneratedAtUtc
            }
            catch {}

            try {
                $sampleTimedOutCount = [int]$healthSample.Snapshot.TimedOutServersCount
            }
            catch {
                $sampleTimedOutCount = 0
            }

            $isDuplicateSnapshot = (
                -not [string]::IsNullOrWhiteSpace($sampleGeneratedAt) -and
                -not [string]::IsNullOrWhiteSpace($previousHealthSnapshotTs) -and
                ($sampleGeneratedAt -eq $previousHealthSnapshotTs)
            )

            $timedOutServersSamples += [PSCustomObject]@{
                SampleIndex = $sampleIndex
                GeneratedAtUtc = $sampleGeneratedAt
                TimedOutServersCount = $sampleTimedOutCount
                DuplicateSnapshot = $isDuplicateSnapshot
            }

            if (-not $isDuplicateSnapshot) {
                if ($sampleTimedOutCount -ge $effectiveTimedOutServersMinimum) {
                    $timedOutServersConsecutiveCount++
                    $timedOutServersMaxConsecutiveCount = [math]::Max($timedOutServersMaxConsecutiveCount, $timedOutServersConsecutiveCount)
                }
                else {
                    $timedOutServersConsecutiveCount = 0
                }

                if (-not [string]::IsNullOrWhiteSpace($sampleGeneratedAt)) {
                    $previousHealthSnapshotTs = $sampleGeneratedAt
                }
            }

            if ($timedOutServersConsecutiveCount -ge $TimedOutServersConsecutiveThreshold) {
                $timedOutServersThresholdTriggered = $true
                $health = $healthSample
                break
            }

            $health = $healthSample
        }

        if ($timedOutServersThresholdTriggered) {
            $sampleSummary = ($timedOutServersSamples | ForEach-Object {
                    ('#{0}: ts={1}, timedOut={2}' -f $_.SampleIndex, $_.GeneratedAtUtc, $_.TimedOutServersCount)
                }) -join '; '
            throw "TimedOutServersCount stayed >= $effectiveTimedOutServersMinimum for at least $TimedOutServersConsecutiveThreshold consecutive health checks. Samples: $sampleSummary"
        }
    }

    if (-not $SkipSqliteChecks) {
        if (-not [bool]$health.Sqlite.Enabled) {
            throw 'Health payload reports SQLite disabled, but SQLite mode is required for this test run.'
        }

        if (-not [bool]$health.Sqlite.DatabaseExists) {
            throw "Health payload reports missing SQLite database file at '$($health.Sqlite.DatabasePath)'."
        }
    }

    $data = Invoke-JsonGet -Url $dataUrl -WebSession $session -SkipCertificateCheck:$SkipCertificateCheck
    Assert-HasProperty -Object $data -PropertyName 'GeneratedAtUtc' -ContextLabel 'Data payload'
    Assert-HasProperty -Object $data -PropertyName 'Summary' -ContextLabel 'Data payload'
    Assert-HasProperty -Object $data -PropertyName 'Servers' -ContextLabel 'Data payload'
    Assert-HasProperty -Object $data -PropertyName 'Sessions' -ContextLabel 'Data payload'
    Assert-HasProperty -Object $data -PropertyName 'NextCycleDelaySeconds' -ContextLabel 'Data payload'

    $zeroSessionSamples = @()
    $zeroSessionConsecutiveCount = 0
    $zeroSessionMaxConsecutiveCount = 0
    $zeroSessionThresholdTriggered = $false
    $previousDataSnapshotTs = ''

    if ($ZeroSessionsConsecutiveThreshold -gt 0) {
        $effectiveCheckCount = [math]::Max($ZeroSessionsConsecutiveThreshold, [math]::Max(1, $ZeroSessionsCheckCount))
        $effectiveDelaySeconds = [math]::Max(1, $ZeroSessionsCheckDelaySeconds)
        $dataSample = $data

        for ($sampleIndex = 1; $sampleIndex -le $effectiveCheckCount; $sampleIndex++) {
            if ($sampleIndex -gt 1) {
                Start-Sleep -Seconds $effectiveDelaySeconds
                $dataSample = Invoke-JsonGet -Url $dataUrl -WebSession $session -SkipCertificateCheck:$SkipCertificateCheck
            }

            $sampleGeneratedAt = ''
            $sampleSessionsCount = 0
            try {
                $sampleGeneratedAt = [string]$dataSample.GeneratedAtUtc
            }
            catch {}

            try {
                $sampleSessionsCount = @($dataSample.Sessions).Count
            }
            catch {
                $sampleSessionsCount = 0
            }

            $isDuplicateSnapshot = (
                -not [string]::IsNullOrWhiteSpace($sampleGeneratedAt) -and
                -not [string]::IsNullOrWhiteSpace($previousDataSnapshotTs) -and
                ($sampleGeneratedAt -eq $previousDataSnapshotTs)
            )

            $zeroSessionSamples += [PSCustomObject]@{
                SampleIndex = $sampleIndex
                GeneratedAtUtc = $sampleGeneratedAt
                SessionsCount = $sampleSessionsCount
                DuplicateSnapshot = $isDuplicateSnapshot
            }

            if (-not $isDuplicateSnapshot) {
                if ($sampleSessionsCount -eq 0) {
                    $zeroSessionConsecutiveCount++
                    $zeroSessionMaxConsecutiveCount = [math]::Max($zeroSessionMaxConsecutiveCount, $zeroSessionConsecutiveCount)
                }
                else {
                    $zeroSessionConsecutiveCount = 0
                }

                if (-not [string]::IsNullOrWhiteSpace($sampleGeneratedAt)) {
                    $previousDataSnapshotTs = $sampleGeneratedAt
                }
            }

            if ($zeroSessionConsecutiveCount -ge $ZeroSessionsConsecutiveThreshold) {
                $zeroSessionThresholdTriggered = $true
                break
            }
        }

        if ($zeroSessionThresholdTriggered) {
            $sampleSummary = ($zeroSessionSamples | ForEach-Object {
                    ('#{0}: ts={1}, sessions={2}' -f $_.SampleIndex, $_.GeneratedAtUtc, $_.SessionsCount)
                }) -join '; '
            throw "Data payload sessions stayed at 0 for at least $ZeroSessionsConsecutiveThreshold consecutive checks. Samples: $sampleSummary"
        }
    }

    $history = Invoke-JsonGet -Url $historyUrl -WebSession $session -SkipCertificateCheck:$SkipCertificateCheck
    Assert-HasProperty -Object $history -PropertyName 'SqliteEnabled' -ContextLabel 'History debug payload'
    Assert-HasProperty -Object $history -PropertyName 'DbExists' -ContextLabel 'History debug payload'
    Assert-HasProperty -Object $history -PropertyName 'FarmRowsLast8Days' -ContextLabel 'History debug payload'
    Assert-HasProperty -Object $history -PropertyName 'DbQueryError' -ContextLabel 'History debug payload'
    Assert-HasProperty -Object $history -PropertyName 'Snapshot' -ContextLabel 'History debug payload'
    Assert-HasProperty -Object $history.Snapshot -PropertyName 'GeneratedAtUtc' -ContextLabel 'History debug Snapshot'
    Assert-HasProperty -Object $history.Snapshot -PropertyName 'SnapshotReadError' -ContextLabel 'History debug Snapshot'

    if (-not $SkipSqliteChecks) {
        if (-not [bool]$history.SqliteEnabled) {
            throw 'History debug payload reports SQLite disabled, but SQLite mode is required for this test run.'
        }

        if (-not [bool]$history.DbExists) {
            throw "History debug payload reports missing SQLite database file at '$($history.DbPath)'."
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$history.DbQueryError)) {
            throw "History debug payload reports SQLite query error: $($history.DbQueryError)"
        }

        $farmRows = 0
        try {
            $farmRows = [int]$history.FarmRowsLast8Days
        }
        catch {
            throw "Unable to parse FarmRowsLast8Days ('$($history.FarmRowsLast8Days)')."
        }

        if ($farmRows -lt $MinimumFarmRowsLast8Days) {
            throw "SQLite farm history rows are too low. Expected at least $MinimumFarmRowsLast8Days rows in the last 8 days, found $farmRows."
        }

        if (-not [string]::IsNullOrWhiteSpace($HistoryServerName)) {
            Assert-HasProperty -Object $history -PropertyName 'ServerRowsLast1Hour' -ContextLabel 'History debug payload'
            $serverRows = 0
            try {
                $serverRows = [int]$history.ServerRowsLast1Hour
            }
            catch {
                throw "Unable to parse ServerRowsLast1Hour ('$($history.ServerRowsLast1Hour)') for server '$HistoryServerName'."
            }

            if ($serverRows -lt $MinimumServerRowsLast1Hour) {
                throw "SQLite server history rows are too low for '$HistoryServerName'. Expected at least $MinimumServerRowsLast1Hour row(s) in the last hour, found $serverRows."
            }
        }
    }

    $restartCheck = $null
    if ($InvokeRestartCheck) {
        if ([string]::IsNullOrWhiteSpace($effectiveCsrfToken)) {
            throw 'CsrfToken is required when InvokeRestartCheck is specified and could not be extracted from the authenticated HTML pages.'
        }

        $restartUrl = "$normalizedBaseUrl/api/health/restart-collector"
        $restartCheck = Invoke-JsonPost -Url $restartUrl -WebSession $session -Headers @{ Accept = 'application/json'; 'X-CSRF-Token' = $effectiveCsrfToken } -Body '' -SkipCertificateCheck:$SkipCertificateCheck
        Assert-HasProperty -Object $restartCheck -PropertyName 'Success' -ContextLabel 'Restart response'
        Assert-HasProperty -Object $restartCheck -PropertyName 'State' -ContextLabel 'Restart response'
        Assert-HasProperty -Object $restartCheck -PropertyName 'Blocked' -ContextLabel 'Restart response'
    }

    [PSCustomObject]@{
        BaseUrl = $normalizedBaseUrl
        AuthMode = $authMode
        DashboardPageStatusCode = [int]$dashboardPage.StatusCode
        HealthPageStatusCode = [int]$healthPage.StatusCode
        CsrfTokenSource = if (-not [string]::IsNullOrWhiteSpace([string]$CsrfToken)) { 'parameter' } elseif (-not [string]::IsNullOrWhiteSpace($effectiveCsrfToken)) { 'html' } else { 'missing' }
        HealthState = [string]$health.Collector.HealthState
        CollectorStatusText = [string]$health.Collector.StatusText
        CollectorState = [string]$health.Collector.State
        SqliteEnabled = [bool]$health.Sqlite.Enabled
        SqliteDatabaseExists = [bool]$health.Sqlite.DatabaseExists
        SqliteDatabasePath = [string]$health.Sqlite.DatabasePath
        DashboardGeneratedAtUtc = [string]$data.GeneratedAtUtc
        DashboardServersCount = @($data.Servers).Count
        DashboardSessionsCount = @($data.Sessions).Count
        ZeroSessionsConsecutiveThreshold = $ZeroSessionsConsecutiveThreshold
        ZeroSessionsCheckCount = if ($ZeroSessionsConsecutiveThreshold -gt 0) { [math]::Max($ZeroSessionsConsecutiveThreshold, [math]::Max(1, $ZeroSessionsCheckCount)) } else { 0 }
        ZeroSessionsCheckDelaySeconds = if ($ZeroSessionsConsecutiveThreshold -gt 0) { [math]::Max(1, $ZeroSessionsCheckDelaySeconds) } else { 0 }
        ZeroSessionsMaxConsecutiveObserved = $zeroSessionMaxConsecutiveCount
        ZeroSessionsSamples = ($zeroSessionSamples | ForEach-Object {
            ('#{0}: ts={1}, sessions={2}, duplicate={3}' -f $_.SampleIndex, $_.GeneratedAtUtc, $_.SessionsCount, $_.DuplicateSnapshot)
            }) -join '; '
        SnapshotAgeSeconds = $health.Snapshot.AgeSeconds
        TimedOutServersCount = $health.Snapshot.TimedOutServersCount
        FailedServersCount = $health.Snapshot.FailedServersCount
        TimedOutServersConsecutiveThreshold = $TimedOutServersConsecutiveThreshold
        TimedOutServersMinimum = $effectiveTimedOutServersMinimum
        TimedOutServersCheckCount = if ($TimedOutServersConsecutiveThreshold -gt 0) { [math]::Max($TimedOutServersConsecutiveThreshold, [math]::Max(1, $TimedOutServersCheckCount)) } else { 0 }
        TimedOutServersCheckDelaySeconds = if ($TimedOutServersConsecutiveThreshold -gt 0) { [math]::Max(1, $TimedOutServersCheckDelaySeconds) } else { 0 }
        TimedOutServersMaxConsecutiveObserved = $timedOutServersMaxConsecutiveCount
        TimedOutServersSamples = ($timedOutServersSamples | ForEach-Object {
            ('#{0}: ts={1}, timedOut={2}, duplicate={3}' -f $_.SampleIndex, $_.GeneratedAtUtc, $_.TimedOutServersCount, $_.DuplicateSnapshot)
            }) -join '; '
        FarmRowsLast8Days = [int]$history.FarmRowsLast8Days
        ServerRowsLast1Hour = if ($history.PSObject.Properties['ServerRowsLast1Hour']) { [int]$history.ServerRowsLast1Hour } else { $null }
        HistoryDbQueryError = [string]$history.DbQueryError
        RestartRequestsLastHour = $health.Collector.Restart.RequestsLastHour
        RestartCooldownRemainingSeconds = $health.Collector.Restart.CooldownRemainingSeconds
        RestartWarningReason = [string]$health.Collector.Restart.WarningReason
        HistorySnapshotGeneratedAtUtc = [string]$history.Snapshot.GeneratedAtUtc
        HistorySnapshotReadError = [string]$history.Snapshot.SnapshotReadError
        RestartCheckSuccess = if ($null -ne $restartCheck) { $restartCheck.Success } else { $null }
        RestartCheckBlocked = if ($null -ne $restartCheck) { $restartCheck.Blocked } else { $null }
        RestartCheckState = if ($null -ne $restartCheck) { [string]$restartCheck.State } else { '' }
    } | Format-List
}
finally {
    Restore-WebRequestEnvironment
}