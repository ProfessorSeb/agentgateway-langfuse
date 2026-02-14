#!/usr/bin/env bash
# verify.sh — Verify AgentGateway → Langfuse trace pipeline
#
# Usage:
#   ./scripts/verify.sh <LANGFUSE_HOST> <LANGFUSE_AUTH_BASE64> [GATEWAY_ENDPOINT]
#
# Example:
#   ./scripts/verify.sh http://localhost:3000 "cGstbGY...base64..." http://localhost:8080
#
# Environment variables (alternative to args):
#   LANGFUSE_HOST       — Langfuse base URL (e.g., http://localhost:3000)
#   LANGFUSE_AUTH       — Base64 encoded public_key:secret_key
#   GATEWAY_ENDPOINT    — AgentGateway LLM endpoint (e.g., http://localhost:8080)
#   KUBECTL_CONTEXT     — kubectl context to use (optional)

set -euo pipefail

LANGFUSE_HOST="${1:-${LANGFUSE_HOST:-http://localhost:3000}}"
LANGFUSE_AUTH="${2:-${LANGFUSE_AUTH:-}}"
GATEWAY_ENDPOINT="${3:-${GATEWAY_ENDPOINT:-http://localhost:8080}}"
KUBECTL_CTX="${KUBECTL_CONTEXT:-}"

if [[ -z "$LANGFUSE_AUTH" ]]; then
  echo "❌ Error: Langfuse auth not provided."
  echo "Usage: $0 <LANGFUSE_HOST> <LANGFUSE_AUTH_BASE64> [GATEWAY_ENDPOINT]"
  echo "   or: LANGFUSE_AUTH=<base64> $0"
  exit 1
fi

kubectl_cmd() {
  if [[ -n "$KUBECTL_CTX" ]]; then
    kubectl --context "$KUBECTL_CTX" "$@"
  else
    kubectl "$@"
  fi
}

echo "============================================"
echo "  AgentGateway → Langfuse Verification"
echo "============================================"
echo ""
echo "  Langfuse:  $LANGFUSE_HOST"
echo "  Gateway:   $GATEWAY_ENDPOINT"
echo ""

# Step 1: Check collector pod
echo "1️⃣  Checking Langfuse OTel Collector..."
COLLECTOR_STATUS=$(kubectl_cmd get pods -n agentgateway-system -l app=langfuse-otel-collector \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$COLLECTOR_STATUS" == "Running" ]]; then
  echo "   ✅ langfuse-otel-collector is Running"
else
  echo "   ❌ langfuse-otel-collector status: $COLLECTOR_STATUS"
  exit 1
fi

# Step 2: Check tracing endpoint
echo ""
echo "2️⃣  Checking AgentGateway tracing endpoint..."
TRACING_ENDPOINT=$(kubectl_cmd get enterpriseagentgatewayparameters tracing -n agentgateway-system \
  -o jsonpath='{.spec.rawConfig.config.tracing.otlpEndpoint}' 2>/dev/null || echo "N/A (OSS or not configured)")
echo "   Endpoint: $TRACING_ENDPOINT"
if echo "$TRACING_ENDPOINT" | grep -q "langfuse-otel-collector"; then
  echo "   ✅ Pointing to Langfuse collector"
else
  echo "   ⚠️  May not be pointing to Langfuse collector"
fi

# Step 3: Check logs
echo ""
echo "3️⃣  Checking collector logs..."
ERRORS=$(kubectl_cmd logs -n agentgateway-system -l app=langfuse-otel-collector \
  --tail 50 2>/dev/null | grep -ci 'error\|fail' || true)
if [[ "$ERRORS" -eq 0 ]]; then
  echo "   ✅ No errors in collector logs"
else
  echo "   ⚠️  Found $ERRORS error(s) — check: kubectl logs -n agentgateway-system -l app=langfuse-otel-collector"
fi

# Step 4: Send test request
echo ""
echo "4️⃣  Sending test LLM request..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${GATEWAY_ENDPOINT}/openai/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4.1-mini","messages":[{"role":"user","content":"Verification test — respond with OK"}]}' 2>/dev/null || echo -e "\n000")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
if [[ "$HTTP_CODE" == "200" ]]; then
  echo "   ✅ LLM response received (HTTP 200)"
else
  echo "   ❌ LLM request failed (HTTP $HTTP_CODE)"
  echo "   Check your GATEWAY_ENDPOINT: $GATEWAY_ENDPOINT"
  exit 1
fi

# Step 5: Check Langfuse
echo ""
echo "5️⃣  Waiting 15 seconds for trace propagation..."
sleep 15

TRACES=$(curl -s "${LANGFUSE_HOST}/api/public/traces?limit=3" \
  -H "Authorization: Basic ${LANGFUSE_AUTH}" 2>/dev/null)

TRACE_COUNT=$(echo "$TRACES" | python3 -c "import sys,json; print(json.load(sys.stdin)['meta']['totalItems'])" 2>/dev/null || echo "0")

if [[ "$TRACE_COUNT" -gt 0 ]]; then
  echo "   ✅ Found $TRACE_COUNT trace(s) in Langfuse!"
  echo ""
  echo "   Latest trace:"
  echo "$TRACES" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data'][0]
print(f\"   Name:      {data.get('name', 'N/A')}\")
print(f\"   Timestamp: {data.get('timestamp', 'N/A')}\")
" 2>/dev/null || true
else
  echo "   ❌ No traces found in Langfuse"
  echo "   Check collector logs and Langfuse credentials"
fi

echo ""
echo "============================================"
echo "  Verification Complete"
echo "============================================"
echo ""
echo "  View traces: ${LANGFUSE_HOST}"
echo ""
