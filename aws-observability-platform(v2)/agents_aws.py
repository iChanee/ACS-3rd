"""
AWS Observability Agent - AWS 환경용 Tool 함수
agents.py (로컬 JSON) 대신 실제 AMP/OpenSearch를 쿼리

환경변수:
    AMP_ENDPOINT        - AMP workspace endpoint
    OPENSEARCH_ENDPOINT - OpenSearch domain endpoint
    OPENSEARCH_USER     - OpenSearch 사용자
    OPENSEARCH_PASSWORD - OpenSearch 비밀번호
    AWS_REGION_NAME     - AWS 리전 (기본: ap-northeast-2)
"""

import os
import json
import boto3
import urllib.request
import urllib.parse
import base64
from datetime import datetime, timedelta

from strands import Agent, tool
from strands.models import BedrockModel

# ============================================================
# 환경변수
# ============================================================
AMP_ENDPOINT       = os.environ.get("AMP_ENDPOINT", "")
OS_ENDPOINT        = os.environ.get("OPENSEARCH_ENDPOINT", "")
OS_USER            = os.environ.get("OPENSEARCH_USER", "admin")
OS_PASSWORD        = os.environ.get("OPENSEARCH_PASSWORD", "")
AWS_REGION         = os.environ.get("AWS_REGION_NAME", "ap-northeast-2")


# ============================================================
# AMP 쿼리 헬퍼
# ============================================================
def query_amp(promql: str, time_range_minutes: int = 60) -> list:
    """AMP에 PromQL 쿼리 실행"""
    try:
        session = boto3.Session()
        credentials = session.get_credentials().get_frozen_credentials()

        from botocore.auth import SigV4Auth
        from botocore.awsrequest import AWSRequest

        end_time = datetime.utcnow()
        start_time = end_time - timedelta(minutes=time_range_minutes)

        url = (
            f"{AMP_ENDPOINT}api/v1/query_range"
            f"?query={urllib.parse.quote(promql)}"
            f"&start={start_time.timestamp()}"
            f"&end={end_time.timestamp()}"
            f"&step=60"
        )

        request = AWSRequest(method="GET", url=url)
        SigV4Auth(credentials, "aps", AWS_REGION).add_auth(request)

        req = urllib.request.Request(url, headers=dict(request.headers))
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            return data.get("data", {}).get("result", [])
    except Exception as e:
        return [{"error": str(e)}]


def query_amp_instant(promql: str) -> list:
    """AMP에 즉시 쿼리 실행 (현재 값)"""
    try:
        session = boto3.Session()
        credentials = session.get_credentials().get_frozen_credentials()

        from botocore.auth import SigV4Auth
        from botocore.awsrequest import AWSRequest

        url = f"{AMP_ENDPOINT}api/v1/query?query={urllib.parse.quote(promql)}"
        request = AWSRequest(method="GET", url=url)
        SigV4Auth(credentials, "aps", AWS_REGION).add_auth(request)

        req = urllib.request.Request(url, headers=dict(request.headers))
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            return data.get("data", {}).get("result", [])
    except Exception as e:
        return [{"error": str(e)}]


# ============================================================
# OpenSearch 쿼리 헬퍼
# ============================================================
def query_opensearch(index: str, query: dict) -> dict:
    """OpenSearch에 쿼리 실행"""
    try:
        credentials = base64.b64encode(f"{OS_USER}:{OS_PASSWORD}".encode()).decode()
        url = f"https://{OS_ENDPOINT}/{index}/_search"
        payload = json.dumps(query).encode("utf-8")

        req = urllib.request.Request(
            url,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Basic {credentials}"
            },
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return {"error": str(e), "hits": {"hits": []}}


# ============================================================
# Metrics Tools
# ============================================================

@tool
def get_metrics_summary() -> str:
    """
    전체 서비스의 메트릭 요약 (CPU, 메모리, HTTP 요청)을 AMP에서 조회합니다.
    """
    lines = ["=== 메트릭 요약 ==="]

    # CPU 사용률
    cpu_results = query_amp_instant("jvm_cpu_recent_utilization_ratio")
    if cpu_results and "error" not in cpu_results[0]:
        lines.append("[CPU 사용률]")
        for r in cpu_results:
            service = r.get("metric", {}).get("job", "unknown")
            value = float(r.get("value", [0, 0])[1])
            lines.append(f"  {service}: {value*100:.1f}%")

    # 메모리 사용률
    mem_results = query_amp_instant(
        "jvm_memory_used_bytes / jvm_memory_limit_bytes"
    )
    if mem_results and "error" not in mem_results[0]:
        lines.append("[메모리 사용률]")
        for r in mem_results:
            service = r.get("metric", {}).get("job", "unknown")
            value = float(r.get("value", [0, 0])[1])
            lines.append(f"  {service}: {value*100:.1f}%")

    # HTTP 요청 수
    http_results = query_amp_instant(
        "sum(rate(http_server_request_duration_seconds_count[5m])) by (job)"
    )
    if http_results and "error" not in http_results[0]:
        lines.append("[HTTP 요청/초]")
        for r in http_results:
            service = r.get("metric", {}).get("job", "unknown")
            value = float(r.get("value", [0, 0])[1])
            lines.append(f"  {service}: {value:.2f} req/s")

    return "\n".join(lines)


@tool
def get_jvm_metrics(service_name: str = "") -> str:
    """
    JVM 메트릭 (메모리, GC, 스레드)을 AMP에서 조회합니다.
    Args:
        service_name: 조회할 서비스명 (비어있으면 전체)
    """
    filter_str = f'{{job="{service_name}"}}' if service_name else ""
    lines = ["=== JVM 메트릭 ==="]

    metrics = {
        "메모리 사용(MB)": f"jvm_memory_used_bytes{filter_str} / 1024 / 1024",
        "메모리 한계(MB)": f"jvm_memory_limit_bytes{filter_str} / 1024 / 1024",
        "GC후 메모리(MB)": f"jvm_memory_committed_bytes{filter_str} / 1024 / 1024",
        "스레드 수": f"jvm_thread_count{filter_str}",
        "CPU 사용률": f"jvm_cpu_recent_utilization_ratio{filter_str}",
    }

    for label, query in metrics.items():
        results = query_amp_instant(query)
        if results and "error" not in results[0]:
            lines.append(f"[{label}]")
            for r in results:
                service = r.get("metric", {}).get("job", "unknown")
                value = float(r.get("value", [0, 0])[1])
                lines.append(f"  {service}: {value:.2f}")

    return "\n".join(lines)


@tool
def get_http_metrics(service_name: str = "") -> str:
    """
    HTTP 메트릭 (요청 수, 에러율, 응답시간)을 AMP에서 조회합니다.
    Args:
        service_name: 조회할 서비스명 (비어있으면 전체)
    """
    filter_str = f'{{job="{service_name}"}}' if service_name else ""
    lines = ["=== HTTP 메트릭 ==="]

    # 에러율
    error_results = query_amp_instant(
        f"rate(http_server_request_duration_seconds_count{{http_response_status_code=~\"4..|5..\"{(',' + filter_str[1:]) if service_name else ''}}}[5m])"
        f" / rate(http_server_request_duration_seconds_count{filter_str}[5m])"
    )
    if error_results and "error" not in error_results[0]:
        lines.append("[HTTP 에러율]")
        for r in error_results:
            service = r.get("metric", {}).get("job", "unknown")
            value = float(r.get("value", [0, 0])[1])
            lines.append(f"  {service}: {value*100:.2f}%")

    # P95 응답시간
    latency_results = query_amp_instant(
        f"histogram_quantile(0.95, rate(http_server_request_duration_seconds_bucket{filter_str}[5m]))"
    )
    if latency_results and "error" not in latency_results[0]:
        lines.append("[P95 응답시간]")
        for r in latency_results:
            service = r.get("metric", {}).get("job", "unknown")
            value = float(r.get("value", [0, 0])[1])
            lines.append(f"  {service}: {value*1000:.2f}ms")

    return "\n".join(lines)


# ============================================================
# Logs Tools
# ============================================================

@tool
def get_logs_summary() -> str:
    """
    최근 로그 요약 (서비스별 severity 분포)을 OpenSearch에서 조회합니다.
    """
    query = {
        "size": 0,
        "query": {
            "range": {
                "time": {
                    "gte": "now-1h"
                }
            }
        },
        "aggs": {
            "by_service": {
                "terms": {"field": "serviceName", "size": 10},
                "aggs": {
                    "by_severity": {
                        "terms": {"field": "severityText", "size": 5}
                    }
                }
            }
        }
    }

    result = query_opensearch("logs-*", query)
    lines = ["=== 로그 요약 (최근 1시간) ==="]

    buckets = result.get("aggregations", {}).get("by_service", {}).get("buckets", [])
    for b in buckets:
        service = b.get("key", "unknown")
        lines.append(f"[{service}]")
        for sev in b.get("by_severity", {}).get("buckets", []):
            lines.append(f"  {sev['key']}: {sev['doc_count']}건")

    if not buckets:
        lines.append("로그 데이터 없음")

    return "\n".join(lines)


@tool
def search_logs(severity: str = "", keyword: str = "") -> str:
    """
    특정 severity 또는 키워드로 로그를 OpenSearch에서 검색합니다.
    Args:
        severity: 로그 레벨 (ERROR, WARN, INFO 등)
        keyword: 검색 키워드
    """
    must_clauses = [{"range": {"time": {"gte": "now-1h"}}}]

    if severity:
        must_clauses.append({"term": {"severityText": severity}})
    if keyword:
        must_clauses.append({"match": {"body": keyword}})

    query = {
        "size": 20,
        "query": {"bool": {"must": must_clauses}},
        "sort": [{"time": {"order": "desc"}}]
    }

    result = query_opensearch("logs-*", query)
    hits = result.get("hits", {}).get("hits", [])

    if not hits:
        return f"조건에 맞는 로그 없음 (severity={severity}, keyword={keyword})"

    lines = [f"=== 로그 검색 결과 ({len(hits)}건) ==="]
    for h in hits:
        src = h.get("_source", {})
        timestamp = src.get("time", "")
        svc = src.get("serviceName", "unknown")
        sev = src.get("severityText", "")
        body = src.get("body", "")
        lines.append(f"  [{timestamp}] [{svc}] {sev}: {body[:100]}")

    return "\n".join(lines)


@tool
def get_error_logs() -> str:
    """
    최근 ERROR/WARN 로그를 OpenSearch에서 조회합니다.
    """
    query = {
        "size": 20,
        "query": {
            "bool": {
                "must": [
                    {"range": {"time": {"gte": "now-1h"}}},
                    {"terms": {"severityText": ["ERROR", "WARN"]}}
                ]
            }
        },
        "sort": [{"time": {"order": "desc"}}]
    }

    result = query_opensearch("logs-*", query)
    hits = result.get("hits", {}).get("hits", [])

    if not hits:
        return "최근 1시간 ERROR/WARN 로그 없음"

    lines = [f"=== ERROR/WARN 로그 ({len(hits)}건) ==="]
    for h in hits:
        src = h.get("_source", {})
        timestamp = src.get("time", "")
        svc = src.get("serviceName", "unknown")
        sev = src.get("severityText", "")
        body = src.get("body", "")
        lines.append(f"  [{timestamp}] [{svc}] {sev}: {body[:150]}")

    return "\n".join(lines)


# ============================================================
# Traces Tools
# ============================================================

@tool
def get_traces_summary() -> str:
    """
    트레이스 요약 (서비스별 span 수, 평균 응답시간, 에러율)을 OpenSearch에서 조회합니다.
    """
    one_hour_ago = (datetime.utcnow() - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%S.000000000Z")
    query = {
        "size": 0,
        "aggs": {
            "recent": {
                "filter": {"range": {"startTime": {"gte": one_hour_ago}}},
                "aggs": {
                    "by_service": {
                        "terms": {"field": "serviceName", "size": 10},
                        "aggs": {
                            "avg_duration": {"avg": {"field": "durationInNanos"}},
                            "error_count": {
                                "filter": {"term": {"status.code": 2}}
                            }
                        }
                    }
                }
            }
        }
    }

    result = query_opensearch("otel-v1-apm-span-*", query)
    lines = ["=== 트레이스 요약 (최근 1시간) ==="]

    buckets = result.get("aggregations", {}).get("recent", {}).get("by_service", {}).get("buckets", [])
    for b in buckets:
        service = b.get("key", "unknown")
        count = b.get("doc_count", 0)
        avg_ns = b.get("avg_duration", {}).get("value", 0) or 0
        avg_ms = avg_ns / 1_000_000
        errors = b.get("error_count", {}).get("doc_count", 0)
        error_rate = (errors / count * 100) if count > 0 else 0
        lines.append(f"[{service}]")
        lines.append(f"  span 수: {count}개, 평균 응답시간: {avg_ms:.2f}ms, 에러율: {error_rate:.1f}%")

    if not buckets:
        lines.append("트레이스 데이터 없음")

    return "\n".join(lines)


@tool
def get_slow_spans(threshold_ms: float = 100.0) -> str:
    """
    임계값 이상의 느린 span을 OpenSearch에서 조회합니다.
    Args:
        threshold_ms: 느린 span 기준 시간(밀리초), 기본값 100ms
    """
    threshold_ns = threshold_ms * 1_000_000
    one_hour_ago = (datetime.utcnow() - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%S.000000000Z")

    query = {
        "size": 20,
        "query": {
            "bool": {
                "must": [
                    {"range": {"startTime": {"gte": one_hour_ago}}},
                    {"range": {"durationInNanos": {"gte": threshold_ns}}}
                ]
            }
        },
        "sort": [{"durationInNanos": {"order": "desc"}}]
    }

    result = query_opensearch("otel-v1-apm-span-*", query)
    hits = result.get("hits", {}).get("hits", [])

    if not hits:
        return f"threshold {threshold_ms}ms를 초과하는 slow span이 없습니다."

    lines = [f"=== Slow Spans (>{threshold_ms}ms) ==="]
    for h in hits:
        src = h.get("_source", {})
        service = src.get("serviceName", "unknown")
        name = src.get("name", "unknown")
        duration_ms = src.get("durationInNanos", 0) / 1_000_000
        trace_id = src.get("traceId", "")[:16]
        lines.append(f"  [{service}] {name}: {duration_ms:.2f}ms (traceId: {trace_id}...)")

    return "\n".join(lines)


@tool
def get_trace_by_id(trace_id: str) -> str:
    """
    특정 traceId의 전체 span을 OpenSearch에서 조회합니다.
    Args:
        trace_id: 조회할 trace ID
    """
    query = {
        "size": 50,
        "query": {"term": {"traceId.keyword": trace_id}},
        "sort": [{"startTime": {"order": "asc"}}]
    }

    result = query_opensearch("otel-v1-apm-span-*", query)
    hits = result.get("hits", {}).get("hits", [])

    if not hits:
        return f"traceId {trace_id}에 해당하는 span이 없습니다."

    lines = [f"=== Trace {trace_id[:16]}... ({len(hits)}개 span) ==="]
    for h in hits:
        src = h.get("_source", {})
        service = src.get("serviceName", "unknown")
        name = src.get("name", "unknown")
        duration_ms = src.get("durationInNanos", 0) / 1_000_000
        status = src.get("status", {}).get("code", 0)
        status_str = "❌ ERROR" if status == 2 else "✅"
        lines.append(f"  {status_str} [{service}] {name}: {duration_ms:.2f}ms")

    return "\n".join(lines)


# ============================================================
# Agent 정의 (agents.py와 동일한 구조)
# ============================================================

model = BedrockModel(
    model_id="apac.anthropic.claude-sonnet-4-20250514-v1:0",
    region_name=AWS_REGION,
    streaming=False
)

metrics_agent = Agent(
    model=model,
    system_prompt="""Metrics 전문 분석가. 반드시 Tool 호출.
- 핵심 수치만 간결하게 표로 정리
- 3줄 이내 결론
- 코드 예시, 권장사항 제외
- Tool은 한 번에 하나씩만 호출
- 문제 없으면 "정상" 한 줄로 끝""",
    tools=[get_metrics_summary, get_jvm_metrics, get_http_metrics],
)

logs_agent = Agent(
    model=model,
    system_prompt="""Logs 전문 분석가. 반드시 Tool 호출.
- 발견된 이슈만 간결하게 요약
- 이슈 없으면 "정상" 한 줄로 끝
- 로그 없는 서비스는 언급하지 말 것
- 코드 예시 제외""",
    tools=[get_logs_summary, search_logs, get_error_logs],
)

traces_agent = Agent(
    model=model,
    system_prompt="""Traces 전문 분석가. 반드시 Tool 호출.
- 서비스별 응답시간, 에러율만 표로 정리
- 느린 요청 있으면 서비스, ms만 명시
- 코드 예시 제외
- 문제 없으면 "정상" 한 줄로 끝""",
    tools=[get_traces_summary, get_slow_spans, get_trace_by_id],
)