# HighDbConnectionPending

## 개요
DB 커넥션 대기 요청이 5개를 초과한 경우 발생하는 알람입니다.

## 심각도
warning

## 증상
- db_client_connections_pending_requests > 5
- DB 관련 요청 처리 지연
- 응답시간 증가 및 타임아웃 발생 가능

## 원인 분류

### 1. 커넥션 풀 크기 부족
- 동시 요청 수 대비 풀 크기가 너무 작음
- 풀 크기 설정값 확인 필요

### 2. DB 쿼리 지연으로 인한 커넥션 점유
- 느린 쿼리가 커넥션을 오래 점유
- 트랜잭션 미종료 (커넥션 반환 안됨)

### 3. DB 서버 과부하
- DB 자체 CPU/메모리 한계 도달
- 동시 연결 수 한계 초과

### 4. 네트워크 문제
- 애플리케이션 ↔ DB 간 네트워크 지연
- 커넥션 타임아웃 설정 부적절

## 대응 절차
1. 현재 커넥션 풀 상태 확인 (active/idle/pending)
2. DB 서버 CPU/메모리/연결 수 확인
3. 현재 실행 중인 slow query 확인
4. 트랜잭션 미종료 세션 확인 및 강제 종료
5. 커넥션 풀 크기 임시 상향 (설정 변경)
6. slow query 최적화 (인덱스 추가 등)

## 확인 명령
```bash
# 커넥션 대기 수
db_client_connections_pending_requests

# 전체 커넥션 상태
db_client_connections_usage by (state)

# DB 풀 최대 크기
db_client_connections_max
```

## 에스컬레이션
- pending > 20 지속 시 → DBA 호출
- DB 서버 연결 불가 시 → 인프라팀 긴급 대응
