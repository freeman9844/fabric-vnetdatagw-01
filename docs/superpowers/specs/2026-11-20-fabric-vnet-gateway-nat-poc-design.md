# Fabric VNet Data Gateway 고정 송신 IP PoC 설계

## 목적과 범위

실제 Azure에서 Microsoft Fabric이 Public HTTPS API를 호출할 때, API가 보는 클라이언트 IP가 Azure NAT Gateway의 정적 공인 IPv4인지 검증한다. 사용자가 선택한 검증 범위는 **IP 일치와 NAT IP `/32` 허용 목록 동작 모두**다. 즉 호출이 성공했다는 것만으로는 충분하지 않다. 고정 IP가 로그에서 일치하고, 같은 URL은 다른 출발지에서 차단되어야 한다.

운영 API·네트워크·방화벽, 고객 데이터, Hub/ExpressRoute/강제 터널링, Dataflow Gen2 지원 여부는 검증하지 않는다. Lakehouse는 REST Copy Activity 실행에 필요한 임시 싱크이며 운영 적재는 범위에 포함하지 않는다. Azure Mock API는 온프레미스 Public API의 접근 제어를 흉내 내며, 실제 온프레미스 경로나 인터넷 통과 구간까지 입증하지는 않는다.

## 검토한 접근

| 접근 | 장점 | 제약 및 선택 |
| --- | --- | --- |
| 외부 IP 에코 API | 가장 빠르게 API가 보는 공인 IP를 확인할 수 있다. | 목적지 `/32` 접근 제어와 독립적인 수신 로그를 제어할 수 없다. 사용자가 선택한 범위에는 맞지 않는다. |
| Azure App Service에 자체 HTTPS Mock API | 관리형 TLS, IP 접근 제한, 플랫폼 수신 로그로 IP와 허용·거부를 모두 입증할 수 있다. | Public endpoint 예외 및 소규모 App Service/로그 요금이 필요하다. **제안 구성**이다. |
| Azure VM에 자체 HTTPS Mock API | 웹 서버 수신 로그와 네트워크 제어를 직접 관리할 수 있다. | TLS 인증서, OS, 공인 IP, 관리 경로가 더 필요하다. 이 단기 테스트에서는 관리형 대안보다 복잡하다. |

## 제안 구성

```text
Fabric Trial / PoC 전용 작업 영역
  Pipeline REST Copy Activity (GET)  ── 결과 ──> PoC Lakehouse
    │ VNet Data Gateway 연결 지정
    ▼
Azure West US 3 / PoC 전용 리소스 그룹
  PoC VNet / 전용 IPv4 /27 위임 서브넷 (Microsoft.PowerPlatform/vnetaccesslinks)
    │ NAT Gateway Standard → 정적 공인 IPv4 1개로 SNAT
    ▼
  App Service의 기본 Public HTTPS 호스트
    ├ 허용: NAT 공인 IP /32
    ├ 거부: 나머지 IPv4 명시적 거부, 불일치 기본 거부
    └ App Service 플랫폼 로그 → PoC Log Analytics
```

- 기존 활성 Fabric Trial(FTL64, West US 3)을 그대로 참조한다. Trial에 PoC 전용 작업 영역과 단일 멤버 VNet Data Gateway를 연결한다. 운영 작업 영역, 기존 게이트웨이, Trial 설정은 변경하지 않는다. Trial을 사용할 수 없으면 중단하며 유료 Capacity로 자동 전환하지 않는다.
- 현재 CLI 기본 구독에서 West US 3, NAT 및 공인 IP 할당량, Linux App Service B1, 관련 공급자 등록 상태를 읽기 전용으로 확인했다. 태그를 지원하는 PoC 리소스에는 구독 정책에 맞춰 `Control=Yes`를 지정한다. 구독 전체 인사이트 조회는 권한 오류가 났으므로, 배포 가능 여부는 ARM 권한과 what-if에서 다시 확인한다. Fabric 및 Azure의 동일 테넌트, 위임 서브넷 `join/action`, Fabric Capacity 및 작업 영역 권한을 변경 전에 확인한다.
- Azure 리소스는 Bicep으로 별도 리소스 그룹에 관리한다. 서브넷은 기본 인터넷 경로와 NAT를 쓰고, App Service로 우회할 수 있는 `Microsoft.Web` 서비스 엔드포인트·Private Endpoint·피어링·강제 터널링은 두지 않는다. 게이트웨이 설치 문서가 요구하는 `Microsoft.AzureActiveDirectory`와 `Microsoft.Storage` 서비스 엔드포인트는 별도로 설정한다. Fabric 리소스는 Azure ARM 리소스가 아니므로 Fabric REST API 및 필요한 경우 문서화된 포털 절차로 관리한다.
- Mock API는 HTTPS 전용(TLS 1.2 이상)으로 합성 JSON만 반환한다. 본문에 실제 IP, 헤더, 자격 증명 또는 고객 데이터를 넣지 않는다. 익명 REST 연결을 쓰되 앱 사이트는 생성 시점부터 NAT `/32` 외 접근을 차단한다. SCM은 앱과 별도 규칙을 두고 기본 거부, 기본 인증·FTP 비활성화, Entra ID 배포만 허용한다. 필요할 때에만 확인된 배포자 IP `/32`를 SCM에 임시 허용한 후 제거한다.
- PoC 앱의 Public endpoint는 검증 목적상 필요한 의도적 예외다. 단기 단일 리전 검증이므로 다중 영역 이중화, WAF, 별도 방화벽은 두지 않는다. Log Analytics에는 필요한 두 범주의 로그만 수집하며, 짧은 보존 기간과 수집 비용 제한을 설정한다. 호출 자체는 로그 수집에 의존하지 않는다.

## 테스트와 판정

| 검사 | 기대 결과 | 남길 증거 |
| --- | --- | --- |
| NAT 및 연결 설정 | 서브넷이 지정된 NAT Gateway에 연결되고 NAT에는 정적 공인 IPv4가 하나만 할당됨. REST 연결에 PoC 게이트웨이 지정. | Azure에서 조회한 NAT IP와 서브넷 연결, Fabric 게이트웨이·연결 식별자 |
| Fabric 실제 호출 | REST Copy Activity에서 두 번 `GET /probe/{id}` 실행. 각 실행이 성공하고 API 응답이 임시 Lakehouse에 적재됨. | 실행 ID, UTC 시각, 고유 경로, 적재된 합성 JSON |
| 수신 IP | 두 실행에 해당하는 `AppServiceHTTPLogs`의 `ScStatus`는 `200`, `CIp`는 NAT 공인 IP와 정확히 일치. IP 접근 로그에도 NAT 출발지에 대한 허용이 기록됨. | 고유 경로로 연결한 HTTP 로그 및 같은 시간대의 `AppServiceIPSecAuditLogs` |
| 비허용 출발지 | NAT에 연결되지 않은 IPv4 클라이언트가 같은 HTTPS URL을 요청하면 `403`. 수신 IP 감사 로그에서 NAT와 다른 IP에 대한 명시적 거부 확인. | 클라이언트 HTTP 결과, UTC 시각, 동일 호스트의 IP 감사 로그 |

실행 전에 Log Analytics로 HTTP·IP 감사 로그가 전달되도록 구성한다. IP는 호출자가 넣은 `X-Forwarded-For`가 아니라 App Service 플랫폼의 수신 IP와 네트워크 정책 판정에서 읽는다. 고유 경로에는 테스트 식별자만 넣고, 결과를 공유할 때 비허용 클라이언트 IP는 마스킹한다. 응답이나 로그가 누락되거나 IP가 다르면 통과로 처리하지 않고 원인과 미확인 항목을 기록한다.

## 비용, 변경 승인, 정리

공개 미국 USD 요율 기준 고정 비용은 약 **$0.067/시간**이다(NAT $0.045, 공인 IPv4 $0.005, Linux B1 $0.017). 24시간이면 고정 비용 약 $1.61이며 NAT 처리량, 데이터 전송, 로그 수집·보존 요금 및 구독 계약 차이는 별도다. 기존 Trial 사용을 전제로 새 Fabric Capacity 비용은 포함하지 않는다.

설계 승인 후 구현 계획을 작성한다. Azure에 쓰기 전에 구독 범위 ARM what-if로 새 리소스 그룹과 그 안의 리소스 생성을 함께 미리 보고, 변경 내역과 비용을 제시해 별도 승인을 받는다. PoC 종료 시 결과를 먼저 보존한다. 삭제는 사용자가 승인한 PoC 신규 리소스에만 적용하고, Fabric 연결·게이트웨이 및 테스트 작업 영역을 먼저 정리한 뒤 Azure 리소스 그룹을 정리한다. 게이트웨이 삭제 후 위임 서브넷이 해제되기까지 최대 2–3시간 걸릴 수 있으므로 삭제 완료를 재확인한다. 기존 Trial, 등록된 공급자와 운영 리소스는 그대로 둔다.

## 공식 근거

- [VNet Data Gateway 아키텍처와 NAT 규칙](https://learn.microsoft.com/data-integration/vnet/data-gateway-architecture), [생성 및 지원 리전](https://learn.microsoft.com/data-integration/vnet/create-data-gateways), [Trial 지원과 삭제 FAQ](https://learn.microsoft.com/data-integration/vnet/data-gateway-faqs)
- [Fabric REST 커넥터의 VNet 게이트웨이 지원](https://learn.microsoft.com/fabric/data-factory/connector-rest-overview), [REST Copy Activity](https://learn.microsoft.com/fabric/data-factory/connector-rest-copy-activity)
- [App Service 접근 제한 및 감사](https://learn.microsoft.com/azure/app-service/overview-access-restrictions#diagnostic-logging), [HTTP 로그](https://learn.microsoft.com/azure/azure-monitor/reference/tables/appservicehttplogs), [IP 감사 로그](https://learn.microsoft.com/azure/azure-monitor/reference/tables/appserviceipsecauditlogs)
- Azure Well-Architected Framework: [App Service](https://learn.microsoft.com/azure/well-architected/service-guides/app-service-web-apps), [Virtual Network](https://learn.microsoft.com/azure/well-architected/service-guides/virtual-network), [Log Analytics](https://learn.microsoft.com/azure/well-architected/service-guides/azure-log-analytics)
- [Azure NAT Gateway 요금](https://azure.microsoft.com/pricing/details/azure-nat-gateway/), [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)
