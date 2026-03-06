"""
AWS Observability Agent - Lambda Handler
AMP Alertmanager → SNS → Lambda → graph_agent → Slack (Block Kit + chat.update)
"""

import json
import os
import urllib.request
import sys
import re

import agents_aws as agents_module
sys.modules['agents'] = agents_module

from graph_agent import build_graph
from slack_templates import (
    IncidentReport,
    build_alert_message,
    build_incident_report_message,
    build_error_message,
)

SLACK_BOT_TOKEN = os.environ.get("SLACK_BOT_TOKEN", "")
SLACK_CHANNEL   = os.environ.get("SLACK_CHANNEL", "")


def slack_post(payload: dict) -> str:
    """chat.postMessage → ts 반환"""
    payload["channel"] = SLACK_CHANNEL
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {SLACK_BOT_TOKEN}",
        },
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read())
        ts = result.get("ts", "")
        print(f"Slack postMessage: ok={result.get('ok')}, ts={ts}")
        if not result.get("ok"):
            print(f"Slack 오류: {result.get('error')}")
        return ts


def slack_delete(ts: str):
    """기존 메시지 삭제 (chat.update의 color 버그 우회)"""
    data = json.dumps({"channel": SLACK_CHANNEL, "ts": ts}).encode("utf-8")
    req = urllib.request.Request(
        "https://slack.com/api/chat.delete",
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {SLACK_BOT_TOKEN}",
        },
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read())
        print(f"Slack delete: ok={result.get('ok')}")
        if not result.get("ok"):
            print(f"Slack 삭제 오류: {result.get('error')}")


def parse_alert(event: dict) -> dict:
    try:
        sns_record = event["Records"][0]["Sns"]
        message = sns_record.get("Message", "")
        subject = sns_record.get("Subject", "")

        try:
            alert_data = json.loads(message)
            alerts = alert_data.get("alerts", [{}])
            alert = alerts[0]
            return {
                "name":        alert.get("labels", {}).get("alertname", "Unknown"),
                "severity":    alert.get("labels", {}).get("severity", "unknown"),
                "service":     alert.get("labels", {}).get("service_name", ""),
                "summary":     alert.get("annotations", {}).get("summary", ""),
                "description": alert.get("annotations", {}).get("description", ""),
                "amp_link":    alert.get("generatorURL", ""),
            }
        except json.JSONDecodeError:
            pass

        # 텍스트 파싱
        name, severity, service, summary, amp_link = "Unknown", "unknown", "", "", ""

        if m := re.search(r"alertname\s*=\s*(\w+)", message):
            name = m.group(1)
        if m := re.search(r"severity\s*=\s*(\w+)", message):
            severity = m.group(1)
        if m := re.search(r"service_name\s*=\s*(\S+)", message):
            service = m.group(1)
        if m := re.search(r"summary\s*=\s*(.+)", message):
            summary = m.group(1).strip()
        if m := re.search(r"Source:\s*(\S+)", message):
            raw_link = m.group(1)
            if raw_link.startswith("http"):
                amp_link = raw_link
            else:
                # 상대경로 → AMP 콘솔 URL로 조합
                # AMP_ENDPOINT: https://aps-workspaces.ap-northeast-2.amazonaws.com/workspaces/ws-xxx/
                amp_endpoint = os.environ.get("AMP_ENDPOINT", "").rstrip("/")
                # ws-xxx 추출
                ws_match = re.search(r"workspaces/(ws-[^/]+)", amp_endpoint)
                if ws_match:
                    ws_id = ws_match.group(1)
                    region = os.environ.get("AWS_REGION_NAME", "ap-northeast-2")
                    query = raw_link.split("?", 1)[1] if "?" in raw_link else ""
                    amp_link = f"https://{region}.console.aws.amazon.com/prometheus/home#/workspaces/{ws_id}/alerting"
                else:
                    amp_link = ""
        if name == "Unknown" and subject:
            if m := re.search(r"\] (\w+) \(", subject):
                name = m.group(1)

        return {
            "name": name, "severity": severity, "service": service,
            "summary": summary or message[:100], "description": "", "amp_link": amp_link,
        }

    except Exception as e:
        print(f"SNS 파싱 오류: {e}")
        return {"name": "Unknown", "severity": "unknown", "service": "",
                "summary": "알람 파싱 실패", "description": str(e), "amp_link": ""}


def handler(event, context):
    print(f"이벤트 수신: {json.dumps(event)}")

    alert = parse_alert(event)
    alert_info = f"{alert['name']} (severity: {alert['severity']})"
    if alert['summary']:
        alert_info += f" - {alert['summary']}"
    if alert['service']:
        alert_info += f" / 서비스: {alert['service']}"

    print(f"알람: {alert_info}")

    # 1) 즉시 "분석 중..." 전송 → ts 저장, 탐지 시각 기록
    from datetime import datetime, timezone
    detected_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    ts = slack_post(build_alert_message(alert_info, alert['severity']))

    # 2) 분석 실행
    try:
        app = build_graph()
        question = f"{alert_info} 이 알람이 발생했어. 시스템 전체 상태를 분석해줘."
        if alert['service']:
            question = f"{alert['service']} 서비스에서 {alert_info} 발생. 원인과 현재 상태를 분석해줘."

        result = app.invoke({
            "question":       question,
            "alert_name":     alert['name'],
            "severity":       alert['severity'],
            "amp_link":       alert['amp_link'],
            "category":       [],
            "metrics_result": "",
            "logs_result":    "",
            "traces_result":  "",
            "runbook_result": "",
            "final_answer":   "",
        })

        # JSON → Pydantic IncidentReport 파싱
        raw_json = result.get("final_answer", "{}")
        print(f"분석 결과: {raw_json}")
        report = IncidentReport.model_validate_json(raw_json)

        final_payload = build_incident_report_message(
            alert_info=alert_info,
            report=report,
            amp_link=alert['amp_link'],
            detected_at=detected_at,
        )

    except Exception as e:
        print(f"분석 오류: {e}")
        final_payload = build_error_message(alert_info, str(e))

    # 3) 기존 "분석 중..." 메시지 삭제 후 최종 결과 새로 전송
    #    (chat.update는 attachments color를 무시하는 버그가 있어 삭제 후 재전송)
    if ts:
        slack_delete(ts)
    slack_post(final_payload)

    return {"statusCode": 200, "body": json.dumps({"alert": alert_info}, ensure_ascii=False)}