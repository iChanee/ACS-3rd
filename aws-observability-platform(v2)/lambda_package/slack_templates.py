"""
Slack Block Kit 템플릿 + Pydantic 스키마 정의
attachments + blocks 조합으로 색깔 선 + Block Kit 동시 구현
"""

from __future__ import annotations
from datetime import datetime, timezone
from typing import Literal, Optional
from pydantic import BaseModel, Field


# ============================================================
# Pydantic 스키마
# ============================================================

Severity = Literal["info", "low", "medium", "high", "critical"]
Priority = Literal["low", "medium", "high"]
AnalysisType = Literal["log", "metric", "trace"]


class TimeRange(BaseModel):
    start: str = Field(description="분석 시작 시각 (ISO8601 문자열)")
    end: str   = Field(description="분석 종료 시각 (ISO8601 문자열)")


class EvidenceItem(BaseModel):
    source:    str           = Field(description="근거 출처. 예: logs, metrics, traces, opensearch, amp")
    detail:    str           = Field(description="근거 상세 설명")
    timestamp: Optional[str] = Field(default=None, description="근거 시각 (있으면 기록)")


class ActionItem(BaseModel):
    action:   str      = Field(description="권장 조치")
    priority: Priority = Field(description="조치 우선순위")


class AnalysisResult(BaseModel):
    analysis_type:        AnalysisType       = Field(description="분석 타입")
    service_name:         str                = Field(description="대상 서비스명")
    time_range:           TimeRange          = Field(description="분석 시간 범위")
    summary:              str                = Field(description="핵심 요약")
    evidence:             list[EvidenceItem] = Field(default_factory=list)
    suspected_root_cause: list[str]          = Field(default_factory=list)
    severity:             Severity           = Field(description="심각도")
    recommended_actions:  list[ActionItem]   = Field(default_factory=list)


class RunbookReference(BaseModel):
    source:    str = Field(description="런북 파일명")
    section:   str = Field(description="참조한 섹션명")
    relevance: str = Field(description="이 런북이 현재 장애와 어떻게 관련되는지 설명")


class IncidentReport(BaseModel):
    incident_summary:   str                                          = Field(description="최종 장애 요약")
    likely_root_causes: list[str]                                    = Field(default_factory=list)
    severity:           Literal["low", "medium", "high", "critical"] = Field(description="최종 심각도")
    impact:             str                                          = Field(description="장애 영향 범위")
    immediate_actions:  list[str]                                    = Field(default_factory=list)
    follow_up_actions:  list[str]                                    = Field(default_factory=list)
    evidence_summary:   list[str]                                    = Field(default_factory=list)
    runbook_references: list[RunbookReference]                       = Field(default_factory=list)


# ============================================================
# 상수
# ============================================================

SEVERITY_EMOJI = {
    "critical": "🔴",
    "high":     "🟠",
    "medium":   "🟡",
    "low":      "🟢",
    "info":     "⚪",
}

SEVERITY_COLOR = {
    "critical": "#f22613",
    "high":     "#FF6600",
    "medium":   "#FFAA00",
    "low":      "#2eb886",
    "info":     "#AAAAAA",
    "unknown":  "#AAAAAA",
}


# ============================================================
# Block Kit 빌더
# ============================================================

def build_alert_message(alert_info: str, severity: str = "critical") -> dict:
    """알람 감지 즉시 전송 - '분석 중...' 메시지"""
    emoji = SEVERITY_EMOJI.get(severity, "🚨")
    color = SEVERITY_COLOR.get(severity, "#AAAAAA")
    now   = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    return {
        "attachments": [
            {
                "color": color,
                "blocks": [
                    {
                        "type": "header",
                        "text": {"type": "plain_text", "text": f"{emoji} Alert 감지 — 분석 중...", "emoji": True}
                    },
                    {
                        "type": "section",
                        "fields": [
                            {"type": "mrkdwn", "text": f"*알람*\n{alert_info}"},
                            {"type": "mrkdwn", "text": f"*감지 시각*\n{now}"},
                        ]
                    },
                    {
                        "type": "context",
                        "elements": [{"type": "mrkdwn", "text": "⏳ Metrics · Logs · Traces · 런북 분석 중입니다..."}]
                    }
                ]
            }
        ]
    }


def build_incident_report_message(
    alert_info: str,
    report: IncidentReport,
    amp_link: str = "",
    detected_at: str = "",
) -> dict:
    """IncidentReport → Slack attachments + blocks 최종 분석 메시지"""

    severity     = report.severity
    emoji        = SEVERITY_EMOJI.get(severity, "🟡")
    color        = SEVERITY_COLOR.get(severity, "#AAAAAA")
    now          = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    detected_at  = detected_at or now

    blocks = []

    # ── 헤더 ──────────────────────────────────────────────
    blocks.append({
        "type": "header",
        "text": {"type": "plain_text", "text": f"{emoji} Observability 분석 완료", "emoji": True}
    })

    # ── 알람 기본 정보 ────────────────────────────────────
    blocks.append({
        "type": "section",
        "fields": [
            {"type": "mrkdwn", "text": f"*알람*\n{alert_info}"},
            {"type": "mrkdwn", "text": f"*심각도*\n{emoji} {severity.upper()}"},
        ]
    })
    blocks.append({
        "type": "section",
        "fields": [
            {"type": "mrkdwn", "text": f"*탐지 시각*\n{detected_at}"},
            {"type": "mrkdwn", "text": f"*분석 완료*\n{now}"},
        ]
    })
    blocks.append({"type": "divider"})

    # ── 장애 요약 ─────────────────────────────────────────
    if report.incident_summary:
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*📋 장애 요약*\n{report.incident_summary}"}
        })

    # ── 영향 범위 ─────────────────────────────────────────
    if report.impact:
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*💥 영향 범위*\n{report.impact}"}
        })

    blocks.append({"type": "divider"})

    # ── 추정 원인 ─────────────────────────────────────────
    if report.likely_root_causes:
        causes_text = "\n".join(f"• {c}" for c in report.likely_root_causes)
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*🔍 추정 원인*\n{causes_text}"}
        })

    # ── 핵심 근거 ─────────────────────────────────────────
    if report.evidence_summary:
        ev_text = "\n".join(f"• {e}" for e in report.evidence_summary[:5])
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*📊 핵심 근거*\n{ev_text}"}
        })

    blocks.append({"type": "divider"})

    # ── 즉시 조치 ─────────────────────────────────────────
    if report.immediate_actions:
        actions_text = "\n".join(f"{i+1}. {a}" for i, a in enumerate(report.immediate_actions))
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*⚡ 즉시 조치*\n{actions_text}"}
        })

    # ── 후속 조치 ─────────────────────────────────────────
    if report.follow_up_actions:
        followup_text = "\n".join(f"{i+1}. {a}" for i, a in enumerate(report.follow_up_actions))
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*📝 후속 조치*\n{followup_text}"}
        })

    blocks.append({"type": "divider"})

    # ── 참조 런북 ─────────────────────────────────────────
    if report.runbook_references:
        rb_lines = []
        for rb in report.runbook_references:
            rb_lines.append(f"• *[{rb.source}]* {rb.section}\n  _{rb.relevance}_")
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": "*📖 참조 런북*\n" + "\n".join(rb_lines)}
        })

    # ── AMP 링크 버튼 ─────────────────────────────────────
    # Grafana 연동 시 활성화
    # if amp_link:
    #     blocks.append({
    #         "type": "actions",
    #         "elements": [{
    #             "type": "button",
    #             "text": {"type": "plain_text", "text": "📈 그래프 보기", "emoji": True},
    #             "url": amp_link,
    #             "style": "primary"
    #         }]
    #     })

    # ── 하단 컨텍스트 ─────────────────────────────────────
    blocks.append({
        "type": "context",
        "elements": [{"type": "mrkdwn", "text": f"Scenario: `{alert_info.split(' ')[0]}` | 분석 완료"}]
    })

    return {
        "attachments": [
            {
                "color": color,
                "blocks": blocks
            }
        ]
    }


def build_error_message(alert_info: str, error: str) -> dict:
    """분석 실패 시 에러 메시지"""
    return {
        "attachments": [
            {
                "color": "#AAAAAA",
                "blocks": [
                    {
                        "type": "header",
                        "text": {"type": "plain_text", "text": "⚠️ 분석 실패", "emoji": True}
                    },
                    {
                        "type": "section",
                        "text": {
                            "type": "mrkdwn",
                            "text": f"*알람:* {alert_info}\n*오류:* ```{error}```"
                        }
                    }
                ]
            }
        ]
    }