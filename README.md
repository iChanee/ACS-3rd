# 로그, 트레이스, 메트릭 모니터링 및 분석 플랫폼 인프라 구조

## 프로젝트 개요

AWS 기반 Observability 플랫폼으로, OpenTelemetry를 활용한 로그, 트레이스, 메트릭 수집 및 분석 시스템입니다.
외부 애플리케이션에서 전송된 텔레메트리 데이터를 수집하고, AI 기반 자동 분석 및 알림 기능을 제공합니다.

**프로젝트명**: log-platform-dev  
**리전**: ap-northeast-2 (서울)  
**환경**: development

---

## 아키텍처 다이어그램

```
[외부 OTel Collector]
        ↓ (OTLP gRPC/HTTP)
[Envoy Proxy - JWT 인증]
        ↓
[EC2 OTel Collector]
        ├─→ [Amazon Managed Prometheus (AMP)] - 메트릭
        ├─→ [OpenSearch Ingestion Pipeline] - 로그/트레이스
        │       ↓
        │   [OpenSearch Domain] - 로그/트레이스 저장 및 검색
        └─→ [S3 Buckets] - 장기 백업 (30일/365일)
                ↓
        [Glue Crawler + Athena] - 장기 분석

[AMP Alertmanager]
        ↓
    [SNS Topic]
        ↓
[Lambda - AI Agent]
        ├─→ [Bedrock] - AI 분석
        ├─→ [OpenSearch Serverless] - 런북 벡터 검색
        └─→ [Slack] - 알림 전송
```

---

## 1. 네트워크 구성

### VPC

- **CIDR**: 10.0.0.0/16
- **DNS 지원**: 활성화

### 서브넷

| 이름           | CIDR        | 가용영역        | 타입    | 용도                           |
| -------------- | ----------- | --------------- | ------- | ------------------------------ |
| public-subnet  | 10.0.1.0/24 | ap-northeast-2a | Public  | EC2 OTel Collector, OpenSearch |
| private-subnet | 10.0.2.0/24 | ap-northeast-2a | Private | Lambda 함수                    |

### 게이트웨이

- **Internet Gateway**: Public 서브넷 인터넷 연결
- **NAT Gateway**: Private 서브넷 아웃바운드 인터넷 연결 (Elastic IP 할당)

### 보안 그룹

#### otel-collector-sg

- **인바운드**:
  - SSH (22) - 관리용
  - OTLP gRPC (4317) - 외부 OTel Collector 데이터 수신
  - OTLP HTTP (4318) - 외부 OTel Collector 데이터 수신
- **아웃바운드**: 전체 허용

#### opensearch-sg

- **인바운드**:
  - HTTPS (443) - VPC 내부에서만 접근
  - Lambda Security Group에서 접근 허용
- **아웃바운드**: 전체 허용

#### lambda-sg

- **인바운드**: 없음
- **아웃바운드**: 전체 허용 (NAT Gateway 통해 인터넷 접근)

---

## 2. 데이터 수집 계층

### EC2 OTel Collector

- **인스턴스 타입**: t2.micro
- **AMI**: Ubuntu 22.04 (ami-0c9c942bd7bf113a2)
- **스토리지**: 8GB gp3
- **Elastic IP**: 고정 IP 할당
- **IAM Role**: AMP, S3, OSIS, CloudWatch 권한

#### 설치 컴포넌트

1. **OpenTelemetry Collector** (v0.119.0)
   - 내부 포트: 14317 (gRPC), 14318 (HTTP)
   - 프로세서: batch, memory_limiter
   - 익스포터: AMP, OSIS, S3

2. **Envoy Proxy**
   - 외부 포트: 4317 (gRPC), 4318 (HTTP)
   - JWT 인증: Cognito 연동
   - TLS: Self-signed 인증서

3. **SigV4 Proxy** (포트 8005)
   - Grafana → AMP 연동용

4. **Grafana** (포트 3000)
   - 메트릭 시각화

### Cognito 인증

- **User Pool**: 고객 OTel Collector 인증용
- **인증 방식**: OAuth 2.0 Client Credentials
- **스코프**: `https://{project_name}.otel/ingest`
- **토큰 엔드포인트**: `https://{domain}.auth.{region}.amazoncognito.com/oauth2/token`

---

## 3. 데이터 저장 계층

### Amazon Managed Prometheus (AMP)

- **용도**: 메트릭 저장 및 쿼리
- **Workspace Alias**: log-platform-dev-amp
- **Remote Write**: EC2 OTel Collector에서 전송
- **Alert Rules**: 5가지 알림 규칙 설정

### OpenSearch Domain

- **버전**: OpenSearch 2.11
- **인스턴스**: t3.small.search (1개)
- **스토리지**: 10GB gp3
- **보안**:
  - Fine-grained access control 활성화
  - 마스터 사용자: admin
  - VPC 내부 배치
  - 암호화: at-rest, node-to-node, HTTPS 강제
- **인덱스**:
  - 로그: `logs-YYYY.MM.dd`
  - 트레이스: `trace-analytics-raw`, `trace-analytics-service-map`
- **데이터 보관**: ISM 정책으로 30일 후 자동 삭제

### OpenSearch Ingestion Pipelines (OSIS)

#### logs-pipeline

- **소스**: OTLP logs (HTTP /v1/logs)
- **싱크**: OpenSearch (일별 인덱스)
- **용량**: 1-4 OCU (자동 스케일링)

#### traces-pipeline

- **소스**: OTLP traces (HTTP /v1/traces)
- **프로세서**: otel_traces, service_map
- **싱크**: OpenSearch (trace-analytics)
- **용량**: 1-4 OCU (자동 스케일링)

### S3 백업 버킷

| 버킷           | 용도               | 라이프사이클  |
| -------------- | ------------------ | ------------- |
| logs-backup    | 로그 장기 백업     | 30일 후 삭제  |
| traces-backup  | 트레이스 장기 백업 | 30일 후 삭제  |
| metrics-backup | 메트릭 장기 백업   | 365일 후 삭제 |
| runbooks       | AI 런북 저장       | 영구 보관     |
| athena-results | Athena 쿼리 결과   | 7일 후 삭제   |

---

## 4. 장기 분석 계층

### AWS Glue

- **Database**: log_platform_dev_observability
- **Crawlers**: 3개 (logs, traces, metrics)
  - 스케줄: 매일 새벽 2시 (cron: 0 2 \* _ ? _)
  - S3 데이터 스캔 및 스키마 자동 생성

### Amazon Athena

- **Workgroup**: log-platform-dev-observability
- **쿼리 결과 저장**: S3 athena-results 버킷
- **용도**: S3 백업 데이터 SQL 쿼리 분석

---

## 5. 알림 및 AI 분석 계층

### AMP Alertmanager

- **알림 규칙** (5개):
  1. **HighJvmCpu**: JVM CPU 80% 초과 (2분)
  2. **HighJvmMemory**: JVM 메모리 85% 초과 (2분)
  3. **HighHttpErrorRate**: HTTP 에러율 50% 초과 (30초)
  4. **HighHttpLatency**: P95 응답시간 1초 초과 (2분)
  5. **HighDbConnectionPending**: DB 커넥션 대기 5개 초과 (1분)

- **라우팅**:
  - critical: 10초 대기 후 전송
  - warning: 30초 대기 후 전송
  - 반복 간격: 5분

### SNS Topic

- **이름**: log-platform-dev-alerts
- **구독자**: Lambda 함수
- **발행자**: AMP Alertmanager

### Lambda - AI Observability Agent

- **런타임**: Python 3.12
- **메모리**: 512MB
- **타임아웃**: 300초 (5분)
- **VPC**: Private 서브넷 배치
- **Layer**: agent-deps (boto3, opensearch-py, langchain, langgraph 등)

#### 환경 변수

- AMP_ENDPOINT
- OPENSEARCH_ENDPOINT
- OPENSEARCH_USER / PASSWORD
- SLACK_BOT_TOKEN / SLACK_CHANNEL
- AOSS_ENDPOINT (런북 벡터 검색용)

#### 동작 흐름

```
AMP Alert → Alertmanager → SNS → Lambda (handler)
                                    ↓
                            LangGraph AI Agent
                                    ↓
                    ┌───────────────┼───────────────┐
                    ↓               ↓               ↓
            Metrics Agent    Logs Agent    Traces Agent
                    ↓               ↓               ↓
            (AMP 쿼리)      (OpenSearch)    (OpenSearch)
                    ↓               ↓               ↓
            PromQL 실행      로그 검색      트레이스 검색
                    └───────────────┼───────────────┘
                                    ↓
                            Bedrock (Claude)
                            종합 분석 및 JSON 생성
                                    ↓
                                Slack 전송
```

**상세 단계:**

1. **SNS에서 알림 수신** (lambda_handler.py)
   - 알림 파싱 (alertname, severity, service 등)

2. **즉시 Slack에 "분석 중..." 메시지 전송**
   - 사용자에게 빠른 피드백 제공

3. **LangGraph 기반 AI Agent 실행** (graph_agent.py)

   a. **Classify Node**: Bedrock Claude가 질문 분석
   - 어떤 데이터가 필요한지 판단 (metrics/logs/traces)

   b. **병렬 데이터 수집** (3개 Agent 동시 실행):
   - **Metrics Agent** (agents_aws.py)
     - Strands Agent가 상황에 맞는 Tool 선택 및 실행
     - Tools: `get_metrics_summary`, `get_jvm_metrics`, `get_http_metrics`
     - 실제 동작: boto3로 AMP에 SigV4 인증 후 PromQL 쿼리 실행
     - 예시 쿼리: `jvm_cpu_recent_utilization_ratio`, `histogram_quantile(0.95, ...)`
   - **Logs Agent** (agents_aws.py)
     - Strands Agent가 상황에 맞는 Tool 선택 및 실행
     - Tools: `get_logs_summary`, `search_logs`, `get_error_logs`
     - 실제 동작: OpenSearch REST API에 Basic Auth로 쿼리 실행
     - 예시: `logs-*` 인덱스에서 severity, keyword 검색
   - **Traces Agent** (agents_aws.py)
     - Strands Agent가 상황에 맞는 Tool 선택 및 실행
     - Tools: `get_traces_summary`, `get_slow_spans`, `get_trace_by_id`
     - 실제 동작: OpenSearch REST API로 `otel-v1-apm-span-*` 인덱스 쿼리
     - 예시: durationInNanos > threshold인 느린 span 검색

   c. **Runbook Search Node**
   - OpenSearch Serverless 벡터 검색
   - Bedrock Titan Embed로 임베딩 후 유사도 검색

   d. **Synthesize Node**: Bedrock Claude가 최종 분석
   - 입력: 3개 Agent 결과 + 런북 검색 결과
   - 출력: JSON 형식 IncidentReport
     ```json
     {
       "incident_summary": "한 문장 요약",
       "likely_root_causes": ["원인1", "원인2"],
       "severity": "critical",
       "impact": "영향 범위 설명",
       "immediate_actions": ["즉시 조치1", "즉시 조치2"],
       "follow_up_actions": ["후속 조치1", "후속 조치2"],
       "evidence_summary": ["근거1", "근거2"],
       "runbook_references": [...]
     }
     ```

4. **Slack에 최종 분석 결과 전송** (Block Kit 형식)
   - 기존 "분석 중..." 메시지 삭제
   - 최종 분석 결과 새로 전송 (색상, 섹션, 필드 포함)

### OpenSearch Serverless - 런북 벡터 검색

- **컬렉션 타입**: VECTORSEARCH
- **용도**: AI 런북 문서 임베딩 및 검색
- **인덱싱**: S3 runbooks/ 폴더에 .md 파일 업로드 시 Lambda 자동 실행
- **임베딩 모델**: Amazon Titan Embed Text v2

### Slack 연동

- **방식**: Slack Bot Token + Channel ID
- **메시지 형식**: Block Kit (색상, 섹션, 필드 지원)
- **알림 내용**:
  - 알림 정보 (이름, 심각도, 서비스)
  - 탐지 시각
  - 근본 원인 분석
  - 영향 범위
  - 권장 조치사항
  - AMP 콘솔 링크

---

## 6. IAM 역할 및 권한

### otel-collector-role (EC2)

- AMP: RemoteWrite, QueryMetrics
- S3: PutObject (백업 버킷)
- OSIS: Ingest (파이프라인)
- CloudWatch: PutMetricData

### osis-pipeline-role

- OpenSearch: DescribeDomain, ESHttp\*

### lambda-agent-role

- Logs: CreateLogGroup, CreateLogStream, PutLogEvents
- AMP: QueryMetrics, GetSeries, GetLabels
- OpenSearch: ESHttpGet, ESHttpPost
- Bedrock: InvokeModel
- S3: GetObject (runbooks)
- VPC: NetworkInterface 관리
- AOSS: APIAccessAll

### bedrock-agent-role

- AMP: QueryMetrics
- OpenSearch: ESHttpGet, ESHttpPost
- S3: GetObject, ListBucket (runbooks)
- Bedrock: InvokeModel

### glue-crawler-role

- Glue: AWSGlueServiceRole
- S3: GetObject, ListBucket (백업 버킷)

---

## 7. AI Agent 상세 동작 원리

### Lambda가 Bedrock과 AMP/OpenSearch를 사용하는 방식

Lambda 함수는 **LangGraph 워크플로우 + Strands Agent 3개** 구조를 사용합니다:

**구조:**

- **메인 Agent는 없음** - LangGraph가 워크플로우만 제어
- **Strands Agent 3개**: metrics_agent, logs_agent, traces_agent
- **Bedrock Claude (LLM 인스턴스 1개로 통합)** ✅
  - `shared_llm` (shared_llm.py): 모든 곳에서 공유
  - graph_agent.py: classify, synthesize에서 사용
  - agents_aws.py: 3개 Agent가 공유
- **총 LLM 호출**: 최대 5번
- **메모리 절약**: 50MB 절감 (100MB → 50MB)

#### 1단계: LangGraph 워크플로우 제어

- **graph_agent.py**가 전체 흐름을 제어
- 노드: classify → metrics/logs/traces (병렬) → runbook → synthesize
- 각 노드는 독립적으로 실행되며 상태(State)를 공유

#### 2단계: Bedrock Claude가 직접 분류 (classify_node)

- LangGraph의 classify_node에서 Bedrock Claude를 직접 호출
- 질문을 분석해서 어떤 데이터가 필요한지 판단 (metrics/logs/traces)

#### 3단계: Strands Agent 3개가 병렬 실행

- **agents_aws.py**에 3개의 전문 Agent 정의:
  - `metrics_agent`: 메트릭 분석 전문 (Strands Agent)
  - `logs_agent`: 로그 분석 전문 (Strands Agent)
  - `traces_agent`: 트레이스 분석 전문 (Strands Agent)

- 각 Agent는 **Bedrock Claude**를 LLM으로 사용
- Agent가 질문을 받으면 **자동으로 적절한 Tool을 선택하여 실행**

#### 4단계: Tool이 실제 데이터 조회

각 Tool 함수는 **직접** AWS 서비스에 쿼리를 실행합니다:

**Metrics Tools → AMP 쿼리**

```python
def query_amp(promql: str):
    # boto3로 SigV4 인증
    # AMP API에 PromQL 쿼리 전송
    # 예: jvm_cpu_recent_utilization_ratio
```

**Logs Tools → OpenSearch 쿼리**

```python
def query_opensearch(index: str, query: dict):
    # Basic Auth로 OpenSearch REST API 호출
    # 예: logs-* 인덱스에서 ERROR 로그 검색
```

**Traces Tools → OpenSearch 쿼리**

```python
def query_opensearch("otel-v1-apm-span-*", query):
    # OpenSearch REST API로 트레이스 데이터 조회
    # 예: durationInNanos > 100ms인 느린 span 검색
```

#### 5단계: Bedrock이 결과 해석

- **Metrics Agent**: Tool 실행 결과를 받아 Bedrock이 해석
  - "JVM CPU 80% 초과, 메모리 85% 사용 중" → "리소스 부족 상태"
- **Logs Agent**: Tool 실행 결과를 받아 Bedrock이 해석
  - "ERROR 로그 50건, OutOfMemoryError 발견" → "메모리 부족으로 인한 장애"
- **Traces Agent**: Tool 실행 결과를 받아 Bedrock이 해석
  - "P95 응답시간 2초, DB 쿼리 느림" → "데이터베이스 성능 저하"

#### 6단계: Bedrock이 최종 종합 분석 (synthesize_node)

- **Synthesize Node**에서 Bedrock Claude를 직접 호출
- 입력: 3개 Agent의 분석 결과 + 런북 검색 결과
- 출력: 구조화된 JSON (IncidentReport)

### 핵심 포인트

1. **LangGraph는 워크플로우 오케스트레이터**
   - 메인 Agent가 아님
   - 노드 간 실행 순서와 상태 관리만 담당

2. **Strands Agent 3개가 실제 분석 수행**
   - metrics_agent, logs_agent, traces_agent
3. **Bedrock Claude 사용 (LLM 인스턴스 1개로 통합)** ✅
   - **shared_llm.py의 `shared_llm`**: 모든 곳에서 공유
   - graph_agent.py: classify_node, synthesize_node에서 사용
   - agents_aws.py: 3개 Strands Agent가 공유
   - 총 LLM 호출: 최대 5번 (classify + 3개 agent + synthesize)
   - 총 LLM 인스턴스: 1개만 생성 (메모리 50% 절감)model`**: 3개 Strands Agent가 공유
   - 총 LLM 호출: 최대 5번 (classify + 3개 agent + synthesize)
   - 총 LLM 인스턴스: 2개만 생성

4. **실제 데이터 조회는 Tool 함수가 직접 수행**
   - AMP: boto3 + SigV4 인증 + PromQL
   - OpenSearch: urllib + Basic Auth + REST API

5. **Bedrock은 데이터를 직접 보지 않음**
   - Tool이 조회한 결과(텍스트)를 받아서 해석만 함
   - 예: "CPU 80%" → Bedrock → "리소스 부족 상태로 판단됨"

### 데이터 흐름 예시

```
알람 발생: HighJvmCpu
    ↓
Lambda Handler: "JVM CPU 80% 초과 알람 분석해줘"
    ↓
LangGraph classify_node: Bedrock Claude 직접 호출
    → "metrics 데이터 필요"
    ↓
LangGraph metrics_node: metrics_agent 실행
    ↓
Metrics Agent (Strands Agent + Bedrock): "get_jvm_metrics 실행해야겠다"
    ↓
get_jvm_metrics Tool: AMP에 Prom QL 쿼리
    → jvm_cpu_recent_utilization_ratio
    → 결과: service-a: 0.85, service-b: 0.45
    ↓
Metrics Agent (Bedrock): "service-a의 CPU가 85%로 높음"
    ↓
LangGraph synthesize_node: Bedrock Claude 직접 호출
    → 모든 결과 종합
    → "service-a의 CPU 과부하로 인한 성능 저하"
    → JSON 생성
    ↓
Slack 전송
```

---

## 8. 데이터 흐름

### 메트릭 흐름

```
외부 앱 → Envoy (JWT) → EC2 OTel → AMP
                              ↓
                            S3 백업
```

### 로그 흐름

```
외부 앱 → Envoy (JWT) → EC2 OTel → OSIS Logs → OpenSearch
                              ↓
                            S3 백업 → Glue → Athena
```

### 트레이스 흐름

```
외부 앱 → Envoy (JWT) → EC2 OTel → OSIS Traces → OpenSearch
                              ↓                    (Service Map)
                            S3 백업 → Glue → Athena
```

### 알림 흐름

```
AMP Alert → Alertmanager → SNS → Lambda → AI 분석 → Slack
                                    ↓
                            AMP + OpenSearch + Bedrock
```

---

## 9. 주요 엔드포인트

### 데이터 수집

- **OTLP gRPC**: `{EC2_PUBLIC_IP}:4317` (Envoy, JWT 필요)
- **OTLP HTTP**: `http://{EC2_PUBLIC_IP}:4318` (Envoy, JWT 필요)

### 대시보드

- **OpenSearch Dashboards**: `https://{opensearch_endpoint}/_dashboards`
- **Grafana**: `http://{EC2_PUBLIC_IP}:3000`
- **AMP Console**: AWS Console → Prometheus

### 인증

- **Cognito Token**: `https://{domain}.auth.{region}.amazoncognito.com/oauth2/token`
- **JWKS URI**: `https://cognito-idp.{region}.amazonaws.com/{pool_id}/.well-known/jwks.json`

---

## 10. 비용 최적화

### 데이터 보관 정책

- OpenSearch: 30일 (ISM 정책)
- S3 로그/트레이스: 30일
- S3 메트릭: 365일
- Athena 쿼리 결과: 7일

### 리소스 크기

- EC2: t2.micro (프리티어)
- OpenSearch: t3.small.search (최소 사양)
- OSIS: 1-4 OCU (자동 스케일링)
- Lambda: 512MB (필요 시만 실행)

---

## 11. 보안 구성

### 네트워크 보안

- VPC 격리
- Security Group 최소 권한
- Private 서브넷 (Lambda)
- NAT Gateway (아웃바운드만)

### 데이터 암호화

- OpenSearch: at-rest, node-to-node, TLS 1.2+
- S3: 기본 암호화
- Envoy: TLS (Self-signed)

### 인증/인가

- Cognito JWT 토큰 검증
- OpenSearch Fine-grained Access Control
- IAM Role 기반 권한 관리
- Secrets: terraform.tfvars (민감 정보)

---

## 12. 모니터링 및 운영

### 헬스 체크

```bash
# EC2 SSH 접속
ssh -i {key_path} ubuntu@{EC2_PUBLIC_IP}

# OTel Collector 상태
sudo systemctl status otelcol
sudo journalctl -u otelcol -f

# Envoy 상태
docker logs envoy -f

# Grafana 상태
sudo systemctl status grafana-server
```

### 로그 확인

- **OTel Collector**: `journalctl -u otelcol`
- **Envoy**: `docker logs envoy`
- **Lambda**: CloudWatch Logs `/aws/lambda/{function_name}`

### 알림 테스트

1. AMP Console에서 알림 규칙 확인
2. 테스트 메트릭 전송
3. SNS → Lambda → Slack 흐름 확인

---

## 13. 배포 방법

### 사전 준비

1. AWS CLI 설치 및 자격 증명 설정
2. Terraform 설치 (>= 1.0)
3. EC2 Key Pair 생성 (.pem 파일 다운로드)
4. Slack Bot Token 및 Channel ID 준비

### 배포 단계

```bash
# 1. 변수 파일 설정
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars 편집 (키, 비밀번호, Slack 정보 등)

# 2. Terraform 초기화
terraform init

# 3. 계획 확인
terraform plan

# 4. 배포 실행
terraform apply

# 5. 출력 확인
terraform output
terraform output -raw cognito_client_secret
```

### 배포 후 설정

1. OpenSearch 대시보드 접속 (admin 계정)
2. Grafana 데이터 소스 설정 (AMP)
3. 외부 OTel Collector 설정 (Cognito 토큰)
4. S3에 런북 업로드 (`runbooks/` 폴더)

---

## 14. 주요 파일 구조

```
.
├── main.tf                    # 메인 인프라 (VPC, EC2, AMP, OpenSearch, S3, Glue, Athena, Cognito)
├── alert_infra.tf             # 알림 인프라 (SNS, Lambda, Alertmanager)
├── opensearch_serverless.tf   # 런북 벡터 검색 (AOSS, Lambda 인덱서)
├── variables.tf               # 변수 정의
├── outputs.tf                 # 출력 값
├── terraform.tfvars           # 변수 값 (민감 정보 포함)
├── files/
│   └── user_data.sh          # EC2 초기화 스크립트
├── lambda_package/
│   ├── shared_llm.py         # 공유 LLM 인스턴스 (통합)
│   ├── lambda_handler.py     # Lambda 메인 핸들러
│   ├── graph_agent.py        # LangGraph AI Agent
│   ├── agents_aws.py         # AWS 연동 에이전트
│   ├── runbooks_aws.py       # 런북 벡터 검색
│   └── slack_templates.py    # Slack 메시지 템플릿
└── lambda_layer/             # Lambda 의존성 패키지
```

---

## 15. 확장 계획

### 단기

- [ ] Grafana 대시보드 자동 프로비저닝
- [ ] 추가 알림 규칙 (디스크, 네트워크)
- [ ] 런북 자동 생성 (Bedrock)

### 중기

- [ ] Multi-region 지원
- [ ] 고가용성 구성 (Multi-AZ)
- [ ] 커스텀 메트릭 수집

### 장기

- [ ] 머신러닝 기반 이상 탐지
- [ ] 자동 복구 (Auto-remediation)
- [ ] 비용 최적화 자동화

---

## 16. 문제 해결

### EC2 OTel Collector 연결 실패

- Security Group 4317/4318 포트 확인
- Envoy 로그 확인: `docker logs envoy`
- JWT 토큰 유효성 확인

### OpenSearch 접근 불가

- VPC 내부에서만 접근 가능 (EC2 SSH 터널링)
- Role 매핑 확인 (null_resource 실행 여부)

### Lambda 타임아웃

- VPC NAT Gateway 정상 동작 확인
- OpenSearch 쿼리 최적화
- 메모리 증설 (512MB → 1024MB)

### Slack 알림 미수신

- SNS → Lambda 구독 확인
- Lambda 로그 확인 (CloudWatch)
- Slack Bot Token 권한 확인

---

## 참고 자료

- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [Amazon Managed Prometheus](https://docs.aws.amazon.com/prometheus/)
- [OpenSearch](https://opensearch.org/docs/latest/)
- [AWS Lambda](https://docs.aws.amazon.com/lambda/)
- [LangGraph](https://langchain-ai.github.io/langgraph/)
- [Envoy Proxy](https://www.envoyproxy.io/docs/envoy/latest/)
