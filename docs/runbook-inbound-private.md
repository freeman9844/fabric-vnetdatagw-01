# Fabric Inbound Deny와 OneLake Private Endpoint 재현

VNet 안의 Linux VM에서 **작업 영역 수준 Private Endpoint**를 통해 Lakehouse `Files`에 직접 쓴다. VNet 밖에서는 같은 Entra 계정으로 같은 Lakehouse의 공용 경로를 대조한다. **Bastion은 VM 관리 접속에만 사용**하며, OneLake HTTPS 요청은 VM이 직접 보낸다. Pipeline, VNet Data Gateway 및 NAT Gateway는 이 시험에 필요 없다.

## 사전 조건과 배포

1. 대상 Fabric 테넌트에서 **고급 네트워킹 → 작업 영역 수준 인바운드 네트워크 규칙 구성**이 켜져 있고, OneLake에 대한 외부 앱 접근이 테스트 계정에 허용돼 있어야 한다. 이번 실측에서는 **테넌트 전체 공용 인터넷 차단**을 켜지 않았다. 작업 영역 관리자 역할과 Azure 리소스 배포 권한을 준비한다. [Fabric 설정과 Private Link 요구 사항](https://learn.microsoft.com/ko-kr/fabric/security/security-workspace-level-private-links-set-up)을 참고한다. 기존 Trial이나 P SKU는 작업 영역 수준 Private Link를 지원하지 않는다.
2. 저장소 루트에서 아래 명령으로 두 템플릿을 오프라인 컴파일한다. 대상 구독의 `westus3`에서 F2, VM SKU, Bastion 사용 가능 여부를 확인한다. `rg-fabric-inbound-pe-poc`가 이미 있다면 이 템플릿을 그 그룹에 재배포하지 않는다. F2, VM, Bastion 등은 과금되므로 **신규 그룹 범위와 비용을 승인받은 후** 실행한다.

   ```powershell
   az bicep build --file .\infra\inbound-poc\main.bicep --stdout
   az bicep build --file .\infra\inbound-poc\private-endpoint.bicep --stdout
   ```

3. [기본 환경 템플릿](../infra/inbound-poc/main.bicep)에 고유한 소문자 영숫자 `runId`, `capacityAdmin`, 테스트용 `sshPublicKey`를 전달한다. 실제 매개 변수 파일과 SSH 개인 키는 저장소 밖에 둔다. `az deployment sub what-if`에서 승인 구독의 신규 그룹과 그 하위의 생성만 확인한 뒤, 동일 매개 변수로 `az deployment sub create`를 실행한다. F2가 `Active`가 되면 **새 Fabric 작업 영역을 이 F2에 할당**하고 Lakehouse를 만든다.
4. [Private Endpoint 템플릿](../infra/inbound-poc/private-endpoint.bicep)에 같은 `runId`, 새 `workspaceId`, 같은 테넌트의 `tenantId`를 지정한다. `az deployment group what-if`로 PoC 그룹 내 새 리소스에만 변경이 있는지 확인한 뒤 `az deployment group create`를 실행한다. 연결 대상이 `workspace`이고 상태가 `Approved`인지 확인한다. Private Endpoint NIC의 IP 목록과 `privatelink.fabric.microsoft.com` 영역이 PoC VNet에 연결됐는지도 확인한다.

## OneLake 검증

1. [작업 영역 전용 FQDN](https://learn.microsoft.com/ko-kr/fabric/onelake/onelake-manage-inbound-access)을 사용한다. Blob API 대상은 아래 형식이다. 호스트에는 하이픈 없는 작업 영역 GUID를 사용하고, 경로에는 하이픈을 포함한 작업 영역·Lakehouse GUID를 사용한다.

   ```text
   https://{하이픈_없는_workspace_GUID}.z{GUID_앞_두_글자}.blob.fabric.microsoft.com/{workspace_GUID}/{lakehouse_GUID}/Files/{새_합성_파일}
   ```

2. VM에는 공인 IP나 기본 인터넷 송신 경로가 없다. Bastion을 통해 VM에 접속하고, SSH 호스트 키를 Azure 관리형 부팅 진단에 기록된 지문과 대조한다. 양쪽 클라이언트에서 동일 사용자와 [Storage 대상 Entra 토큰](https://learn.microsoft.com/ko-kr/fabric/onelake/onelake-access-api)을 사용한다. 토큰은 신뢰가 확인된 테스트 VM으로 SSH 표준 입력을 통해 전달하고 값 자체를 출력하거나 저장하지 않는다.
3. 정책이 `Allow`일 때 양쪽 클라이언트에서 작은 합성 파일을 [Put Blob](https://learn.microsoft.com/rest/api/storageservices/put-blob)으로 써서 `201`을 확인한다. `x-ms-blob-type: BlockBlob`을 사용한다. VNet 내부의 DNS 응답과 TLS 소켓의 실제 연결 IP가 모두 승인된 Private Endpoint NIC 주소에 속해야 한다. 외부 요청은 공인 주소로 연결됐는지 확인한다. 인증서 검증과 DNS 해석을 강제로 우회하지 않는다.
4. [Get Network Communication Policy](https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-network-communication-policy)로 **원래 정책 전체**를 저장한다. [Set Network Communication Policy](https://learn.microsoft.com/rest/api/fabric/core/workspaces/set-network-communication-policy)로 전용 작업 영역의 `inbound.publicAccessRules.defaultAction`만 `Deny`로 바꾼다. 이 API는 전체 정책을 덮어쓰므로 아웃바운드 정책을 포함해 나머지 값을 유지하고, 반환된 ETag가 있다면 `If-Match`를 사용한다. 설정 API의 `Deny` 조회와 실제 데이터 경로의 전파는 별개이며 전파에는 최대 30분이 걸릴 수 있다.
5. **합격 조건:** 외부에서 기준선과 같은 URL에 같은 계정으로 쓰면 `403 DeniedByPolicy`가 반환된다. 그 상태에서 내부 VM은 새 파일 쓰기 `201`, 같은 파일 읽기 `200`을 받고 SHA-256이 원본과 일치해야 한다. 쓰기와 읽기의 실제 연결 IP를 다시 Private Endpoint NIC와 대조한다. 시간 초과, 일반 권한 오류 또는 `Deny` 설정 조회만으로는 공용 경로 차단을 입증할 수 없다.

## 정리

실측을 보존한 뒤 포털이나 글로벌 Fabric 작업 영역 통신 정책 API로 **PoC 작업 영역**의 원래 정책을 복구한다. 실측에서는 정책 API가 `Allow`를 반환한 뒤에도 일반 작업 영역 API가 일시적으로 `RequestDeniedByInboundPolicy`를 반환했다. `403`을 삭제 완료로 판단하지 않는다.

승인 범위의 Lakehouse·작업 영역을 삭제하고 해당 작업 영역 조회가 `404`가 되는지 확인한다. PoC 그룹의 소유 태그와 리소스 범위를 확인하고 그룹을 삭제한다. Azure에서는 `az group exists --subscription <승인된 구독> --name rg-fabric-inbound-pe-poc`가 `false`, Fabric에서는 임시 F2가 용량 목록에 없고 기존 Trial은 활성 상태인지 확인한다. 테넌트 설정과 기존 리소스는 삭제하거나 변경하지 않는다.
