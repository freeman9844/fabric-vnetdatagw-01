#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $EvidencePath
)

$ErrorActionPreference = 'Stop'

function Assert-Evidence([bool] $Condition, [string] $Reason) {
    if (-not $Condition) { throw [FormatException]::new($Reason) }
}

function Test-Ipv4($Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z') {
        return $false
    }

    $ip = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref] $ip)
}

function Test-DnsName($Value) {
    return $Value -is [string] -and [Uri]::CheckHostName($Value) -eq [UriHostNameType]::Dns
}

function Test-ProbeId($Value) {
    return $Value -is [string] -and $Value -match '\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z'
}

function Test-Status($Value, [int] $Expected) {
    return ($Value -is [int] -or $Value -is [long]) -and $Value -eq $Expected
}

function ConvertTo-Utc($Value, [string] $Field) {
    Assert-Evidence ($Value -is [string] -and $Value -cmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,7})?(?:Z|\+00:00)\z') `
        "$Field 값은 UTC 시각이어야 합니다."
    $utc = [DateTimeOffset]::MinValue
    Assert-Evidence ([DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref] $utc)) "$Field 값이 올바른 시각이 아닙니다."
    return $utc
}

function Get-RunWindow($Record, [string] $Label) {
    $start = ConvertTo-Utc $Record.fromUtc "$Label.fromUtc"
    $end = ConvertTo-Utc $Record.toUtc "$Label.toUtc"
    Assert-Evidence ($start -lt $end) "$Label 시간창이 유효하지 않습니다."
    return @{ start = $start; end = $end }
}

function Get-WindowRows([array] $Rows, $Window, [string] $MockHost) {
    $Rows | Where-Object { $_.host -eq $MockHost -and $_.time -ge $Window.start -and $_.time -le $Window.end }
}

try {
    $raw = Get-Content -LiteralPath $EvidencePath -Raw
} catch {
    Write-Error -ErrorAction Continue '증거 파일을 읽을 수 없습니다. 경로와 읽기 권한을 확인하세요.'
    exit 1
}

try {
    $evidence = ConvertFrom-Json -InputObject $raw -AsHashtable -DateKind String -Depth 10 -NoEnumerate
} catch {
    Write-Error -ErrorAction Continue '증거 파일을 JSON으로 읽을 수 없습니다.'
    exit 1
}

try {
    Assert-Evidence ($evidence -is [System.Collections.IDictionary]) '증거는 JSON 객체여야 합니다.'
    $nat = $evidence.natIpv4
    $mockHost = $evidence.host
    Assert-Evidence (Test-Ipv4 $nat) 'NAT 주소는 표준 점 표기의 IPv4여야 합니다.'
    Assert-Evidence (Test-DnsName $mockHost) 'Mock API의 DNS 호스트 이름이 필요합니다.'
    Assert-Evidence ($evidence.fabric -is [array] -and $evidence.fabric.Count -eq 2) 'Fabric 실행이 정확히 두 건이어야 합니다.'
    Assert-Evidence ($evidence.http -is [array] -and $evidence.http.Count -ge 2) 'HTTP 수신 로그가 누락됐습니다.'
    Assert-Evidence ($evidence.audit -is [array] -and $evidence.audit.Count -ge 3) 'IP 접근 감사 로그가 누락됐습니다.'

    $httpRows = foreach ($row in $evidence.http) {
        Assert-Evidence ($row -is [System.Collections.IDictionary] -and (Test-DnsName $row.host) -and
            (Test-ProbeId $row.probeId) -and (Test-Ipv4 $row.clientIp) -and
            ($row.status -is [int] -or $row.status -is [long])) 'HTTP 수신 로그에 잘못된 필드가 있습니다.'
        $row.time = ConvertTo-Utc $row.timeUtc 'http.timeUtc'
        $row
    }
    $auditRows = foreach ($row in $evidence.audit) {
        Assert-Evidence ($row -is [System.Collections.IDictionary] -and (Test-DnsName $row.host) -and
            (Test-Ipv4 $row.clientIp) -and $row.result -is [string] -and
            $row.result -cin @('Allowed', 'Denied')) 'IP 접근 감사 로그에 잘못된 필드가 있습니다.'
        $row.time = ConvertTo-Utc $row.timeUtc 'audit.timeUtc'
        $row
    }

    $runIds = @()
    $probeIds = @()
    $windows = @()
    foreach ($run in $evidence.fabric) {
        Assert-Evidence ($run -is [System.Collections.IDictionary] -and $run.runId -is [string] -and
            -not [string]::IsNullOrWhiteSpace($run.runId) -and (Test-ProbeId $run.probeId)) 'Fabric 실행 또는 프로브 식별자가 유효하지 않습니다.'
        Assert-Evidence ($run.runId -notin $runIds -and $run.probeId -notin $probeIds) 'Fabric 실행 ID 또는 프로브 ID가 중복됐습니다.'
        Assert-Evidence ($run.status -is [string] -and $run.status -ceq 'Completed' -and $run.landedProbeId -is [string] -and
            $run.landedProbeId -ceq $run.probeId) 'Fabric 실행이 완료되지 않았거나 Lakehouse 프로브가 일치하지 않습니다.'
        $runIds += $run.runId
        $probeIds += $run.probeId

        $window = Get-RunWindow $run 'fabric'
        $windows += $window
        $http = @(Get-WindowRows $httpRows $window $mockHost | Where-Object { $_.probeId -ceq $run.probeId })
        Assert-Evidence ($http.Count -eq 1 -and $http[0].status -eq 200 -and
            $http[0].clientIp -ceq $nat) '같은 호스트·경로·시간창에서 NAT IP의 HTTP 200 수신 로그가 정확히 하나여야 합니다.'
        $natAudit = @(Get-WindowRows $auditRows $window $mockHost | Where-Object { $_.clientIp -ceq $nat })
        Assert-Evidence ($natAudit.Count -gt 0 -and 'Denied' -cnotin $natAudit.result) `
            'Fabric 시간창에서 NAT IP의 Allowed 감사 로그가 없거나 접근 판정이 상충합니다.'
    }

    $negative = $evidence.negative
    Assert-Evidence ($negative -is [System.Collections.IDictionary] -and
        (Test-Status $negative.status 403) -and (Test-ProbeId $negative.probeId) -and
        $negative.probeId -cin $probeIds) '부정 검사는 동일한 프로브 경로에서 관측한 HTTP 403이어야 합니다.'
    $window = Get-RunWindow $negative 'negative'
    $sorted = @($windows + $window | Sort-Object { $_.start })
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        Assert-Evidence ($sorted[$i - 1].end -lt $sorted[$i].start) '관측 시간창이 겹칩니다.'
    }

    $negativeAudit = @(Get-WindowRows $auditRows $window $mockHost)
    $denied = @($negativeAudit | Where-Object result -CEQ 'Denied')
    Assert-Evidence ($denied.Count -eq 1 -and $denied[0].clientIp -cne $nat) `
        '부정 검사 시간창에서 NAT와 다른 IPv4의 Denied 감사 기록이 정확히 하나여야 합니다.'
    $deniedIp = $denied[0].clientIp
    Assert-Evidence (-not ($negativeAudit | Where-Object { $_.clientIp -ceq $deniedIp -and $_.result -ceq 'Allowed' })) `
        '부정 검사 출발지에 대한 감사 판정이 상충합니다.'

    # Access restrictions can reject a request before the HTTP request log is written.
    $negativeHttp = @(Get-WindowRows $httpRows $window $mockHost | Where-Object { $_.probeId -ceq $negative.probeId })
    Assert-Evidence ($negativeHttp.Count -eq 0 -or ($negativeHttp.Count -eq 1 -and
        $negativeHttp[0].status -eq 403 -and $negativeHttp[0].clientIp -ceq $deniedIp)) `
        '부정 검사 HTTP 수신 로그와 접근 감사 로그가 일치하지 않습니다.'

    $masked = $deniedIp -replace '\.[0-9]+\z', '.x'
    "통과: Fabric HTTP 200 두 건의 수신 IP가 NAT IPv4 $nat 와 일치합니다. 같은 URL의 비허용 출발지 $masked 는 HTTP 403입니다."
    exit 0
} catch [FormatException] {
    Write-Error -ErrorAction Continue "증거 불충분: $($_.Exception.Message)"
    exit 1
}
