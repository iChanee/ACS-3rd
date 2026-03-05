"""
AWS 런북 관리 - S3 + OpenSearch Serverless (벡터 검색)

흐름:
    S3에 마크다운 업로드
        ↓ (인덱싱 Lambda 또는 수동 실행)
    OpenSearch Serverless에 벡터로 저장
        ↓
    Agent가 문제 감지 시 유사 런북 검색

의존성:
    pip install opensearch-py requests-aws4auth
"""

import os
import json
import boto3

from opensearchpy import OpenSearch, RequestsHttpConnection, AWSV4SignerAuth

AWS_REGION      = os.environ.get("AWS_REGION_NAME", "ap-northeast-2")
RUNBOOKS_BUCKET = os.environ.get("RUNBOOKS_BUCKET", "")
AOSS_ENDPOINT   = os.environ.get("AOSS_ENDPOINT", "")  # https:// 포함
AOSS_INDEX      = "runbooks"


# ============================================================
# OpenSearch Serverless 클라이언트 (SigV4)
# ============================================================
def get_os_client() -> OpenSearch:
    """AOSS SigV4 인증 클라이언트 생성"""
    credentials = boto3.Session().get_credentials()
    auth = AWSV4SignerAuth(credentials, AWS_REGION, "aoss")

    # AOSS_ENDPOINT에서 https:// 제거 (host만 추출)
    host = AOSS_ENDPOINT.replace("https://", "").replace("http://", "").rstrip("/")

    client = OpenSearch(
        hosts=[{"host": host, "port": 443}],
        http_auth=auth,
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection,
        timeout=30,
    )
    return client


# ============================================================
# 텍스트 임베딩 (Bedrock Titan v2)
# ============================================================
def get_embedding(text: str) -> list:
    """Bedrock Titan Embed v2로 텍스트 임베딩 생성 (1024차원)"""
    client = boto3.client("bedrock-runtime", region_name=AWS_REGION)
    response = client.invoke_model(
        modelId="amazon.titan-embed-text-v2:0",
        body=json.dumps({"inputText": text})
    )
    result = json.loads(response["body"].read())
    return result["embedding"]


# ============================================================
# S3에서 런북 마크다운 로드
# ============================================================
def load_runbooks_from_s3() -> list:
    """S3 런북 버킷에서 마크다운 파일 전체 로드"""
    s3 = boto3.client("s3", region_name=AWS_REGION)
    runbooks = []

    try:
        response = s3.list_objects_v2(Bucket=RUNBOOKS_BUCKET, Prefix="runbooks/")
        for obj in response.get("Contents", []):
            key = obj["Key"]
            if not key.endswith(".md"):
                continue

            file_response = s3.get_object(Bucket=RUNBOOKS_BUCKET, Key=key)
            content = file_response["Body"].read().decode("utf-8")

            runbook_id = key.replace("runbooks/", "").replace(".md", "")
            title = ""
            severity = "medium"
            action_lines = []
            in_action = False

            for line in content.split("\n"):
                if line.startswith("# "):
                    title = line[2:].strip()
                elif line.strip() in ("critical", "high", "medium"):
                    severity = line.strip()
                elif line.startswith("## 대응 절차"):
                    in_action = True
                elif line.startswith("## ") and in_action:
                    in_action = False
                elif in_action and line.strip():
                    action_lines.append(line.strip())

            runbooks.append({
                "id":       runbook_id,
                "title":    title,
                "content":  content,
                "severity": severity,
                "action":   "\n".join(action_lines),
            })

        print(f"S3에서 런북 {len(runbooks)}개 로드 완료")
        return runbooks

    except Exception as e:
        print(f"S3 런북 로드 오류: {e}")
        return []


# ============================================================
# OpenSearch Serverless 인덱스 생성
# ============================================================
def create_index(client: OpenSearch):
    """벡터 검색용 인덱스 생성 (이미 있으면 스킵)"""
    if client.indices.exists(index=AOSS_INDEX):
        print(f"인덱스 '{AOSS_INDEX}' 이미 존재, 스킵")
        return

    body = {
        "settings": {
            "index": {"knn": True}
        },
        "mappings": {
            "properties": {
                "title":    {"type": "text"},
                "content":  {"type": "text"},
                "severity": {"type": "keyword"},
                "action":   {"type": "text"},
                "embedding": {
                    "type": "knn_vector",
                    "dimension": 1024,  # Titan Embed v2 차원
                    "method": {
                        "name": "hnsw",
                        "space_type": "cosinesimil",
                        "engine": "nmslib"
                    }
                }
            }
        }
    }
    result = client.indices.create(index=AOSS_INDEX, body=body)
    print(f"인덱스 생성: {result}")


# ============================================================
# 런북 인덱싱 (S3 → OpenSearch Serverless)
# ============================================================
def index_runbooks():
    """S3 런북을 벡터로 변환해서 OpenSearch Serverless에 저장"""
    runbooks = load_runbooks_from_s3()
    if not runbooks:
        print("런북 없음")
        return

    client = get_os_client()
    create_index(client)

    for rb in runbooks:
        search_text = f"{rb['title']}\n{rb['content'][:500]}"
        embedding = get_embedding(search_text)

        doc = {
            "title":     rb["title"],
            "content":   rb["content"],
            "severity":  rb["severity"],
            "action":    rb["action"],
            "embedding": embedding
        }

        result = client.index(index=AOSS_INDEX, id=rb["id"], body=doc)
        print(f"  인덱싱: {rb['title']} → {result.get('result', 'error')}")

    print(f"✅ 런북 {len(runbooks)}개 인덱싱 완료")


# ============================================================
# 런북 검색 (벡터 유사도)
# ============================================================
def search_runbook(query: str, n_results: int = 2) -> list:
    """증상으로 관련 런북 벡터 검색"""
    try:
        client = get_os_client()
        query_embedding = get_embedding(query)

        body = {
            "size": n_results,
            "query": {
                "knn": {
                    "embedding": {
                        "vector": query_embedding,
                        "k": n_results
                    }
                }
            },
            "_source": ["title", "severity", "action"]
        }

        result = client.search(index=AOSS_INDEX, body=body)
        hits = result.get("hits", {}).get("hits", [])

        runbooks = []
        for h in hits:
            src = h.get("_source", {})
            score = h.get("_score", 0)
            runbooks.append({
                "title":     src.get("title", ""),
                "severity":  src.get("severity", "medium"),
                "action":    src.get("action", ""),
                "relevance": score
            })

        return runbooks

    except Exception as e:
        print(f"런북 검색 오류: {e}")
        return []


# ============================================================
# S3에 런북 업로드 (로컬 → S3)
# ============================================================
def upload_runbooks_to_s3(local_dir: str = "./runbooks"):
    """로컬 런북 마크다운 파일들을 S3에 업로드"""
    s3 = boto3.client("s3", region_name=AWS_REGION)

    for filename in os.listdir(local_dir):
        if not filename.endswith(".md"):
            continue

        filepath = os.path.join(local_dir, filename)
        s3_key = f"runbooks/{filename}"

        with open(filepath, "rb") as f:
            s3.put_object(
                Bucket=RUNBOOKS_BUCKET,
                Key=s3_key,
                Body=f.read(),
                ContentType="text/markdown"
            )
        print(f"  업로드: {filename} → s3://{RUNBOOKS_BUCKET}/{s3_key}")

    print("✅ 런북 업로드 완료")


# ============================================================
# Lambda 핸들러 (S3 업로드 트리거)
# S3에 런북 파일 올라오면 자동 인덱싱
# ============================================================
def indexing_handler(event, context):
    """S3 업로드 이벤트 → 자동 인덱싱"""
    print(f"S3 이벤트: {json.dumps(event)}")
    index_runbooks()
    return {"statusCode": 200, "body": "인덱싱 완료"}


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "upload":
        upload_runbooks_to_s3()
    elif len(sys.argv) > 1 and sys.argv[1] == "index":
        index_runbooks()
    else:
        print("사용법:")
        print("  python runbooks_aws.py upload  # 로컬 런북 → S3 업로드")
        print("  python runbooks_aws.py index   # S3 런북 → OpenSearch 인덱싱")
