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

1. SNS에서 알림 수신
2. 즉시 Slack에 "분석 중..." 메시지 전송
3. LangGraph 기반 AI Agent 실행:
   - 메트릭 분석 (AMP 쿼리)
   - 로그 분석 (OpenSearch 쿼리)
   - 트레이스 분석 (OpenSearch 쿼리)
   - 런북 검색 (OpenSearch Serverless 벡터 검색)
   - Bedrock으로 종합 분석
4. Slack에 최종 분석 결과 전송 (Block Kit 형식)

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

## 7. 데이터 흐름

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

## 8. 주요 엔드포인트

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

## 9. 비용 최적화

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

## 10. 보안 구성

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

## 11. 모니터링 및 운영

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

## 12. 배포 방법

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

## 13. 주요 파일 구조

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
│   ├── lambda_handler.py     # Lambda 메인 핸들러
│   ├── graph_agent.py        # LangGraph AI Agent
│   ├── agents_aws.py         # AWS 연동 에이전트
│   └── slack_templates.py    # Slack 메시지 템플릿
└── lambda_layer/             # Lambda 의존성 패키지
```

---

## 14. 확장 계획

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

## 15. 문제 해결

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
