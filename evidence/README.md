# 실측 증적

## NAT 송신 IP 검증

2026-11-20 Azure West US 3에서 실행한 최종 검증을 요약합니다. `01`과 `02`는 독립적인 Fabric Pipeline 실행이고, `03`은 `01`과 **같은 HTTPS URL**을 NAT를 거치지 않는 IPv4 클라이언트로 호출한 대조군입니다.

| 순서 | 검증 | 관측 시각 (UTC) | HTTP | App Service IP 감사 | 결과 |
|---|---|---|---|---|---|
| 01 | Fabric 실행 1, `Completed` · Lakehouse 적재 일치 | `08:20:33.01263` | `200` · 수신 IP = NAT IPv4 | `Allowed` · NAT IPv4 | **PASS** |
| 02 | Fabric 실행 2, `Completed` · Lakehouse 적재 일치 | `08:21:31.568068` | `200` · 수신 IP = NAT IPv4 | `Allowed` · NAT IPv4 | **PASS** |
| 03 | 01의 URL을 별도 IPv4에서 호출 | `08:22:28.6340908` | 클라이언트 응답 `403` | `Denied` · NAT와 다른 IPv4 | **PASS** |

시각은 `01`·`02`는 HTTP 수신 로그, `03`은 IP 감사 로그 기준입니다. 같은 호스트와 겹치지 않는 UTC 시간창으로 로그를 대조했고, HTTP 수신 로그는 프로브 경로까지 대조했습니다. [증거 판정기](../scripts/Confirm-PocEvidence.ps1)의 종료 코드 `0`으로 최종 통과를 확인했습니다. 첫 진단 실행은 페이지 매김 때문에 같은 URL을 반복 호출해 취소했으며 합격 근거에서 제외했습니다.

이 문서는 원본의 공개용 요약입니다. 실제 IP, 앱 호스트, Azure·Fabric 식별자와 원본 로그는 공개하지 않습니다. 재현 시 [증거 수집 절차](../docs/runbook.md#fabric-호출과-로그-대조)에 따라 새 결과를 수집합니다.

## 정리 상태

2026-11-20에 Fabric 연결·게이트웨이·PoC 작업 영역은 삭제 후 모두 `404`였고 기존 Trial은 `Active`였습니다. 초기 조회에서는 위임 서브넷에 `PowerPlatformSAL`이 남아 Azure 그룹 삭제가 지연됐습니다. **2026-11-25 20:51 KST 재조회에서 `rg-fabric-nat-poc` 부재를 확인했습니다.**

## Private Link 수신 검증

2026-11-25 Azure West US 3에서 전용 F2 작업 영역의 OneLake Lakehouse `Files`에 합성 파일을 썼습니다. 공용과 사설 요청은 동일한 Entra 계정, 작업 영역, Lakehouse를 사용했습니다.

| 정책 | 경로 | 실측 |
|---|---|---|
| `Allow` | 외부 클라이언트 → 공용 OneLake | `PUT 201` |
| `Allow` | VNet 테스트 VM → 작업 영역 Private Endpoint | `PUT 201` |
| `Deny` | 외부 클라이언트 → 공용 OneLake | `PUT 403`, `DeniedByPolicy` |
| `Deny` | VNet 테스트 VM → 작업 영역 Private Endpoint | `PUT 201`, `GET 200`, SHA-256 일치 |

Private Endpoint는 `Approved`였고, 사설 DNS 응답과 실제 HTTPS 연결 IP가 모두 해당 NIC의 IP와 일치했습니다. 작업 영역의 아웃바운드 정책과 테넌트 전체 공용 접근 설정(`차단 안 함`)은 바꾸지 않았습니다.

**정리 확인:** PoC 작업 영역은 재조회 `404`, 임시 F2는 Fabric 용량 목록에서 부재, 전용 Azure 리소스 그룹은 존재 여부 `false`였습니다. 기존 Trial은 `Active`였으며 테넌트의 작업 영역 수준 인바운드 규칙 허용은 켜진 상태로 유지됐습니다.

[비식별 결과 JSON](fabric-inbound-private.json) · [검증 재현 절차](../docs/runbook-inbound-private.md)

## Pipeline 사설 적재 검증

2026-11-25 West US 3 임시 F2에서 실제 REST Copy Activity를 실행했습니다. App Service PE와 Fabric Workspace PE는 별도 서브넷에 있었고, REST 원본만 VNet Data Gateway 연결로 지정했습니다. App Service 공용 대조군은 `403`, 사설 HTTPS는 `200`이었습니다.

| 실행 | Fabric 정책 / Fabric PE 경로 | 일치하는 원본 요청 | OneLake 확인 |
|---|---|---:|---|
| 01 | `Allow` 기준선 | 1 | 완료 · `GET 200` · SHA-256 일치 |
| 02 | `Deny` + PE 접근 가능 | 0 | `ActionTimedOut` · `GET 404` |
| 03 | `Deny` + Gateway 서브넷에서 Fabric PE 경로 차단 | 1 | `LakehouseForbiddenError` / `DeniedByPolicy` · `GET 404` |
| 04 | `Deny` + Fabric PE 경로 복구 | 1 | 완료 · `GET 200` · SHA-256 일치 |
| 05 | `Deny` + 복구 상태 재실행 | 1 | 완료 · `GET 200` · SHA-256 일치 |

ARM 감사 로그에서 승인된 Fabric PE IP 6개에 대한 `/32 → None` 라우트의 생성·삭제 성공을 확인했습니다. App Service 요청과 적재 파일은 실행 ID로 연결했으며, 성공 파일에 포함된 원본 합성 데이터 256 KiB의 SHA-256을 비교했습니다. 최종 실행 전후 공용 OneLake 쓰기는 `403 DeniedByPolicy`였습니다.

**해석:** 실행 02의 시간 초과만으로 적재 네트워크 경로를 판정할 수 없습니다. 실행 03~05에서는 원본 앱 호출과 적재가 분리돼 이 구성의 적재 성공이 Fabric PE 접근에 의존한다는 근거가 됩니다. [Azure Monitor의 PE 바이트](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-network-privateendpoints-metrics)는 분 단위 합계이고 실행 ID·연결 식별자가 없습니다. 파일 재읽기와 상태 조회를 복사 관측 시간에서 분리했지만, 이 지표로 전체 페이로드의 통과를 확정하지 않습니다.

**정리 확인:** 시험 라우트와 작업 영역 정책을 원복했습니다. Fabric 연결·Gateway·작업 영역은 `404`, 임시 F2와 전용 Azure 그룹은 부재였습니다. 기존 용량과 테넌트 설정은 유지했습니다.

[비식별 결과 JSON](fabric-pipeline-private.json) · [재현 절차](../docs/runbook-pipeline-private.md)
