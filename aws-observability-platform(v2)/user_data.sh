#!/bin/bash
set -e

apt-get update -y
apt-get install -y wget curl jq docker.io apt-transport-https software-properties-common

systemctl enable docker
systemctl start docker

wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.119.0/otelcol-contrib_0.119.0_linux_amd64.tar.gz -O otelcol-contrib_linux_amd64.tar.gz
mkdir -p /opt/otelcol
tar -xzf otelcol-contrib_linux_amd64.tar.gz -C /opt/otelcol
ln -sf /opt/otelcol/otelcol-contrib /usr/local/bin/otelcol

useradd --system --no-create-home --shell /usr/sbin/nologin otelcol || true
mkdir -p /etc/otelcol
chown otelcol:otelcol /etc/otelcol

cat > /etc/otelcol/config.yaml <<EOF
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:14317
      http:
        endpoint: 0.0.0.0:14318

processors:
  batch:
    timeout: 5s
    send_batch_size: 512
  memory_limiter:
    check_interval: 5s
    limit_mib: 700
    spike_limit_mib: 100

exporters:
  prometheusremotewrite:
    endpoint: ${amp_remote_write_url}api/v1/remote_write
    auth:
      authenticator: sigv4auth/aps
  otlphttp/logs:
    endpoint: https://${osis_logs_endpoint}
    compression: none
    auth:
      authenticator: sigv4auth
  otlphttp/traces:
    endpoint: https://${osis_traces_endpoint}
    compression: none
    auth:
      authenticator: sigv4auth
  awss3/logs:
    s3uploader:
      region: ${aws_region}
      s3_bucket: ${s3_logs_bucket}
      s3_prefix: logs
  awss3/traces:
    s3uploader:
      region: ${aws_region}
      s3_bucket: ${s3_traces_bucket}
      s3_prefix: traces
  awss3/metrics:
    s3uploader:
      region: ${aws_region}
      s3_bucket: ${s3_metrics_bucket}
      s3_prefix: metrics
  debug:
    verbosity: normal

extensions:
  sigv4auth:
    region: ${aws_region}
    service: osis
  sigv4auth/aps:
    region: ${aws_region}
    service: aps

service:
  extensions: [sigv4auth, sigv4auth/aps]
  pipelines:
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/logs, awss3/logs, debug]
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/traces, awss3/traces, debug]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite, awss3/metrics, debug]
EOF

chown otelcol:otelcol /etc/otelcol/config.yaml
chmod 640 /etc/otelcol/config.yaml

cat > /etc/systemd/system/otelcol.service <<EOF
[Unit]
Description=OpenTelemetry Collector
After=network.target

[Service]
Type=simple
User=otelcol
Group=otelcol
ExecStart=/usr/local/bin/otelcol --config=/etc/otelcol/config.yaml
Restart=on-failure
RestartSec=5s
MemoryLimit=800M
CPUQuota=80%

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable otelcol
systemctl start otelcol
sleep 5

# Envoy 설치 (JWT 인증 게이트웨이)
docker pull envoyproxy/envoy:v1.29-latest
mkdir -p /etc/envoy

# Self-signed TLS 인증서 생성
mkdir -p /etc/envoy/certs
openssl req -x509 -newkey rsa:4096 -keyout /etc/envoy/certs/key.pem \
  -out /etc/envoy/certs/cert.pem -days 3650 -nodes \
  -subj "/CN=otel-collector"
chmod 644 /etc/envoy/certs/key.pem
chmod 644 /etc/envoy/certs/cert.pem

COGNITO_ISSUER="https://cognito-idp.${aws_region}.amazonaws.com/${cognito_user_pool_id}"
COGNITO_JWKS_URI="https://cognito-idp.${aws_region}.amazonaws.com/${cognito_user_pool_id}/.well-known/jwks.json"
COGNITO_SNI="cognito-idp.${aws_region}.amazonaws.com"

cat > /etc/envoy/envoy.yaml <<ENVOY_EOF
static_resources:
  listeners:
    - name: listener_grpc
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 4317
      filter_chains:
        - transport_socket:
            name: envoy.transport_sockets.tls
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
              common_tls_context:
                tls_certificates:
                  - certificate_chain:
                      filename: /etc/envoy/certs/cert.pem
                    private_key:
                      filename: /etc/envoy/certs/key.pem
          filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: ingress_grpc
                codec_type: HTTP2
                http_filters:
                  - name: envoy.filters.http.jwt_authn
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication
                      providers:
                        cognito:
                          issuer: $COGNITO_ISSUER
                          forward: true
                          remote_jwks:
                            http_uri:
                              uri: $COGNITO_JWKS_URI
                              cluster: cognito_jwks
                              timeout: 5s
                            cache_duration: 300s
                          claim_to_headers:
                            - header_name: x-tenant-id
                              claim_name: client_id
                      rules:
                        - match:
                            prefix: /
                          requires:
                            provider_name: cognito
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
                route_config:
                  name: local_route_grpc
                  virtual_hosts:
                    - name: otelcol_grpc
                      domains: ["*"]
                      routes:
                        - match:
                            prefix: /
                          route:
                            cluster: otelcol_grpc

  clusters:
    - name: otelcol_grpc
      connect_timeout: 5s
      type: STATIC
      http2_protocol_options: {}
      load_assignment:
        cluster_name: otelcol_grpc
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: 127.0.0.1
                      port_value: 14317

    - name: cognito_jwks
      connect_timeout: 5s
      type: LOGICAL_DNS
      dns_lookup_family: V4_ONLY
      transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
          sni: $COGNITO_SNI
      load_assignment:
        cluster_name: cognito_jwks
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: $COGNITO_SNI
                      port_value: 443

admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901
ENVOY_EOF

docker run -d \
  --name envoy \
  --restart unless-stopped \
  --network host \
  --user root \
  -v /etc/envoy/envoy.yaml:/etc/envoy/envoy.yaml:ro \
  -v /etc/envoy/certs:/etc/envoy/certs:ro \
  envoyproxy/envoy:v1.29-latest \
  -c /etc/envoy/envoy.yaml

sleep 5

# SigV4 Proxy (Grafana → AMP 연동용)
docker run -d \
  --name sigv4-proxy \
  --restart unless-stopped \
  --network host \
  public.ecr.aws/aws-observability/aws-sigv4-proxy:latest \
  --name aps \
  --region ${aws_region} \
  --host aps-workspaces.${aws_region}.amazonaws.com \
  --port :8005

# Grafana 설치
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | tee /etc/apt/sources.list.d/grafana.list
apt-get update -y
apt-get install -y grafana
systemctl enable grafana-server
systemctl start grafana-server

echo "====================================="
echo "설치 완료!"
echo "Envoy  : 4317(gRPC) / 4318(HTTP) - JWT 인증"
echo "OTelCol: 14317(gRPC) / 14318(HTTP) - 내부 전용"
echo "Grafana: 3000"
echo "====================================="