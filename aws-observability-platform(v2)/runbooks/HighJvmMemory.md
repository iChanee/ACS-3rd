# HighJvmMemory

## 개요
JVM 메모리 사용률이 85%를 초과한 경우 발생하는 알람입니다.

## 심각도
critical

## 증상
- jvm_memory_used_bytes / jvm_memory_limit_bytes > 0.85
- Full GC 빈도 증가
- 응답 지연 및 OutOfMemoryError 위험

## 원인 분류

### 1. 메모리 누수
- 정적 컬렉션에 객체 무한 축적
- 리소스 미반환 (커넥션, 스트림 등)
- 캐시 만료 정책 미설정

### 2. 힙 설정 부족
- Xmx 설정이 워크로드 대비 낮음
- 컨테이너 메모리 한도와 JVM 힙 불일치

### 3. 대용량 데이터 처리
- 대량 쿼리 결과를 메모리에 전부 로드
- 배치 처리 중 메모리 과다 사용

### 4. 세션/캐시 과다 누적
- 세션 만료 정책 미흡
- 인메모리 캐시 크기 제한 없음

## 대응 절차
1. 메모리 풀별 사용량 확인 (Heap, Non-Heap)
2. GC 로그 분석 (Full GC 빈도 확인)
3. Heap dump 수집 후 메모리 누수 분석
4. 즉시 조치: JVM 재시작 (임시)
5. 근본 원인: 메모리 누수 코드 패치
6. Xmx 상향 검토 (임시 완화)

## 확인 명령
```bash
# 메모리 사용률
jvm_memory_used_bytes / jvm_memory_limit_bytes

# 풀별 메모리
jvm_memory_used_bytes by (jvm_memory_pool_name)

# GC 횟수
rate(jvm_gc_duration_seconds_count[5m])
```

## 에스컬레이션
- 95% 초과 시 → 즉시 재시작
- 재시작 후 빠르게 재상승 시 → 메모리 누수 긴급 패치
