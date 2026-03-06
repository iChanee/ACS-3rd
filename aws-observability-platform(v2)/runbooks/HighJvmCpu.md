# HighJvmCpu

## 개요
JVM CPU 사용률이 80%를 초과한 경우 발생하는 알람입니다.

## 심각도
critical

## 증상
- jvm_cpu_recent_utilization_ratio > 0.8
- 응답 지연 증가
- GC 빈도 급증 가능

## 원인 분류

### 1. 트래픽 급증
- 예상치 못한 요청량 증가
- 배치 작업과 실시간 트래픽 충돌

### 2. 메모리 부족으로 인한 GC 과부하
- Old Gen 가득 찬 경우 Full GC 반복
- 메모리 누수로 인한 점진적 GC 증가

### 3. 무한루프 또는 블로킹 연산
- CPU-intensive 연산 버그
- 외부 호출 타임아웃으로 인한 스레드 블로킹

### 4. 스레드 폭증
- 스레드 풀 설정 오류
- 동시 요청 과다

## 대응 절차
1. JVM 메모리 사용량 및 GC 빈도 확인
2. 스레드 수 이상 여부 확인
3. Heap dump 또는 Thread dump 수집
4. 트래픽 패턴 분석 (급증 여부)
5. 메모리 누수 의심 시 재시작 후 모니터링
6. 트래픽 급증 시 오토스케일링 또는 rate limiting 적용

## 확인 명령
```bash
# CPU 사용률 추이
jvm_cpu_recent_utilization_ratio

# GC 시간
rate(jvm_gc_duration_seconds_sum[5m])

# 스레드 수
jvm_thread_count
```

## 에스컬레이션
- CPU 90% 초과 후 3분 지속 시 → 즉시 재시작 검토
- 재시작 후에도 재발 시 → 개발팀 코드 리뷰 요청
