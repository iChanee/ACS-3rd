# HighHttpLatency

## 개요
HTTP 응답시간 P95가 1초를 초과한 경우 발생하는 알람입니다.

## 심각도
warning

## 증상
- P95 응답시간 > 1000ms
- 사용자 체감 속도 저하
- 타임아웃 연쇄 발생 가능

## 원인 분류

### 1. DB 쿼리 지연
- 인덱스 미사용 풀스캔
- 락 경합 (Lock contention)
- 커넥션 풀 고갈로 인한 대기

### 2. 외부 API 지연
- 서드파티 API 응답 지연
- 네트워크 레이턴시 증가
- DNS 해석 지연

### 3. 애플리케이션 내부 처리 지연
- 동기 블로킹 I/O
- 대용량 직렬화/역직렬화
- 비효율적인 알고리즘

### 4. 리소스 경합
- CPU 포화로 인한 큐잉
- GC stop-the-world 영향
- 스레드 풀 고갈

## 대응 절차
1. 느린 트레이스 top 5 확인 (어느 서비스/구간인지)
2. DB slow query 로그 확인
3. 외부 API 레이턴시 측정
4. 커넥션 풀 상태 확인 (pending 요청 수)
5. CPU/메모리 동시 이상 여부 확인
6. 캐시 히트율 확인 (캐시 적용 검토)

## 확인 명령
```bash
# P95 응답시간
histogram_quantile(0.95, rate(http_server_request_duration_seconds_bucket[5m]))

# 엔드포인트별 P95
histogram_quantile(0.95, sum by (http_route, le) (
  rate(http_server_request_duration_seconds_bucket[5m])
))

# DB 커넥션 대기
db_client_connections_pending_requests
```

## 에스컬레이션
- P95 > 3초 지속 시 → 서비스 담당자 호출
- 특정 엔드포인트 집중 시 → 해당 기능 긴급 점검
