#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
$validator = Join-Path $PSScriptRoot '..\scripts\Confirm-PocEvidence.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw '증거 판정기가 아직 없습니다.'
}

$first = 'd156c3f6-fc88-47ec-a516-6e25bcd5cc2b'
$second = '71ba152b-5fae-4429-870b-68838c8771f0'
$mockHost = 'mock.example.com'
$nat = '192.0.2.10'
$other = '203.0.113.47'
$fixture = @{
    natIpv4 = $nat
    host = $mockHost
    fabric = @(
        @{ runId = 'run-1'; probeId = $first; status = 'Completed'; landedProbeId = $first; fromUtc = '2026-11-20T01:00:00Z'; toUtc = '2026-11-20T01:00:20Z' }
        @{ runId = 'run-2'; probeId = $second; status = 'Completed'; landedProbeId = $second; fromUtc = '2026-11-20T01:01:00Z'; toUtc = '2026-11-20T01:01:20Z' }
    )
    http = @(
        @{ host = $mockHost; probeId = $first; timeUtc = '2026-11-20T01:00:05.1234567Z'; status = 200; clientIp = $nat }
        @{ host = $mockHost; probeId = $second; timeUtc = '2026-11-20T01:01:05Z'; status = 200; clientIp = $nat }
    )
    audit = @(
        @{ host = $mockHost; timeUtc = '2026-11-20T01:00:05Z'; result = 'Allowed'; clientIp = $nat }
        @{ host = $mockHost; timeUtc = '2026-11-20T01:01:05Z'; result = 'Allowed'; clientIp = $nat }
        @{ host = $mockHost; timeUtc = '2026-11-20T01:02:01Z'; result = 'Denied'; clientIp = $other }
    )
    negative = @{ probeId = $first; fromUtc = '2026-11-20T01:02:00Z'; toUtc = '2026-11-20T01:02:02Z'; status = 403 }
}
$json = $fixture | ConvertTo-Json -Depth 6
$cases = @(
    @{ name = '완전한 증거'; code = 0; mutate = {} }
    @{ name = '선택적 403 HTTP 로그 일치'; code = 0; mutate = {
        $e.http += @{ host = $mockHost; probeId = $first; timeUtc = '2026-11-20T01:02:01Z'; status = 403; clientIp = $other }
    } }
    @{ name = 'HTTP 로그 누락'; code = 1; mutate = { $e.Remove('http') } }
    @{ name = 'NAT와 다른 수신 IP'; code = 1; mutate = { $e.http[0].clientIp = $other } }
    @{ name = '중복 Fabric 실행'; code = 1; mutate = { $e.fabric[1].runId = $e.fabric[0].runId } }
    @{ name = '중복 프로브'; code = 1; mutate = { $e.fabric[1].probeId = $first } }
    @{ name = '상태 실패'; code = 1; mutate = { $e.fabric[1].status = 'Failed' } }
    @{ name = '배열로 기록된 Fabric 상태'; code = 1; mutate = { $e.fabric[1].status = @('Failed', 'Completed') } }
    @{ name = 'Lakehouse 적재 불일치'; code = 1; mutate = { $e.fabric[1].landedProbeId = $first } }
    @{ name = 'HTTP 로그 중복'; code = 1; mutate = { $e.http += $e.http[0] } }
    @{ name = 'Allowed 누락'; code = 1; mutate = { $e.audit = $e.audit[1..2] } }
    @{ name = 'NAT IP에 대한 403'; code = 1; mutate = { $e.audit[2].clientIp = $nat } }
    @{ name = '다른 호스트의 Denied'; code = 1; mutate = { $e.audit[2].host = 'other.example.com' } }
    @{ name = '다른 시간창의 Denied'; code = 1; mutate = { $e.audit[2].timeUtc = '2026-11-20T01:01:05Z' } }
    @{ name = 'Fabric 미호출 경로의 403'; code = 1; mutate = { $e.negative.probeId = '56715234-e7ab-473a-b6d0-26ad398a50dc' } }
    @{ name = '중복 Denied'; code = 1; mutate = { $e.audit += $e.audit[2] } }
    @{ name = '403 HTTP 로그와 감사 IP 불일치'; code = 1; mutate = {
        $e.http += @{ host = $mockHost; probeId = $first; timeUtc = '2026-11-20T01:02:01Z'; status = 403; clientIp = $nat }
    } }
    @{ name = '겹치는 관측 시간창'; code = 1; mutate = { $e.fabric[0].toUtc = $e.fabric[1].fromUtc } }
    @{ name = 'UTC 오프셋 누락'; code = 1; mutate = { $e.http[0].timeUtc = '2026-11-20T01:00:05' } }
    @{ name = '비표준 IPv4'; code = 1; mutate = { $e.natIpv4 = '192.0.2.010' } }
    @{ name = '정수가 아닌 HTTP 상태'; code = 1; mutate = { $e.negative.status = '403' } }
)

$file = New-TemporaryFile
try {
    foreach ($case in $cases) {
        $e = $json | ConvertFrom-Json -AsHashtable -DateKind String
        & $case.mutate
        $e | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file.FullName
        $output = (& $validator -EvidencePath $file.FullName 2>&1 | Out-String)
        if ($LASTEXITCODE -ne $case.code) {
            throw "$($case.name): 기대 종료 코드 $($case.code), 실제 $LASTEXITCODE. $output"
        }
        if ($case.code -eq 0 -and $output -notmatch '203\.0\.113\.x') {
            throw "$($case.name): 거부된 출발지 IP의 마스크가 없습니다."
        }
        if ($output.Contains($other)) {
            throw "$($case.name): 거부된 출발지의 전체 IP가 노출됐습니다."
        }
    }

    Set-Content -LiteralPath $file.FullName -Value "{ `"natIpv4`": `"$other`","
    $output = (& $validator -EvidencePath $file.FullName 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 1 -or $output.Contains($other)) {
        throw '잘못된 JSON은 출발지 IP를 노출하지 않고 거부해야 합니다.'
    }
    "통과: PoC 증거 판정 $($cases.Count + 1)건"
} finally {
    Remove-Item -LiteralPath $file.FullName
}
