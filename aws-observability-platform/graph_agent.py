"""
AWS Observability Platform - Graph Agent
LangGraph로 흐름을 제어하고, 각 노드 안에서 Strands Agents as Tools 패턴 사용

구조:
    classify → metrics/logs/traces (병렬) + runbook_search → synthesize
"""

import os
import json
from typing import TypedDict, Annotated

from langgraph.graph import StateGraph, END
from langchain_aws import ChatBedrockConverse

from agents_aws import (
    get_metrics_summary, get_jvm_metrics, get_http_metrics,
    get_logs_summary, search_logs, get_error_logs,
    get_traces_summary, get_slow_spans, get_trace_by_id,
    metrics_agent, logs_agent, traces_agent
)
from runbooks_aws import search_runbook


# ============================================================
# 1. State 정의
# ============================================================
class ObservabilityState(TypedDict):
    question:        Annotated[str, lambda x, y: y]
    alert_name:      Annotated[str, lambda x, y: y]
    severity:        Annotated[str, lambda x, y: y]
    amp_link:        Annotated[str, lambda x, y: y]
    category:        Annotated[list[str], lambda x, y: y]
    metrics_result:  Annotated[str, lambda x, y: y]
    logs_result:     Annotated[str, lambda x, y: y]
    traces_result:   Annotated[str, lambda x, y: y]
    runbook_result:  Annotated[str, lambda x, y: y]
    final_answer:    Annotated[str, lambda x, y: y]   # JSON 문자열 (IncidentReport)


# ============================================================
# 2. LLM 설정
# ============================================================
llm = ChatBedrockConverse(
    model="apac.anthropic.claude-sonnet-4-20250514-v1:0",
    region_name="ap-northeast-2",
)


# ============================================================
# 3. 노드 정의
# ============================================================

def classify_node(state: ObservabilityState) -> ObservabilityState:
    question = state["question"]

    prompt = f"""다음 질문을 분석해서 어떤 데이터가 필요한지 판단하세요.

질문: {question}

반드시 아래 카테고리 중 해당하는 것만 골라서 쉼표로 구분해서 답하세요.
다른 말은 절대 하지 마세요.

카테고리:
- metrics: JVM, CPU, 메모리, HTTP 응답시간, DB 커넥션 관련
- logs: 로그, 에러, WARN, INFO, 이벤트 관련
- traces: 트레이스, 느린 요청, 응답시간, 서비스 간 호출 관련
- all: 전체 점검, 종합 분석, 시스템 상태 전반

답변 (카테고리만):"""

    response = llm.invoke(prompt)
    categories_str = response.content.strip().lower()

    if "all" in categories_str:
        categories = ["metrics", "logs", "traces"]
    else:
        categories = [c.strip() for c in categories_str.split(",") if c.strip() in ["metrics", "logs", "traces"]]

    if not categories:
        categories = ["metrics", "logs", "traces"]

    print(f"📋 분류 결과: {categories}")
    return {**state, "category": categories}


def metrics_node(state: ObservabilityState) -> ObservabilityState:
    if "metrics" not in state.get("category", []):
        return {**state, "metrics_result": ""}

    print("📊 Metrics Agent 실행 중...")
    result = metrics_agent(state["question"])
    return {**state, "metrics_result": str(result)}


def logs_node(state: ObservabilityState) -> ObservabilityState:
    if "logs" not in state.get("category", []):
        return {**state, "logs_result": ""}

    print("📝 Logs Agent 실행 중...")
    result = logs_agent(state["question"])
    return {**state, "logs_result": str(result)}


def traces_node(state: ObservabilityState) -> ObservabilityState:
    if "traces" not in state.get("category", []):
        return {**state, "traces_result": ""}

    print("🔍 Traces Agent 실행 중...")
    result = traces_agent(state["question"])
    return {**state, "traces_result": str(result)}


def runbook_node(state: ObservabilityState) -> ObservabilityState:
    """관련 런북 벡터 검색"""
    print("📖 런북 검색 중...")
    try:
        query = f"{state.get('alert_name', '')} {state['question']}"
        runbooks = search_runbook(query, n_results=2)

        if not runbooks:
            return {**state, "runbook_result": "관련 런북 없음"}

        lines = []
        for rb in runbooks:
            lines.append(f"[{rb['title']}] (관련도: {rb['relevance']:.2f})")
            lines.append(f"  심각도: {rb['severity']}")
            if rb.get("action"):
                # 대응 절차 첫 5줄만
                action_lines = rb["action"].split("\n")[:5]
                lines.append("  대응 절차:")
                for al in action_lines:
                    if al.strip():
                        lines.append(f"    {al.strip()}")

        return {**state, "runbook_result": "\n".join(lines)}

    except Exception as e:
        print(f"런북 검색 오류: {e}")
        return {**state, "runbook_result": f"런북 검색 실패: {e}"}


def synthesize_node(state: ObservabilityState) -> ObservabilityState:
    """분석 결과 + 런북 → IncidentReport JSON 생성"""
    print("🧩 결과 종합 중...")

    parts = []
    if state.get("metrics_result"):
        parts.append(f"[메트릭 분석]\n{state['metrics_result']}")
    if state.get("logs_result"):
        parts.append(f"[로그 분석]\n{state['logs_result']}")
    if state.get("traces_result"):
        parts.append(f"[트레이스 분석]\n{state['traces_result']}")
    if state.get("runbook_result"):
        parts.append(f"[런북 참조]\n{state['runbook_result']}")

    combined = "\n\n".join(parts)
    alert_name = state.get("alert_name", "Unknown")
    severity   = state.get("severity", "critical")

    prompt = f"""당신은 AWS 옵저버빌리티 플랫폼의 인시던트 분석 AI입니다.

알람명: {alert_name}
심각도: {severity}
질문: {state['question']}

분석 데이터:
{combined}

위 데이터를 바탕으로 아래 JSON 형식으로만 답변하세요.
다른 텍스트, 마크다운 백틱, 설명은 절대 포함하지 마세요.
반드시 유효한 JSON만 출력하세요.

{{
  "incident_summary": "한 문장 요약",
  "likely_root_causes": ["원인1", "원인2"],
  "severity": "{severity}",
  "impact": "영향 범위 설명",
  "immediate_actions": ["즉시 조치1", "즉시 조치2"],
  "follow_up_actions": ["후속 조치1", "후속 조치2"],
  "evidence_summary": ["근거1", "근거2", "근거3"],
  "runbook_references": [
    {{
      "source": "런북 파일명",
      "section": "참조 섹션",
      "relevance": "현재 장애와의 관련성"
    }}
  ]
}}"""

    response = llm.invoke(prompt)
    raw = response.content.strip()

    # JSON 파싱 검증
    try:
        parsed = json.loads(raw)
        final = json.dumps(parsed, ensure_ascii=False)
    except json.JSONDecodeError:
        # 파싱 실패 시 fallback
        fallback = {
            "incident_summary": f"{alert_name} 알람 발생 - 상세 분석 필요",
            "likely_root_causes": ["분석 데이터 부족"],
            "severity": severity,
            "impact": "영향 범위 파악 중",
            "immediate_actions": ["시스템 로그 즉시 확인", "담당자 호출"],
            "follow_up_actions": ["근본 원인 분석", "재발 방지 대책 수립"],
            "evidence_summary": [combined[:200]] if combined else [],
            "runbook_references": []
        }
        final = json.dumps(fallback, ensure_ascii=False)

    return {**state, "final_answer": final}


# ============================================================
# 4. Graph 구성
# ============================================================
def build_graph():
    graph = StateGraph(ObservabilityState)

    graph.add_node("classify",  classify_node)
    graph.add_node("metrics",   metrics_node)
    graph.add_node("logs",      logs_node)
    graph.add_node("traces",    traces_node)
    graph.add_node("runbook",   runbook_node)
    graph.add_node("synthesize", synthesize_node)

    graph.set_entry_point("classify")
    graph.add_edge("classify", "metrics")
    graph.add_edge("classify", "logs")
    graph.add_edge("classify", "traces")
    graph.add_edge("classify", "runbook")
    graph.add_edge("metrics",  "synthesize")
    graph.add_edge("logs",     "synthesize")
    graph.add_edge("traces",   "synthesize")
    graph.add_edge("runbook",  "synthesize")
    graph.add_edge("synthesize", END)

    return graph.compile()


# ============================================================
# 5. CLI 인터페이스
# ============================================================
def main():
    print("=" * 60)
    print("🔍 AWS Observability Platform - Graph Agent")
    print("=" * 60)

    app = build_graph()

    while True:
        try:
            user_input = input("👤 질문: ").strip()
            if not user_input:
                continue
            if user_input.lower() in ("quit", "exit", "종료"):
                break

            result = app.invoke({
                "question":       user_input,
                "alert_name":     "",
                "severity":       "medium",
                "amp_link":       "",
                "category":       [],
                "metrics_result": "",
                "logs_result":    "",
                "traces_result":  "",
                "runbook_result": "",
                "final_answer":   "",
            })

            report = json.loads(result["final_answer"])
            print(f"\n🤖 요약: {report.get('incident_summary')}")
            print(f"   신뢰도: {report.get('overall_confidence')}%")
            print(f"   즉시 조치: {report.get('immediate_actions')}\n")

        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"오류: {e}\n")


if __name__ == "__main__":
    main()