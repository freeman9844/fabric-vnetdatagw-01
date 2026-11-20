$ErrorActionPreference = 'Stop'
$main = Join-Path $PSScriptRoot '..\infra\main.bicep'
if (-not (Test-Path -LiteralPath $main)) {
    throw '배포할 Bicep 템플릿이 아직 없습니다.'
}

$build = @(az bicep build --file $main --stdout 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Bicep 컴파일 실패: $LASTEXITCODE" }
$diagnostics = @($build | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
foreach ($diagnostic in $diagnostics) {
    if ("$diagnostic" -match ': Warning ') { throw "Bicep 형식 또는 린트 경고: $diagnostic" }
}
$compiled = $build | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
$root = $compiled | ConvertFrom-Json
$deployments = @($root.resources | Where-Object type -eq 'Microsoft.Resources/deployments')
if ($deployments.Count -ne 1 -or $root.'$schema' -notmatch 'subscriptionDeploymentTemplate') {
    throw '구독 범위에서 PoC 리소스 그룹 모듈 하나를 배포해야 합니다.'
}
$resources = $deployments[0].properties.template.resources

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Get-OnlyResource([string] $Type) {
    $matched = @($resources | Where-Object type -eq $Type)
    Assert-True ($matched.Count -eq 1) "다음 리소스가 정확히 하나여야 합니다: $Type"
    return $matched[0]
}

function Get-ResourceIdExpression($Resource) {
    $name = $Resource.name
    if ($name.StartsWith('[') -and $name.EndsWith(']')) {
        $name = $name.Substring(1, $name.Length - 2)
    } else {
        $name = "'$name'"
    }
    return "resourceId('$($Resource.type)', $name)"
}

function Assert-NetworkPath {
    $pip = Get-OnlyResource 'Microsoft.Network/publicIPAddresses'
    $nat = Get-OnlyResource 'Microsoft.Network/natGateways'
    $vnet = Get-OnlyResource 'Microsoft.Network/virtualNetworks'
    Assert-True ($pip.sku.name -eq 'Standard' -and $pip.properties.publicIPAllocationMethod -eq 'Static' -and
        $pip.properties.publicIPAddressVersion -eq 'IPv4') '정적 Standard 공인 IPv4가 필요합니다.'
    $expectedPipId = Get-ResourceIdExpression $pip
    Assert-True ($nat.sku.name -eq 'Standard' -and $nat.properties.publicIpAddresses.Count -eq 1 -and
        $nat.properties.publicIpAddresses[0].id -eq "[$expectedPipId]" -and
        -not $nat.properties.publicIpPrefixes.Count) 'NAT는 지정한 공인 IPv4 하나만 사용해야 합니다.'
    Assert-True ($vnet.properties.subnets.Count -eq 1) '게이트웨이 전용 서브넷만 있어야 합니다.'
    $subnet = $vnet.properties.subnets[0].properties
    $expectedNatId = Get-ResourceIdExpression $nat
    Assert-True ($subnet.addressPrefix -eq '10.20.30.0/27' -and
        $subnet.delegations.Count -eq 1 -and
        $subnet.delegations[0].properties.serviceName -eq 'Microsoft.PowerPlatform/vnetaccesslinks' -and
        $subnet.natGateway.id -eq "[$expectedNatId]" -and $subnet.defaultOutboundAccess -eq $false -and
        -not $subnet.routeTable) '서브넷의 위임, 주소 또는 송신 경로가 계획과 다릅니다.'
    $services = @($subnet.serviceEndpoints | ForEach-Object service | Sort-Object)
    Assert-True (($services -join ',') -eq 'Microsoft.AzureActiveDirectory,Microsoft.Storage') '서비스 엔드포인트가 PoC에 필요한 범위를 벗어납니다.'
}

function Assert-IngressPolicy {
    $app = (Get-OnlyResource 'Microsoft.Web/sites').properties
    $config = $app.siteConfig
    $rules = @($config.ipSecurityRestrictions | Sort-Object priority)
    $expectedPipId = Get-ResourceIdExpression (Get-OnlyResource 'Microsoft.Network/publicIPAddresses')
    Assert-True ($app.publicNetworkAccess -eq 'Enabled' -and $app.httpsOnly -eq $true -and
        [version] $config.minTlsVersion -ge [version] '1.2' -and [version] $config.scmMinTlsVersion -ge [version] '1.2') `
        'Mock API와 SCM은 TLS 1.2 이상이어야 합니다.'
    Assert-True ($rules.Count -eq 2 -and $rules[0].action -eq 'Allow' -and
        $rules[0].ipAddress -match [regex]::Escape($expectedPipId) -and
        $rules[0].ipAddress -match '/32' -and $rules[1].action -eq 'Deny' -and
        $rules[1].ipAddress -eq '0.0.0.0/0' -and $config.ipSecurityRestrictionsDefaultAction -eq 'Deny') `
        'Mock API는 NAT IP /32만 먼저 허용하고 나머지를 거부해야 합니다.'
    Assert-True ($config.scmIpSecurityRestrictionsUseMain -eq $false -and
        $config.scmIpSecurityRestrictionsDefaultAction -eq 'Deny' -and
        @($config.scmIpSecurityRestrictions | Where-Object action -eq 'Allow').Count -eq 0 -and
        $config.ftpsState -eq 'Disabled') 'SCM은 별도의 기본 거부 정책을 사용하고 FTP는 비활성화해야 합니다.'
    $policies = @($resources | Where-Object type -eq 'Microsoft.Web/sites/basicPublishingCredentialsPolicies')
    Assert-True ($policies.Count -eq 2 -and
        @($policies | Where-Object { $_.name -match '\bftp\b' -and $_.properties.allow -eq $false }).Count -eq 1 -and
        @($policies | Where-Object { $_.name -match '\bscm\b' -and $_.properties.allow -eq $false }).Count -eq 1) `
        'FTP와 SCM 기본 인증을 둘 다 비활성화해야 합니다.'
}

function Assert-LogRouting {
    $diag = Get-OnlyResource 'Microsoft.Insights/diagnosticSettings'
    $workspaceId = Get-ResourceIdExpression (Get-OnlyResource 'Microsoft.OperationalInsights/workspaces')
    $categories = @($diag.properties.logs | Where-Object enabled | ForEach-Object category | Sort-Object)
    Assert-True ($diag.scope -match 'Microsoft\.Web/sites' -and
        $diag.properties.workspaceId -eq "[$workspaceId]" -and
        $diag.properties.logAnalyticsDestinationType -eq 'Dedicated' -and
        ($categories -join ',') -eq 'AppServiceHTTPLogs,AppServiceIPSecAuditLogs' -and
        -not $diag.properties.metrics.Count) '앱의 HTTP 및 IP 감사 로그만 전용 워크스페이스에 수집해야 합니다.'
}

Assert-NetworkPath
Assert-IngressPolicy
Assert-LogRouting
'통과: NAT 송신 경로, 앱/SCM 접근 제한, 수신 로그 전달'
