# 실측 증적

2026-11-20 Azure West US 3에서 실행한 최종 검증을 요약합니다. `01`과 `02`는 독립적인 Fabric Pipeline 실행이고, `03`은 `01`과 **같은 HTTPS URL**을 NAT를 거치지 않는 IPv4 클라이언트로 호출한 대조군입니다.

| 순서 | 검증 | 관측 시각 (UTC) | HTTP | App Service IP 감사 | 결과 |
|---|---|---|---|---|---|
| 01 | Fabric 실행 1, `Completed` · Lakehouse 적재 일치 | `08:20:33.01263` | `200` · 수신 IP = NAT IPv4 | `Allowed` · NAT IPv4 | **PASS** |
| 02 | Fabric 실행 2, `Completed` · Lakehouse 적재 일치 | `08:21:31.568068` | `200` · 수신 IP = NAT IPv4 | `Allowed` · NAT IPv4 | **PASS** |
| 03 | 01의 URL을 별도 IPv4에서 호출 | `08:22:28.6340908` | 클라이언트 응답 `403` | `Denied` · NAT와 다른 IPv4 | **PASS** |

시각은 `01`·`02`는 HTTP 수신 로그, `03`은 IP 감사 로그 기준입니다. 같은 호스트와 겹치지 않는 UTC 시간창으로 로그를 대조했고, HTTP 수신 로그는 프로브 경로까지 대조했습니다. [증거 판정기](../scripts/Confirm-PocEvidence.ps1)의 종료 코드 `0`으로 최종 통과를 확인했습니다. 첫 진단 실행은 페이지 매김 때문에 같은 URL을 반복 호출해 취소했으며 합격 근거에서 제외했습니다.

이 문서는 원본의 공개용 요약입니다. 실제 IP, 앱 호스트, Azure·Fabric 식별자와 원본 로그는 공개하지 않습니다. 재현 시 [증거 수집 절차](../docs/runbook.md#fabric-호출과-로그-대조)에 따라 새 결과를 수집합니다.

## 정리 상태

2026-11-20 18:08 KST 확인 기준입니다. Fabric 연결·게이트웨이·PoC 작업 영역은 삭제 후 조회 시 모두 `404`였고 기존 Trial은 `Active`였습니다. Azure PoC 그룹은 아직 존재했고, 위임 서브넷에 `PowerPlatformSAL`이 남아 있어 Azure 리소스 정리 완료는 확인되지 않았습니다.
