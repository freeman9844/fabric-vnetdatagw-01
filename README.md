# Microsoft Fabric 네트워크 검증: NAT 송신 · Private Link 수신

이 문서는 실제 Azure West US 3에서 검증한 두 시나리오를 다룹니다. **NAT 고정 송신 IP**와 **공개 App Service를 NAT로 호출한 뒤 `Inbound Deny` 상태의 OneLake에 적재하는 Fabric Pipeline**입니다.

## NAT Gateway 고정 송신 IP

Microsoft Fabric Pipeline에서 공개 HTTPS API를 호출할 때, API가 보는 출발지 IP를 Azure NAT Gateway의 정적 공인 IPv4로 고정할 수 있는지 실제 Azure에서 검증한 기록입니다. 기능 검증이며, 성능이나 고객 온프레미스 경로는 검증하지 않았습니다.

- **고정 송신 IP:** VNet Data Gateway를 사용한 Fabric REST Copy Activity 두 건이 모두 `Completed`였고, 응답이 Lakehouse에 적재됐습니다. App Service에 기록된 두 `200` 요청의 출발지 IP는 NAT IPv4와 일치했습니다.
- **`/32` 허용 목록:** NAT를 사용하지 않는 IPv4 클라이언트가 동일한 URL에서 `403`을 받았습니다. App Service IP 감사 로그에도 NAT와 다른 출발지의 `Denied`가 기록됐습니다.

**결과: 3건 PASS** (2026-11-20, West US 3). 정리 상태는 기능 판정과 별개이며 [실측 증적](evidence/README.md#정리-상태)에 마지막 확인 결과를 기록했습니다.

> **발견:** REST Copy Activity에서 `supportRFC5988 = "false"`만 지정했을 때 같은 URL을 반복 호출했습니다. `MaxRequestNumber = "1"`과 `EndCondition:$.ok = "Exist"`를 적용한 뒤, 독립적인 두 실행을 다시 검증했습니다.

## Pipeline 적재: NAT를 통한 공개 App Service 호출과 Fabric Workspace PE

**검증 구성:** `Fabric Pipeline → VNet Data Gateway → NAT Gateway → 공개 App Service(HTTPS)`. App Service 접근 제한은 NAT Gateway의 정적 공인 IPv4(`/32`)만 허용하고 나머지는 거부했습니다. App Service PE는 테스트 중 사용하지 않았습니다. HTTPS 응답은 기존 NAT 연결을 통해 VNet Data Gateway로 돌아오며, 그 응답을 같은 Fabric 작업 영역의 OneLake Lakehouse `Files`에 적재할 때 **Fabric Workspace PE 접근이 필요한지** 확인했습니다.

**실측 결과:** 2026-11-25(UTC), 세 실행 모두 작업 영역의 `Inbound Deny`를 유지했습니다. 같은 Pipeline을 실행하면서 VNet Data Gateway 서브넷의 Fabric PE 경로만 차단했다가 복구했습니다.

| Fabric Workspace PE 경로 | 공개 App Service 원본 호출 | Pipeline / OneLake |
|---|---|---|
| 열림 | 실행 ID 일치 1건 · NAT IP 일치 · `200` | 완료 · 사설 재읽기 `200` · 256 KiB SHA-256 일치 |
| 차단 | 실행 ID 일치 1건 · NAT IP 일치 · `200` | 실패 · `DeniedByPolicy` · 파일 `404` |
| 복구 | 실행 ID 일치 1건 · NAT IP 일치 · `200` | 완료 · 사설 재읽기 `200` · 256 KiB SHA-256 일치 |

**판정:** Fabric PE를 차단해도 원본 호출은 성공했지만 OneLake 적재만 실패했습니다. 복구 후 적재가 다시 성공했고, 실험 전후 공용 OneLake 쓰기는 `403 DeniedByPolicy`였습니다. 따라서 이 구성에서 **적재 성공이 Fabric Workspace PE 접근에 의존**함을 확인했습니다. Pipeline의 쓰기 연결을 직접 추적하지는 않았으므로 응답 전체가 PE를 통과했다고 단정하지 않습니다.

**정리:** 시험 라우트와 작업 영역 정책을 원복했습니다. Fabric 연결·게이트웨이·작업 영역·임시 F2와 Azure 리소스 그룹은 삭제를 확인했습니다. 기존 Fabric 용량과 테넌트 설정은 유지했습니다.

[구성도와 실측 장표](#03-pipeline-결합-검증) · [결합 시나리오 실측 근거](evidence/README.md#pipeline-결합-검증-nat와-fabric-workspace-pe) · [비식별 결과 JSON](evidence/fabric-pipeline-nat-workspace-pe.json)

## 저장소 구성

| 경로 | 내용 |
|---|---|
| [`deck/`](deck/) | **NAT 송신 및 Private Link 수신 검증 장표** PPTX, YAML 원본, 한국어 발표 노트, 슬라이드별 PNG |
| [NAT](docs/runbook.md) | 고정 송신 IP 검증 구성, 판정 기준 및 정리 |
| [실측 증적](evidence/README.md) | 실측 결과와 정리 상태. 원본 로그와 실제 IP·식별자는 제외 |
| [설계](docs/superpowers/specs/2026-11-20-fabric-vnet-gateway-nat-poc-design.md) · [구현 계획](docs/superpowers/plans/2026-11-20-fabric-vnet-gateway-nat-poc.md) | 검증 범위, 접근 정책과 단계별 판정 기준 |
| [NAT 인프라](infra/main.bicep) | 고정 송신 IP 검증용 Azure 리소스를 배포하는 Bicep |
| [`mock-api/`](mock-api/) | NAT용 합성 JSON과 [Pipeline용 256 KiB 합성 데이터](mock-api/pipeline/server.mjs)를 반환하는 Node.js Mock API 및 HTTP 테스트 |
| [`scripts/`](scripts/) · [`tests/`](tests/) | 실측 증거 판정기, 인프라 구조 및 판정 회귀 테스트 |

## 장표

[편집 가능한 PowerPoint v3](deck/fabric-nat-design-v3.pptx) · [YAML 원본](deck/fabric-nat-design-v3.yaml) · [발표 노트](deck/fabric-nat-design-v3.script.md) · [전체 미리보기](deck/fabric-nat-design-v3_render/contact_sheet.png)

기존 NAT 송신 검증 7장과 Pipeline 결합 검증 2장을 한 파일에 담았습니다. 이미지를 클릭하면 원본 크기로 열립니다.

### 1. 검증 샘플 구성

NAT Gateway는 VNet의 위임 서브넷에 연결하는 별도 관리형 리소스입니다. 그림에서는 VNet 경계 안, 위임 서브넷 경계 밖에 배치하고 연결 설정을 주황 점선으로 표시했습니다. 공개 HTTPS Mock API는 VNet 밖에 있습니다.

<a href="deck/fabric-nat-design-v3_render/slide_01.png"><img src="deck/fabric-nat-design-v3_render/slide_01.png" alt="Azure VNet 안에서 위임 서브넷과 연결된 NAT Gateway 및 VNet 밖 App Service의 공개 HTTPS 접근 경로" width="960"></a>

### 01 네트워크 검증

#### 2. 네트워크 검증 섹션

<a href="deck/fabric-nat-design-v3_render/slide_02.png"><img src="deck/fabric-nat-design-v3_render/slide_02.png" alt="네트워크 검증 섹션: 고정 송신 IPv4, /32 접근 제한, 동일 URL 대조군" width="960"></a>

#### 3. 검증 매트릭스

<a href="deck/fabric-nat-design-v3_render/slide_03.png"><img src="deck/fabric-nat-design-v3_render/slide_03.png" alt="허용 요청 두 건과 차단 대조군의 기대 응답과 판정 근거" width="960"></a>

#### 4. 실측 결과

<a href="deck/fabric-nat-design-v3_render/slide_04.png"><img src="deck/fabric-nat-design-v3_render/slide_04.png" alt="Fabric 두 건의 HTTP 200 및 NAT IPv4 일치, 외부 대조군의 HTTP 403 실측" width="960"></a>

### 02 재현 및 정리

#### 5. 재현 및 정리 섹션

<a href="deck/fabric-nat-design-v3_render/slide_05.png"><img src="deck/fabric-nat-design-v3_render/slide_05.png" alt="재현 및 정리 섹션: REST Copy 설정, 판정 절차, 별도 승인 정리" width="960"></a>

#### 6. Fabric 재현 설정

<a href="deck/fabric-nat-design-v3_render/slide_06.png"><img src="deck/fabric-nat-design-v3_render/slide_06.png" alt="Fabric 게이트웨이 연결, 단일 호출을 위한 페이지 매김 규칙, 증거 판정 순서" width="960"></a>

#### 7. 검증 범위와 리소스 정리 상태

<a href="deck/fabric-nat-design-v3_render/slide_07.png"><img src="deck/fabric-nat-design-v3_render/slide_07.png" alt="기능 검증 3건 통과와 Fabric 및 Azure의 마지막 리소스 정리 확인 상태" width="960"></a>

### 03 Pipeline 결합 검증

#### 8. 공개 App Service와 Fabric Workspace PE 구성

<a href="deck/fabric-nat-design-v3_render/slide_08.png"><img src="deck/fabric-nat-design-v3_render/slide_08.png" alt="VNet Data Gateway의 NAT 경유 공개 App Service 호출과 Fabric Workspace PE 접근에 의존하는 OneLake 적재 구성" width="960"></a>

#### 9. Fabric PE 경로 열림·차단·복구 실측

<a href="deck/fabric-nat-design-v3_render/slide_09.png"><img src="deck/fabric-nat-design-v3_render/slide_09.png" alt="세 실행 모두 App Service에서 NAT IPv4와 HTTP 200을 확인했으며 Fabric PE 경로 차단 시에만 OneLake 적재 실패" width="960"></a>

## 재현 순서

아래는 NAT 송신 검증 순서입니다. NAT 호출과 OneLake 적재를 함께 검증한 구성은 [결합 시나리오 실측 근거](evidence/README.md#pipeline-결합-검증-nat와-fabric-workspace-pe)를 참고하세요.

1. [로컬 검증](docs/runbook.md#로컬-검증): Azure 리소스를 만들지 않고 Bicep, Mock API, 증거 판정기를 확인합니다.
2. [Azure 미리보기와 배포](docs/runbook.md#azure-미리보기와-배포): PoC 전용 그룹으로 범위를 제한하고 승인 후 배포합니다.
3. [Fabric 호출과 로그 대조](docs/runbook.md#fabric-호출과-로그-대조): 허용 요청 두 건과 동일 URL의 차단 대조군 한 건을 확인합니다.
4. [정리](docs/runbook.md#정리): 별도 승인 후 PoC 리소스만 삭제하고 Azure와 Fabric에서 삭제 여부를 확인합니다.
