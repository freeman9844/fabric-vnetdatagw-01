# Fabric VNet Data Gateway PoC 실행 안내

명령은 저장소 루트에서 실행합니다. 테스트 범위와 구성은 [프로젝트 개요](../README.md), 실제 실행의 공개 요약은 [실측 증적](../evidence/README.md)을 참고하세요.

## 로컬 검증

PowerShell 7.5 이상, Azure CLI 및 Bicep, Node.js 24 LTS가 필요하다. 아래 명령은 Azure 리소스를 만들지 않는다.

```powershell
az bicep build --file .\infra\main.bicep --stdout
az bicep build-params --file .\infra\main.bicepparam --stdout
pwsh -NoProfile -File .\tests\Test-Infra.ps1
node --test
pwsh -NoProfile -File .\tests\Test-PocEvidence.ps1
checkov -d .\infra --framework bicep --skip-download --skip-results-upload --download-external-modules false
```

Checkov 예외는 테스트용 익명 HTTPS, 관리 ID가 필요 없는 합성 응답, 단일 B1의 이중화 및 상태 점검에 한해 해당 App Service 선언에 기록했다. 앱은 NAT `/32`만 허용하며 SCM은 별도 기본 거부다.

## Azure 미리보기와 배포

1. 대상은 승인된 현재 CLI 기본 구독의 `westus3` 및 신규 `rg-fabric-nat-poc`다. `az account show`, `az group exists`, `az network list-usages --location westus3`와 Fabric `GET /v1/capacities`로 구독·리전·신규 그룹·기존 활성 `FTL64`를 확인한다. Fabric 계정과 구독의 테넌트는 같아야 한다.
2. 아래 미리보기에서 해당 신규 그룹과 그 하위의 생성만 허용한다. 서브넷은 VNet 변경 내용 안에 포함된다. 다른 범위 변경, 이름 충돌, 정책 또는 권한 오류가 있으면 중단한다.

   ```powershell
   $subscription = '<승인된 구독 ID>'
   $group = 'rg-fabric-nat-poc'
   $params = @("resourceGroupName=$group", 'nameSuffix=poc', 'location=westus3')
   az deployment sub what-if --subscription $subscription --location westus3 `
     --template-file .\infra\main.bicep --parameters @params --validation-level Provider
   ```

3. **별도 승인 후에만** 같은 구독·리전·템플릿·매개 변수로 `az deployment sub create --name fabric-nat-poc`을 실행한다. 기존 리소스나 Trial은 변경하지 않는다. 고정 비용은 약 $0.067/시간이며 전송·NAT 처리량·로그 비용은 별도다. `az network public-ip show --ids <publicIpResourceId>`에서 할당된 IPv4를 읽고 `az network vnet subnet show --ids <subnetId>`에서 NAT 연결과 위임을 확인한다.
4. 저장소 밖에 `Compress-Archive -Path .\mock-api\server.mjs -DestinationPath <경로>\mock.zip`으로 ZIP을 만든다. ZIP 루트는 `server.mjs`다. `az webapp deploy --subscription <구독> --resource-group <그룹> --name <앱 이름> --src-path <ZIP 경로> --type zip`으로 Entra ID를 사용해 게시한다. SCM에서 받은 HTTPS `403` 응답에 `x-ms-forbidden-ip`가 있다면 배포자 IPv4를 확인하는 데 사용할 수 있다. 확인된 IPv4 `/32`만 **SCM에만** 임시 허용하고 성공·실패와 관계없이 제거한다. 앱 사이트 규칙을 변경하거나 기본 인증을 켜지 않는다. 게시 후 `az webapp config access-restriction show`로 NAT `/32` Allow, 명시적 IPv4 Deny, 양쪽 기본 Deny 및 SCM 독립 규칙을 재확인한다. CLI 배열의 `Deny all`/`Any`는 기본 규칙 표시로, 명시적 IPv4 Deny와 구분한다.

## Fabric 호출과 로그 대조

1. [게이트웨이 생성 API](https://learn.microsoft.com/rest/api/fabric/core/gateways/create-gateway)로 `type=VirtualNetwork`, 현재 활성 Trial의 `capacityId`, 방금 배포한 구독·그룹·VNet·서브넷, 단일 멤버를 지정한다. Azure 서브넷 `join/action`과 Fabric 게이트웨이 생성 권한이 필요하다. API 인증이 불가능하면 [Fabric 포털의 게이트웨이 관리](https://learn.microsoft.com/data-integration/vnet/create-data-gateways)에서 같은 구성으로 확인한다. Trial 자체에서 생성이 거부되면 중단한다.
2. [지원 연결 형식 조회](https://learn.microsoft.com/rest/api/fabric/core/connections/list-supported-connection-types)에 PoC `gatewayId`를 지정한다. 이 게이트웨이에서 보고한 REST의 API 식별자는 `RestService`, 생성 방식은 `RestService.Contents`, 주소 인자는 `baseUrl`이다. [REST 연결](https://learn.microsoft.com/rest/api/fabric/core/connections/create-connection)을 `VirtualNetworkGateway`·Anonymous·`https://<mockHostname>/`로 만들고, 응답 또는 Fabric 포털에서 같은 게이트웨이 ID를 확인한다. REST 사용이 불가능해도 클라우드 전용 연결로 바꾸지 않는다.
3. 같은 Trial에 새 PoC 작업 영역을 할당한다. 새 Lakehouse를 만들고, Pipeline의 [REST Copy Activity](https://learn.microsoft.com/fabric/data-factory/connector-rest-copy-activity)에서 앞서 확인한 REST 연결을 Source로 선택한다. GET, 서버 인증서 검증 활성화, 자동 재시도 없음, `@concat('probe/',pipeline().RunId)`를 사용한다. 페이지 매김 규칙은 `MaxRequestNumber = "1"`과 `EndCondition:$.ok = "Exist"`로 첫 응답에서 멈추게 한다. `supportRFC5988 = "false"`만 넣었을 때는 같은 URL을 반복 호출했으므로 이 설정으로 대체하지 않는다. Destination은 Lakehouse의 `Files/probes` 아래 `@concat(pipeline().RunId,'.json')`으로 지정한다. 두 실행을 순차적으로 완료하고 각각 실행 ID, 연결 ID, 겹치지 않는 시작·완료 UTC, `ok: true` 및 적재된 `probeId`를 확인한다.
4. 두 실행이 종료된 후 NAT를 사용하지 않는 IPv4 클라이언트에서 **이미 호출한 동일 URL**로 GET을 한 번 보낸다. 예를 들어 `curl.exe -4 --silent --show-error --output NUL --write-out '%{http_code}' "https://<mockHostname>/probe/<이미 사용한 UUID>"`를 사용하고 요청 직전과 직후의 UTC를 남긴다. 이 호출은 자동 재시도·리디렉션을 사용하지 않는다. 전송 오류는 `403`이 아니다.
5. 수집이 끝나면 전용 Log Analytics에서 `_ResourceId`, `CsHost`, `TimeGenerated`를 좁힌다. `AppServiceHTTPLogs`는 `CsMethod == "GET"`과 두 프로브의 정확한 `CsUriStem`으로 필터링한다. `AppServiceIPSecAuditLogs`는 경로 필드가 없으므로 같은 호스트와 각각의 겹치지 않는 시간창을 대조한다. 특히 부정 검사는 가능한 한 짧은 시간창에 Denied 한 건만 있어야 한다. `XForwardedFor`가 아닌 두 테이블의 플랫폼 필드 `CIp`를 사용한다. 감사 로그의 `CIp`가 `IPv4:포트`이면 형식을 확인하고 포트를 제거한다. Azure의 `403` 응답에 `x-ms-forbidden-ip`가 있다면 그 IPv4도 Denied 로그와 대조한다. 부정 검사의 HTTP 로그도 기록됐다면 같은 경로의 `403`과 감사 IP가 일치해야 한다.

| 증거 JSON 필드 | 값 |
| --- | --- |
| `natIpv4`, `host` | Public IP의 실제 IPv4와 앱 DNS 호스트 이름 |
| `fabric` | 두 행의 `runId`, `probeId`, `status: "Completed"`, `landedProbeId`, `fromUtc`, `toUtc` |
| `http` | `host: CsHost`, `probeId: CsUriStem`에서 추출한 UUID, `timeUtc: TimeGenerated`, `status: ScStatus`, `clientIp: CIp` |
| `audit` | `host: CsHost`, `timeUtc: TimeGenerated`, `result: "Allowed"` 또는 `"Denied"`, `clientIp: CIp`에서 정규화한 IPv4 |
| `negative` | 동일 URL의 `probeId`, `fromUtc`, `toUtc`, 정수 `status: 403` |

UTC 시각은 ISO 8601로 기록한다. 로그가 누락되거나 판정이 상충하면 성공으로 보고하지 않는다. `pwsh -NoProfile -File .\scripts\Confirm-PocEvidence.ps1 -EvidencePath <증거 JSON>`의 종료 코드 `0`이 통과다. 원본 증거는 저장소 밖에 보관한다. 공개 요약에는 실제 IP, 앱 호스트, Azure·Fabric 리소스 및 실행 식별자를 싣지 않는다.

## 정리

증거를 먼저 보존하고 **삭제 승인을 별도로** 받는다. 이번 실행의 Fabric 연결, VNet Data Gateway, PoC 작업 영역만 삭제한다. 위임 서브넷에 `PowerPlatformSAL`이 남아 있다면 플랫폼 연결이 해제될 때까지 기다린다. 해제에는 최대 2–3시간이 걸릴 수 있다. 연결 해제와 그룹 내 리소스 범위를 확인한 뒤 승인된 구독의 `rg-fabric-nat-poc`만 삭제한다. `az group exists --subscription $subscription --name $group`이 `false`인지, 세 Fabric 항목 조회가 `404`인지, 기존 Trial이 유지되는지 확인한다. 공급자 등록이나 운영 리소스는 삭제하지 않는다.
