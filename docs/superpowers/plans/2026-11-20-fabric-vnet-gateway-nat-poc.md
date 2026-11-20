# Fabric VNet Data Gateway 고정 송신 IP PoC 구현 계획

> **실행 에이전트 필수 하위 스킬:** `superpowers:subagent-driven-development` 또는 `superpowers:executing-plans`를 사용해 작업 단위로 진행한다. 각 단계는 체크박스로 추적한다.

**목표:** 실제 Fabric Pipeline의 REST 요청이 Azure NAT Gateway의 정적 공인 IPv4로 API에 도달하고, 다른 출발지는 같은 URL에서 거부됨을 입증한다.

**아키텍처:** 기존 West US 3 Fabric Trial에 전용 작업 영역·게이트웨이·Pipeline·Lakehouse를 연결한다. Azure의 전용 리소스 그룹에는 NAT가 연결된 위임 서브넷, 정적 공인 IPv4 1개, `/32` 제한을 갖는 Public HTTPS Mock API와 수신 로그만 추가한다.

**기술 스택:** Azure CLI, Bicep, Linux App Service B1 / Node.js 24 LTS, Azure Monitor Log Analytics, Fabric REST API v1, PowerShell 7.

**설계:** [Fabric VNet Data Gateway 고정 송신 IP PoC 설계](../specs/2026-11-20-fabric-vnet-gateway-nat-poc-design.md)

## 공통 제약

- 현재 CLI 기본 구독과 같은 테넌트의 활성 `FTL64` Trial을 사용한다. 기존 Trial을 변경하지 않으며 유료 Capacity로 자동 전환하지 않는다.
- `westus3`, `Control=Yes`, 전용 IPv4 `/27` 및 `Microsoft.PowerPlatform/vnetaccesslinks`, NAT Gateway Standard와 정적 공인 IPv4 1개를 유지한다.
- `Microsoft.AzureActiveDirectory`와 `Microsoft.Storage` 서비스 엔드포인트만 사용한다. `Microsoft.Web` 서비스 엔드포인트, Private Endpoint, 피어링 및 강제 터널링을 추가하지 않는다.
- Mock API는 HTTPS 전용(TLS 1.2 이상)이며 합성 JSON만 반환한다. 앱 사이트는 생성 시점부터 NAT `/32`만 허용한다. SCM은 앱과 분리해 기본 거부, 기본 인증·FTP 비활성화, Entra ID 배포만 허용한다.
- 실제 Fabric 실행 2건의 `200`, Lakehouse 결과, 플랫폼 로그 IP 일치 및 같은 URL의 비허용 출발지 `403`을 모두 확보해야 통과다.
- 구독 범위 ARM what-if와 위험·비용을 제시한 후 별도 배포 승인을 받는다. 제거는 별도 승인 범위에서 PoC 리소스만 대상으로 한다.

## 검토 집중 항목

- 잘못된 구독·리전 또는 기존 리소스 수정이 what-if에 나타나면 중단한다. 작업 4에서 실제 미리보기의 구독과 변경 대상을 대조한다.
- 앱 배포가 필요해도 앱 사이트가 잠시라도 공개 허용되어서는 안 된다. 작업 1에서 앱·SCM 규칙을 별개로 검증하고 작업 4에서 배포 뒤 재확인한다.
- 가짜 출발지 헤더를 포함한 요청이 응답에 IP나 헤더를 노출하면 안 된다. 작업 2의 합성 응답 검사에 포함한다.
- 게이트웨이 종료·Trial 만료·권한 오류를 성공으로 처리하거나 경로를 바꾸면 안 된다. 작업 4에서 사용 불가 시 중단 조건과 실제 게이트웨이 연결 ID를 확인한다.
- 수신 로그 누락, 비허용 호출의 실제 출발지 미확인, 동일 실행 중복은 통과가 아니다. 작업 3에서 각각 음성 검사를 추가한다.

---

## 파일 구성

| 파일 | 책임 |
| --- | --- |
| `.azure\infrastructure-plan.json` | Azure 리소스·의존성과 플랫폼의 명시적 예외, 승인 상태를 기록 |
| `infra\main.bicep`, `infra\modules\poc.bicep` | 구독 범위 그룹 생성과 그룹 범위 리소스 구성 |
| `tests\Test-Infra.ps1` | 컴파일된 ARM 템플릿에서 네트워크·앱 제한·로그의 구조를 검증 |
| `mock-api\server.mjs`, `mock-api\server.test.mjs` | 의존성 없는 Mock API와 로컬 HTTP 검사 |
| `scripts\Confirm-PocEvidence.ps1`, `tests\Test-PocEvidence.ps1` | 수집한 증거 JSON을 판정하고, 잘못된 성공 판정을 방지 |
| `README.md`, `docs\runbook.md`, `evidence\README.md` | 프로젝트 개요, 배포·실행·정리 절차, 공개용 실측 증적 요약 |

### Task 1: Azure 경로와 접근 정책을 Bicep으로 고정

**파일:** `.azure\infrastructure-plan.json`, `infra\main.bicep`, `infra\modules\poc.bicep`, `tests\Test-Infra.ps1`.

**인터페이스:** 구독 범위 `main.bicep`은 `resourceGroupName: string`, `nameSuffix: string`, `location: string = 'westus3'`를 받고 `subnetId`, `natGatewayId`, `publicIpResourceId`, `mockAppId`, `mockHostname`, `logWorkspaceId`를 모두 `string`으로 출력한다. 실제 공인 IPv4는 출력된 Public IP 리소스에서 배포 후 조회한다.

- [ ] Azure 인프라 플래너 Phase 3에서 `Microsoft.Resources/resourceGroups`, `Microsoft.Network/{virtualNetworks,publicIPAddresses,natGateways}`, `Microsoft.Web/{serverfarms,sites}`, `Microsoft.OperationalInsights/workspaces`, `Microsoft.Insights/diagnosticSettings` 및 필요한 설정 자식 리소스의 ARM 형식·이름·짝 제약을 확인한다. 리소스 목록을 제시해 승인받은 뒤 `.azure\infrastructure-plan.json`을 작성하고 Phase 5에서 검증·승인받는다.
- [ ] 실패 검사를 작성한다. `Test-Infra.ps1`에서 `Assert-NetworkPath`는 정적 `Standard` IPv4 하나, NAT 참조 하나, 전용 `10.20.30.0/27`, 전용 위임과 두 서비스 엔드포인트만 주장한다. `Assert-IngressPolicy`는 메인 사이트의 NAT 할당 IP `/32` Allow 한 개, 그 뒤의 `0.0.0.0/0` Deny 및 기본 Deny, 독립 SCM 기본 Deny, TLS 1.2 이상, 기본 인증 비활성화를 주장한다. `Assert-LogRouting`은 `AppServiceHTTPLogs`·`AppServiceIPSecAuditLogs`만 전용 워크스페이스의 리소스별 테이블로 전달하는지 주장한다.
- [ ] `pwsh -NoProfile -File .\tests\Test-Infra.ps1`을 실행해 템플릿이 아직 없거나 조건을 만족하지 않아 실패함을 확인한다.
- [ ] Bicep을 구현한다. 네트워크는 `10.20.30.0/24` 안의 전용 위임 서브넷으로 구성한다. B1 Linux 앱의 런타임은 `NODE|24-lts`, 시작 명령은 `node server.mjs`다. `Control=Yes`를 태그 지원 리소스에 넣고, Log Analytics 워크스페이스에는 30일 보존과 `0.1 GB` 일일 수집 상한을 사용한다. 진단 워크스페이스 접근은 Entra RBAC를 사용한다.
- [ ] `az bicep build --file .\infra\main.bicep --stdout`, `pwsh -NoProfile -File .\tests\Test-Infra.ps1`, `checkov -d .\infra`를 실행한다. Bicep과 구조 검사는 성공, Checkov는 미해결 High/Critical 0건이어야 한다. 공인 HTTPS가 필요한 정확한 리소스에 한해서만 사유를 문서화하고, 실행 결과를 남긴다.
- [ ] 작업 1의 검증된 파일만 커밋한다.

### Task 2: 합성 응답만 주는 HTTPS 뒤의 Mock API

**파일:** `mock-api\server.mjs`, `mock-api\server.test.mjs`.

**인터페이스:** `createServer(): http.Server`를 내보내고, 실행 진입점은 `0.0.0.0`과 App Service `PORT`(로컬 기본 `8080`)에서 수신한다. `GET /`는 `{ "ok": true }`; `GET /probe/{uuid}`는 `{ "ok": true, "probeId": "<uuid>" }`를 반환한다.

- [ ] Node 기본 테스트 러너로 `returns_health_for_connection_validation`, `returns_only_probe_payload`, `rejects_non_probe_paths_and_unsupported_methods`를 작성한다. 예: `assert.deepEqual(await response.json(), { ok: true, probeId });`에서 요청에 임의 헤더를 넣어도 응답 필드는 이 둘뿐이어야 한다. 합성 API는 `200`, 잘못된 경로는 `404`, 지원하지 않는 메서드는 `405`를 검증한다.
- [ ] `node --test .\mock-api\server.test.mjs`를 실행해 구현이 없는 상태에서 실패함을 확인한다.
- [ ] `node:http`만 사용해 API를 구현한다. UUID 경로만 받으며 Cache-Control은 `no-store`다. IP 판정은 앱이 아니라 App Service 플랫폼 로그에 맡긴다.
- [ ] 같은 Node 테스트를 다시 실행해 전부 통과한 뒤 Mock API 파일만 커밋한다.

### Task 3: 실제 증거 판정기

**파일:** `scripts\Confirm-PocEvidence.ps1`, `tests\Test-PocEvidence.ps1`.

**인터페이스:** `Confirm-PocEvidence.ps1 -EvidencePath <json>`은 조건을 모두 만족하면 종료 코드 0, 누락·불일치 시 1과 이유를 출력한다. 입력은 `natIpv4`, `host`, `fabric[] {runId,probeId,status,landedProbeId,fromUtc,toUtc}`, `http[] {host,probeId,timeUtc,status,clientIp}`, `audit[] {host,timeUtc,result,clientIp}`, `negative {probeId,fromUtc,toUtc,status}`다. `status`는 Fabric에서 `Completed`, HTTP에서는 정수다. `result`는 수집 단계에서 `Allowed` 또는 `Denied`로 정규화한다.

- [ ] 같은 호스트·실행 경로·시간창으로 연결된 두 개의 성공 `200`과 부정 `403` 입력에 `$LASTEXITCODE -eq 0`을 주장한다. 복제한 JSON에서 각각 `http` 누락, `clientIp` 불일치, 두 Fabric `runId` 중복, 같은 NAT IP에 대한 부정 결과, 다른 호스트·시간창의 Deny, Fabric이 호출하지 않은 경로에 대한 `403`을 만들고 모두 `$LASTEXITCODE -eq 1`을 주장한다.
- [ ] `pwsh -NoProfile -File .\tests\Test-PocEvidence.ps1`을 실행해 판정기가 아직 없어서 실패함을 확인한다.
- [ ] 판정기를 구현한다. UTC·IP 필드를 검증하고 각 Fabric 실행마다 Lakehouse `landedProbeId`, 수신 `200` 및 동일 시간창의 `Allowed`를 비교한다. 부정 검사는 같은 프로브 경로의 `403`과 실제 다른 IPv4의 `Denied`를 요구한다. 비허용 IPv4는 보고서에서 마스킹한다.
- [ ] 같은 PowerShell 테스트에서 모든 입력이 지정된 코드로 끝남을 확인한 뒤 판정기와 테스트만 커밋한다.

### Task 4: 실제 Azure·Fabric 실행과 정리

**파일:** `docs\runbook.md`, `evidence\README.md`. 결과 JSON 및 운영 식별자는 커밋하지 않고 세션 산출물로 보존한다.

**인터페이스:** 작업 1의 Bicep 출력, 작업 2의 ZIP(루트에 `server.mjs`), 작업 3 입력 JSON. Fabric에는 PoC 전용 작업 영역·Lakehouse·게이트웨이·REST 연결·Pipeline과 실제 실행 두 건만 만든다.

- [ ] 리전·SKU·할당량·태그 정책을 재확인하고 Fabric `GET /v1/capacities`로 동일 테넌트의 기존 활성 `FTL64`를 확인한다. 용량 사용 불가, 권한 부족, 게이트웨이 연결 실패 시 중단하고 실제 오류를 기록한다. 대체 유료 Capacity나 클라우드 전용 REST 연결은 생성하지 않는다.
- [ ] `az deployment sub what-if --subscription <승인구독> --location westus3 --template-file .\infra\main.bicep --parameters resourceGroupName=<PoC그룹> nameSuffix=<접미사>`를 실행한다. 신규 PoC 범위만 변경되는지 확인하고 공개 HTTPS 예외·비용·정리 범위를 제시해 **별도 배포 승인**을 받는다.
- [ ] 승인 후 동일 인자로 `az deployment sub create`를 수행한다. App Service에 Entra ID로 ZIP을 배포한다. 필요 시 확인된 배포자 `/32`를 SCM에만 임시 허용하고 배포 직후 제거한다. Azure에서 NAT IP와 서브넷 연결을 다시 읽고 메인 사이트의 NAT `/32` 규칙 및 SCM 기본 거부가 유지되는지 확인한다.
- [ ] [게이트웨이 생성 API](https://learn.microsoft.com/rest/api/fabric/core/gateways/create-gateway)로 단일 `VirtualNetwork` 게이트웨이에 Trial과 위임 서브넷을 지정한다. [지원 연결 형식 조회](https://learn.microsoft.com/rest/api/fabric/core/connections/list-supported-connection-types)를 생성한 `gatewayId`로 호출하고, REST 연결을 `VirtualNetworkGateway`·Anonymous·HTTPS로 만든다. 제어 평면에서 지원하는 API를 우선 쓰고, 연결 또는 REST Copy 정의 생성이 API에서 불가능하면 [Fabric 포털](https://app.fabric.microsoft.com)의 공식 절차를 사용한다. 어떤 방식이든 실제 연결 ID와 게이트웨이 연결을 확인한다.
- [ ] 기존 Trial에 새 작업 영역을 할당하고 Lakehouse를 만든다. Pipeline REST Copy Activity의 GET 상대 경로를 `probe/<실행별 UUID>`로 지정해 두 번 실행한다. 각 실행 ID, UTC 시간창, 게이트웨이 연결 ID, Lakehouse 결과를 기록한다. 외부 IPv4 클라이언트에서 동일 프로브 URL로 `403`을 확인한다. 로그가 수집되면 같은 경로의 `AppServiceHTTPLogs`와 동일 호스트·시간창의 `AppServiceIPSecAuditLogs`로 증거 JSON을 구성하고 `pwsh -NoProfile -File .\scripts\Confirm-PocEvidence.ps1 -EvidencePath <결과JSON>`을 실행한다. 코드 0일 때만 실제 성공으로 보고한다.
- [ ] 재현 절차와 오류 시 중단 지점을 `docs\runbook.md`에 기록한다. 통과 시 실제 NAT IP, 두 번의 관측 IP와 `200`, 비허용 출발지의 `403`을 사용자에게 전달하고, `evidence\README.md`에는 원본 데이터와 식별자를 제외한 결과 요약만 커밋한다. 중단 시 부분 결과와 남은 리소스를 보고한다. 결과와 관계없이 정리 승인 후 이번 실행에서 만든 Fabric 연결·게이트웨이·전용 작업 영역을 제거하고 위임 해제 뒤 PoC Azure 그룹을 삭제한다. Azure 그룹 부재와 Fabric 리소스 제거를 재조회하고, 기존 Trial과 공급자 등록 상태가 유지되는지 확인한다.
