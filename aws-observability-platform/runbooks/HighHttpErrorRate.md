# HighHttpErrorRate

## 개요
HTTP 에러율이 50%를 초과한 경우 발생하는 알람입니다.

## 심각도
critical

## 증상
- HTTP 4xx/5xx 응답 비율이 전체 요청의 50% 초과
- 사용자 요청 실패 급증
- 서비스 응답 불가 상태 가능

## 원인 분류

### 1. 애플리케이션 오류 (5xx)
- 코드 버그, NPE, 런타임 예외
- 잘못된 배포로 인한 로직 오류
- DB 연결 실패로 인한 처리 불가

### 2. 클라이언트 오류 (4xx)
- 잘못된 라우팅 설정
- 인증/인가 문제
- API 스펙 변경 후 클라이언트 미반영

### 3. 외부 의존성 장애
- DB 다운 또는 타임아웃
- 외부 API 장애
- 네트워크 파티션

## 대응 절차
1. 에러 상태코드 분포 확인 (4xx vs 5xx 비율)
2. 에러 로그에서 스택 트레이스 확인
3. 최근 배포 이력 확인 (롤백 검토)
4. DB 연결 상태 및 커넥션 풀 확인
5. 외부 의존성 헬스체크
6. 필요 시 이전 버전으로 롤백

## 확인 명령
```bash
# 에러율 확인
rate(http_server_request_duration_seconds_count{http_response_status_code=~"4..|5.."}[5m])
/ rate(http_server_request_duration_seconds_count[5m])

# 상태코드별 분포
sum by (http_response_status_code) (rate(http_server_request_duration_seconds_count[5m]))
```

## 에스컬레이션
- 5분 내 해결 불가 시 → 서비스 담당자 호출
- 롤백 후에도 지속 시 → 인프라팀 에스컬레이션
