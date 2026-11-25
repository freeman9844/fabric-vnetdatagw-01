# 발표 스크립트 — Fabric Inbound Deny · OneLake Private Endpoint

1장 · L300 · 예상 1분 34초

## 1. Inbound Deny — OneLake 사설 적재는 성공, 공용 쓰기는 차단
_1분 34초 · 621자_

앞에서 본 NAT 검증은 Fabric이 외부 API를 호출하는 송신 시험이었죠. 이번 장표는 방향이 반대입니다. 외부 환경과 VNet에서 Fabric으로 들어오는 요청을 각각 보내 봤어요. 그중 VNet에서 들어오는 요청이 사설 연결로 도착해서 파일을 쓸 수 있는지 확인했습니다.

왼쪽 파란 상자가 Azure VNet입니다. 공인 IP가 없는 Linux 테스트 VM과 Private Endpoint를 서로 다른 서브넷에 배치했어요. 초록색 Private Endpoint는 Azure 쪽 전용 서브넷에 있고, 오른쪽 Microsoft Fabric은 VNet 밖에 있는 SaaS입니다. 같은 작업 영역의 Blob 주소를 VNet 안에서 조회하면 Private DNS 덕분에 사설 IP가 나와요. 이 응답뿐 아니라 HTTPS 연결의 실제 상대 IP도 승인된 엔드포인트의 NIC 주소와 대조했습니다. Bastion은 VM에 접속할 때만 썼고, OneLake에 요청을 보낸 주체는 VM입니다.

아래의 빨간 점선은 같은 Entra 계정이 VNet 밖에서 동일한 Lakehouse에 쓰기를 시도한 경로예요. 처음에는 공용과 사설 모두 HTTP 201을 받았습니다. 전용 작업 영역의 인바운드 정책만 Deny로 바꾸자 공용 쓰기는 HTTP 403과 DeniedByPolicy를 받았어요. 이 상태에서도 사설 쓰기는 201, 재읽기는 200이었고 파일의 해시가 원본과 일치했습니다. 테넌트 전체를 막거나 Pipeline으로 우회한 결과가 아니라, 작업 영역의 정책과 Private Link를 함께 검증한 결과입니다.

> 출처: Microsoft Learn — https://learn.microsoft.com/fabric/security/security-workspace-level-private-links-set-up ; https://learn.microsoft.com/fabric/onelake/onelake-manage-inbound-access
