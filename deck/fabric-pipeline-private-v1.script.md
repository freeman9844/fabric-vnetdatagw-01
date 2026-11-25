# 발표 스크립트 — Fabric Pipeline · Inbound Deny와 두 Private Endpoint

2장 · L300 · 예상 3분 20초

## 1. Fabric Pipeline 구성 — 원본 읽기와 OneLake 적재의 두 PE
_1분 40초 · 670자_

이번에는 앞의 VM 직접 쓰기와 달리 Fabric Pipeline이 App Service에서 데이터를 가져오도록 했습니다. 두 사설 엔드포인트가 같은 일을 하는지, 하나가 없어도 이 구성이 동작하는지 살펴볼게요. 왼쪽 파란 상자는 Azure VNet이고, 오른쪽의 App Service와 Fabric은 이 VNet 밖의 서비스입니다. Fabric에서 실행한 Copy Activity의 REST 원본 연결만 왼쪽의 VNet Data Gateway에 명시적으로 연결했어요. 적재 대상은 같은 F2 작업 영역에 있는 기본 Lakehouse Files이고, 대상에는 별도의 Gateway 연결을 만들지 않았습니다.

첫 번째 줄은 원본 읽기입니다. 위임 서브넷의 Gateway가 별도 서브넷에 있는 App Service Private Endpoint로 HTTPS 요청을 보냈습니다. 응답은 같은 연결로 돌아오고 App Service 공용 접근은 꺼져 있었습니다. 두 번째 줄은 검증하려던 Fabric 쪽 경로입니다. 별도 서브넷의 Fabric Workspace Private Endpoint가 대상이고, 각 엔드포인트는 자신의 Private DNS 영역을 사용합니다. 이 환경에는 NAT Gateway를 두지 않았어요.

두 번째 줄의 점선은 패킷을 캡처했다는 뜻이 아닙니다. Gateway 서브넷에만 Fabric PE의 승인된 사설 IP 여섯 개를 대상으로 하는 차단 경로를 적용하고, 이를 제거하기 전후의 적재를 비교했다는 뜻이에요. App Service 쪽 경로나 VM의 사설 관리 경로에는 그 라우트를 넣지 않았습니다. 이제 다음 장에서 원본 요청과 OneLake 적재가 실제로 어떻게 달라졌는지 보겠습니다.

> 출처: Microsoft Learn — https://learn.microsoft.com/data-integration/vnet/use-data-gateways-pipeline-fabric ; https://learn.microsoft.com/fabric/security/security-workspace-level-private-links-support

## 2. 실측 — Fabric PE 경로를 복구하자 Inbound Deny에서 적재 성공
_1분 40초 · 576자_

방금 구성도에서 두 엔드포인트의 역할을 나눠 봤죠. 이제 같은 Pipeline의 다섯 번 실행을 비교해 볼게요. 첫 줄은 인바운드 허용 기준선입니다. App Service에 해당 실행의 요청이 한 번 도착했고 OneLake 파일도 확인했습니다. 공개 접근을 거부로 바꾼 뒤 처음에는 Fabric PE에 접근할 수 있어도 Copy가 시간 초과였어요. 이때는 원본 요청 기록도 없어서 이 실패만으로 적재 경로를 판정할 수 없습니다.

세 번째 줄에서는 Gateway 서브넷에서 Fabric PE 주소만 차단했습니다. 원본 앱에는 해당 실행 요청이 한 번 왔지만 Lakehouse는 DeniedByPolicy를 반환했고 파일이 없었어요. 원래 경로를 복구하고 같은 거부 정책을 유지하자 네 번째와 다섯 번째 실행이 모두 완료됐습니다. 사설 경로로 파일을 읽어 합성 데이터 이백오십육 키비바이트의 해시를 원본과 대조했고, 마지막 실행 전후에 공용 쓰기가 사백삼으로 차단된 것도 다시 확인했습니다.

그래서 이번 구성에서는 원본을 사설로 읽을 수 있어도 Fabric 쪽 접근이 별도로 필요하다고 볼 수 있어요. 다만 모니터 지표는 분 단위 집계여서 어떤 연결이 적재 페이로드 전부를 보냈는지까지 식별하지 못합니다. 마지막으로 임시 연결, Gateway, 작업 영역, F2와 Azure 그룹의 부재를 모두 조회했습니다. 기존 용량과 테넌트 설정은 변경하지 않았어요. 재현할 때도 동일한 원본, 목적지와 차단 대조군을 갖추고 이 판정 범위를 유지해 주세요.

> 출처: 비식별 실측 증적 — https://github.com/freeman9844/fabric-vnetdatagw-01/blob/main/evidence/fabric-pipeline-private.json ; https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-network-privateendpoints-metrics
