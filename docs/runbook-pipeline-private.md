# Fabric Pipeline 사설 적재 재현

실제 Copy Activity에서 **VNet Data Gateway → App Service PE** 원본 읽기와 **Fabric Workspace PE에 대한 OneLake 적재 의존성**을 분리한다. [VM의 OneLake 직접 적재](runbook-inbound-private.md)와 달리 VM은 관리·검증에만 쓴다. NAT Gateway는 배포하지 않는다.

## 사전 조건과 배포

1. 대상은 승인된 구독의 신규 `rg-fabric-pipeline-pe-poc`와 별도 West US 3 F2다. 기존 그룹이 있으면 덮어쓰지 않는다. [작업 영역 인바운드 규칙 허용](https://learn.microsoft.com/fabric/security/security-workspace-enable-inbound-access-protection), OneLake 외부 앱 접근과 작업 영역·Gateway·Azure 권한을 준비한다. 테넌트 전체 공용 접근 정책과 기존 용량은 변경하지 않는다. F2·Bastion·VM·App Service 등에 요금이 발생하므로 승인된 운영 시간과 정리 범위를 정한다.
2. [`main.bicep`](../infra/pipeline-private-poc/main.bicep)을 `az deployment sub what-if`로 확인하고 승인 후 배포한다. 신규 그룹 범위 이외의 변경은 허용하지 않는다. 고유한 `runId`, `capacityAdmin`, 테스트 SSH 공개 키를 사용한다. 키와 실제 매개 변수 파일은 저장소 밖에 둔다. F2가 활성화되면 해당 F2에 새 작업 영역과 Lakehouse를 만든다.
3. [Fabric PE 템플릿](../infra/pipeline-private-poc/fabric-endpoint.bicep)에 같은 `runId`, 새 작업 영역과 테넌트 ID를 넣는다. 승인된 그룹의 `az deployment group what-if`를 확인한 후 배포한다. `workspace`와 `sites` 대상의 PE가 각각 `Approved`이고, 각 Private DNS 영역이 VNet에 연결됐는지 확인한다. Fabric PE NIC의 실제 사설 IP 목록을 저장한다.
4. [`mock-api/pipeline/server.mjs`](../mock-api/pipeline/server.mjs)를 `server.mjs`가 ZIP 루트에 오도록 패키징한다. App Service 로그를 켜고 VNet 내 사설 SCM에 Entra ID로 ZIP을 게시한다. SCM이나 앱의 공용 접근 또는 기본 인증을 켜지 않는다. 관리용 VM을 쓰면 Bastion 접속 전에 부팅 진단에 기록된 SSH 호스트 키와 지문을 확인한다. 공개 HTTPS가 `403`, 내부 HTTPS가 `200`이고 내부에서 실제 연결 상대가 App Service PE NIC와 일치하는지 확인한다.

## Pipeline과 대조군

1. 전용 F2와 위임 서브넷으로 [VNet Data Gateway](https://learn.microsoft.com/data-integration/vnet/create-data-gateways)를 만든다. 지원 연결 조회에 이 Gateway ID를 지정하고 `RestService` / `RestService.Contents`가 반환되는지 확인한다. `VirtualNetworkGateway` 연결에서 익명 HTTPS `baseUrl`을 앱 주소로 지정한다. 배포 API가 시간 초과되면 이름과 생성 범위를 재조회해 중복 생성을 피한다.
2. [Pipeline 정의](../infra/pipeline-private-poc/pipeline-content.json) 사본의 세 자리표시자를 교체하고 [Fabric Items API](https://learn.microsoft.com/rest/api/fabric/core/items/create-item)로 `DataPipeline`을 만든다. 정의 부분의 `path`는 `pipeline-content.json`, `payloadType`은 `InlineBase64`, `payload`는 UTF-8 JSON의 Base64다. REST 원본만 Gateway에 연결한다. 대상은 같은 작업 영역의 네이티브 Lakehouse `Files`로 두고 별도 대상 Gateway 연결을 만들지 않는다. 복사 전 75초 대기, 원본 호출 최대 1회, `Files/probes/{실행 ID}.json`을 유지한다.
3. `Allow`에서 원본 요청 한 건과 적재·재읽기 성공을 확인한다. 원래 작업 영역 정책 전체와 ETag를 보관하고 작업 영역 **인바운드 기본값만** `Deny`로 바꾼다. 관리 API의 정책 설정 조회를 실제 적용으로 간주하지 않는다. [공용 대조군](runbook-inbound-private.md#onelake-검증)이 같은 Lakehouse의 새 합성 파일 쓰기에 `403 DeniedByPolicy`를 반환할 때까지 기다린다.
4. `Deny`를 유지한 채 이 순서로 같은 Pipeline을 실행한다: **Fabric PE 경로 열림 → 차단 → 복구**. 차단 시 전용 Gateway 서브넷에만 연결된 빈 라우트 테이블에 승인된 Fabric PE NIC 주소 각각의 `/32 → None` 라우트를 추가한다. App Service PE 주소, 관리 VM 서브넷과 작업 영역 정책은 바꾸지 않는다. PE 서브넷의 라우트 정책과 각 라우트 적용을 확인하고, 성공·실패와 관계없이 시험 라우트만 제거한다. 공유 라우트 테이블에서 이 절차를 실행하지 않는다.
5. 각 실행의 최종 상태와 내부 오류, App Service `synthetic-probe` 로그의 동일 `probeId` 개수, 사설 OneLake에서 재읽은 파일 HTTP 상태를 대조한다. JSON의 UTF-8 BOM은 파싱 전에 처리한다. 성공 파일의 `probeId`가 실행 ID인지 확인하고 `data`를 Base64 디코딩한다. 기대 바이트는 UTF-8 문자열 `실행ID:0`부터 `실행ID:8191`까지 각각 SHA-256으로 해시한 32바이트를 순서대로 연결한 256 KiB다. 기대 데이터와 파일 속 데이터의 SHA-256을 비교한다.
6. 마지막으로 복구 경로에서 재실행하고 전후 공용 차단을 재확인한다. 실행 시작과 상태 조회·파일 재읽기는 가능한 한 복사 관측 시간대와 분리한다. Azure Monitor의 `PEBytesIn`/`PEBytesOut`는 1분 집계이고 게시가 지연될 수 있다. 집계값을 실행별 흐름이나 페이로드 추적으로 해석하지 않는다.

**판정:** `Deny`에서 Fabric PE만 차단했을 때 앱 요청이 남아 있지만 Lakehouse `DeniedByPolicy`로 실패하고, 복구 후 동일 구성에서 적재·해시 비교가 성공하면 이 구성의 Fabric PE 접근 의존성이 관측된 것이다. 시간 초과·일반 `403`·Pipeline 성공만으로 경로를 판정하지 않는다. [실측 결과](../evidence/fabric-pipeline-private.json)에는 첫 `Deny` 시도의 시간 초과도 포함했다.

## 정리

1. 집계 지표가 수집될 때까지 증거를 보존한다. 시험 라우트 제거와 원래 작업 영역 정책 복원을 확인한다. PoC REST 연결과 VNet Data Gateway를 삭제하고 `404`인지 확인한다.
2. Fabric 작업 영역에 활성 Private Link 서비스가 있으면 삭제가 거부된다. 검증 증거를 보존한 뒤 해당 작업 영역을 대상으로 만든 **Fabric PE → Private Link 서비스 → 작업 영역** 순서로 삭제하고 부재를 확인한다.
3. 소유 태그와 범위를 확인해 전용 Azure 그룹을 삭제한다. 위임 서브넷의 `PowerPlatformSAL`이 남아 있으면 플랫폼 정리를 기다린다. 그룹 삭제가 지연되는 동안 승인 범위에서 F2, Bastion, VM, App Service Plan 등 과금 자원을 먼저 제거한다. 위임을 강제로 해제하지 않는다.
4. 그룹 존재 여부 `false`, Fabric 연결·Gateway·작업 영역 조회 `404`, 임시 F2 부재와 기존 용량 상태를 확인한다. 원본 로그·개인 키·토큰·실제 매개 변수·Azure 및 Fabric 식별자는 공개하지 않는다.
