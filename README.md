# Open Source LLM Observability for Solo AgentGateway with Langfuse

## Trace AI API calls through Solo AgentGateway with Langfuse

This guide demonstrates how to integrate [Langfuse](https://langfuse.com) with [Solo AgentGateway](https://docs.solo.io/agentgateway/) to automatically capture, monitor, and debug all LLM API calls flowing through your AI gateway — without modifying your application code.

**What is Solo AgentGateway?** [AgentGateway](https://agentgateway.dev) is an open-source, Kubernetes-native AI gateway that routes LLM traffic, MCP tool calls, and A2A (Agent-to-Agent) communication. It provides security policies (PII protection, prompt injection prevention, credential leak detection), rate limiting, and model failover — all managed via the Kubernetes Gateway API.

**What is Langfuse?** [Langfuse](https://langfuse.com) is an open-source LLM observability platform that helps you trace, monitor, and debug your LLM applications. It captures prompts, completions, token usage, latency, and cost across all your AI interactions.

### Why integrate them?

AgentGateway already captures rich telemetry about every LLM request (model, tokens, latency, route, security policy actions). By forwarding these traces to Langfuse, you get:

- **Full prompt and completion visibility** across all LLM providers (OpenAI, Anthropic, xAI, etc.)
- **Token usage and cost tracking** per model, route, and user
- **Latency analysis** with gateway-level metadata (which route, which backend, which policy fired)
- **Zero application changes** — tracing happens at the gateway layer

## Architecture

```
┌──────────────┐     ┌────────────────────────┐     ┌─────────────────┐
│ Your App /   │     │   Solo AgentGateway     │     │   LLM Provider  │
│ AI Agent     │────▶│   (Gateway API)         │────▶│   (OpenAI, etc) │
│              │     │                         │     │                 │
└──────────────┘     └───────────┬────────────┘     └─────────────────┘
                                 │
                          OTLP Traces (gRPC)
                                 │
                     ┌───────────▼────────────┐
                     │  OpenTelemetry          │
                     │  Collector (fan-out)    │
                     │                         │
                     └─────┬───────────┬──────┘
                           │           │
                    OTLP HTTP      OTLP gRPC
                           │           │
                     ┌─────▼──┐  ┌─────▼──────────┐
                     │Langfuse│  │ClickHouse /     │
                     │  UI    │  │ Solo Enterprise  │
                     │        │  │ UI (optional)    │
                     └────────┘  └─────────────────┘
```

AgentGateway natively emits OpenTelemetry traces for every LLM request. A lightweight OTel Collector receives these traces and forwards them to Langfuse via OTLP HTTP. Optionally, the same collector can fan-out traces to additional backends (ClickHouse, Jaeger, Datadog, etc.).

## Features

- **Zero-code instrumentation**: Automatic tracing for all LLM calls proxied through AgentGateway
- **Multi-provider support**: OpenAI, Anthropic, xAI/Grok, Azure OpenAI, Google Gemini, Ollama, and any OpenAI-compatible API
- **MCP tool tracing**: Trace MCP (Model Context Protocol) tool discovery and execution
- **Rich gateway metadata**: Route name, backend endpoint, gateway listener, security policy actions
- **Gen AI semantic conventions**: Full [OpenTelemetry GenAI attributes](https://opentelemetry.io/docs/specs/semconv/gen-ai/) (model, tokens, prompt/completion content)
- **Kubernetes-native**: Everything runs as standard K8s resources managed via Gateway API
- **Fan-out capable**: Send traces to Langfuse + any other OTLP-compatible backend simultaneously

## Quick Start (Kind Cluster)

**New to AgentGateway?** Follow the [Kind Quickstart Guide](docs/quickstart-kind.md) to get AgentGateway 2.1 OSS + Langfuse running on a local kind cluster in under 10 minutes.

## Prerequisites

- Kubernetes cluster with AgentGateway deployed ([quickstart](https://docs.solo.io/agentgateway/latest/quickstart/) or [kind quickstart](docs/quickstart-kind.md))
- Langfuse account ([cloud](https://cloud.langfuse.com) or [self-hosted](https://langfuse.com/self-hosting))
- `kubectl` access to the cluster
- At least one LLM gateway route configured (e.g., OpenAI)

## Setup Guide

### Step 1: Get Langfuse API Keys

1. Log in to your Langfuse instance
2. Go to **Settings → API Keys**
3. Create a new API key pair (or use existing)
4. Note your **Public Key** and **Secret Key**

Base64 encode them for the collector config:

```bash
echo -n "pk-lf-YOUR_PUBLIC_KEY:sk-lf-YOUR_SECRET_KEY" | base64
```

### Step 2: Deploy the OTel Collector

The collector acts as a bridge between AgentGateway (which emits OTLP gRPC) and Langfuse (which accepts OTLP HTTP).

Create the collector manifest:

```yaml
# langfuse-collector.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: langfuse-otel-collector-config
  namespace: agentgateway-system
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    exporters:
      otlphttp/langfuse:
        endpoint: http://<YOUR_LANGFUSE_HOST>/api/public/otel
        headers:
          Authorization: "Basic <YOUR_BASE64_CREDENTIALS>"
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s
    processors:
      batch:
        send_batch_size: 1000
        timeout: 5s
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [otlphttp/langfuse]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: langfuse-otel-collector
  namespace: agentgateway-system
  labels:
    app: langfuse-otel-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: langfuse-otel-collector
  template:
    metadata:
      labels:
        app: langfuse-otel-collector
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.132.1
          args: ["--config=/conf/config.yaml"]
          ports:
            - containerPort: 4317
              name: otlp-grpc
            - containerPort: 4318
              name: otlp-http
          volumeMounts:
            - name: config
              mountPath: /conf
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
      volumes:
        - name: config
          configMap:
            name: langfuse-otel-collector-config
---
apiVersion: v1
kind: Service
metadata:
  name: langfuse-otel-collector
  namespace: agentgateway-system
spec:
  selector:
    app: langfuse-otel-collector
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
```

Deploy it:

```bash
kubectl apply -f langfuse-collector.yaml
```

### Step 3: Configure AgentGateway Tracing

Point AgentGateway's tracing to the collector. For **AgentGateway Enterprise**, create an `EnterpriseAgentgatewayParameters` resource:

```yaml
# tracing-params.yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: tracing
  namespace: agentgateway-system
spec:
  rawConfig:
    config:
      tracing:
        otlpEndpoint: grpc://langfuse-otel-collector.agentgateway-system.svc.cluster.local:4317
        otlpProtocol: grpc
        randomSampling: true
        fields:
          add:
            gen_ai.operation.name: '"chat"'
            gen_ai.system: "llm.provider"
            gen_ai.request.model: "llm.requestModel"
            gen_ai.response.model: "llm.responseModel"
            gen_ai.usage.prompt_tokens: "llm.inputTokens"
            gen_ai.usage.completion_tokens: "llm.outputTokens"
            gen_ai.usage.total_tokens: "llm.totalTokens"
            gen_ai.request.temperature: "llm.params.temperature"
            gen_ai.prompt: "llm.prompt"
            gen_ai.completion: "llm.completion"
```

For **AgentGateway OSS**, set the tracing endpoint via environment variables on the proxy:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://langfuse-otel-collector.agentgateway-system.svc.cluster.local:4317"
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "grpc"
```

Apply the config:

```bash
kubectl apply -f tracing-params.yaml
```

### Step 4: Restart AgentGateway Proxies

The proxies need to pick up the new tracing endpoint:

```bash
kubectl rollout restart deployment -n agentgateway-system \
  -l gateway.networking.k8s.io/gateway-name
```

### Step 5: Send a Test Request

Send an LLM request through AgentGateway:

```bash
curl -X POST http://<GATEWAY_ENDPOINT>/openai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4.1-mini",
    "messages": [{"role": "user", "content": "Hello from AgentGateway!"}]
  }'
```

### Step 6: View Traces in Langfuse

Open your Langfuse UI and navigate to **Traces**. You should see a new trace with:

- **Name**: `POST /openai/*`
- **Input**: The user prompt
- **Output**: The model response
- **Metadata**: Gateway name, route, backend endpoint, listener

![Example trace in Langfuse](docs/images/langfuse-trace-example.png)

## Captured Data

### Trace Attributes

| Attribute | Description | Example |
|-----------|-------------|---------|
| `gen_ai.system` | LLM provider | `openai` |
| `gen_ai.request.model` | Requested model | `gpt-4.1-mini` |
| `gen_ai.response.model` | Actual model used | `gpt-4o-mini-2024-07-18` |
| `gen_ai.usage.prompt_tokens` | Input token count | `13` |
| `gen_ai.usage.completion_tokens` | Output token count | `30` |
| `gen_ai.usage.total_tokens` | Combined usage | `43` |
| `gen_ai.prompt` | Full prompt content | `[{"role":"user","content":"Hello"}]` |
| `gen_ai.completion` | Full completion content | `Hello! How can I help you?` |
| `gen_ai.request.temperature` | Temperature setting | `0.7` |
| `gen_ai.streaming` | Whether streaming was used | `false` |

### Gateway Metadata

| Attribute | Description | Example |
|-----------|-------------|---------|
| `gateway` | AgentGateway resource name | `agentgateway-system/agentgateway-proxy` |
| `route` | HTTPRoute name | `agentgateway-system/openai` |
| `endpoint` | Backend LLM endpoint | `api.openai.com:443` |
| `listener` | Gateway listener | `llm-providers` |

### Performance Metrics

- **Total Duration**: End-to-end request processing time through the gateway
- **Token Throughput**: Tokens per second based on response timing
- **Time to First Token**: For streaming responses (when applicable)

## Advanced Configuration

### Fan-Out to Multiple Backends

Send traces to both Langfuse and another backend (e.g., Jaeger, Datadog, or ClickHouse):

```yaml
exporters:
  otlphttp/langfuse:
    endpoint: http://<LANGFUSE_HOST>/api/public/otel
    headers:
      Authorization: "Basic <CREDENTIALS>"
  otlp/jaeger:
    endpoint: jaeger-collector:4317
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp/langfuse, otlp/jaeger]
```

### Filter Traces

Use the OTel Collector's [filter processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/filterprocessor/README.md) to selectively send traces to Langfuse:

```yaml
processors:
  filter/genai:
    traces:
      span:
        # Only forward spans from AgentGateway
        - 'not(IsMatch(instrumentation_scope.name, "^agentgateway$"))'
```

### MCP Tool Tracing

AgentGateway also traces MCP (Model Context Protocol) tool calls. When an agent discovers or invokes tools through an MCP server proxied by AgentGateway, you'll see:

- Tool discovery requests (`/mcp/tools/list`)
- Tool execution calls with parameters and results
- Backend MCP server latency

These appear as separate spans within the same trace in Langfuse.

### Security Policy Visibility

When AgentGateway's security policies fire (PII protection, prompt injection detection, credential leak prevention), the trace metadata includes:

- Which policy was triggered
- The action taken (block, mask, allow)
- The matched pattern

This gives you observability into both your LLM interactions and your security guardrails.

## Kubernetes Deployment with ArgoCD

For production deployments managed via ArgoCD/GitOps, see the example in [`examples/argocd/`](examples/argocd/) which includes:

- Kustomization for the collector + tracing params
- ArgoCD Application definition
- Fan-out to both Langfuse and Solo Enterprise UI (ClickHouse)

## Troubleshooting

### No traces appearing in Langfuse

1. **Check collector is running**: `kubectl get pods -n agentgateway-system -l app=langfuse-otel-collector`
2. **Check collector logs**: `kubectl logs -n agentgateway-system -l app=langfuse-otel-collector`
3. **Verify credentials**: Wrong API keys show as 401 errors in collector logs
4. **Check network**: Ensure the collector pod can reach your Langfuse host
5. **Restart proxies**: AgentGateway proxies must restart after tracing config changes

### Traces in AgentGateway logs but not Langfuse

- Langfuse only supports **OTLP HTTP** (not gRPC) — the collector handles protocol conversion
- Check the `otlphttp/langfuse` exporter endpoint URL includes `/api/public/otel`
- Verify Base64 credentials format: `base64(public_key:secret_key)`

### Incomplete trace data

- Ensure `tracing-params.yaml` includes the `fields.add` section for GenAI attributes
- Set `randomSampling: true` to capture all requests (or configure sampling rate)
- Check that `gen_ai.prompt` and `gen_ai.completion` fields are mapped

## Verification Script

Run the included verification script to test the full pipeline:

```bash
./scripts/verify.sh
```

The script checks:
1. ✅ Collector pod is running
2. ✅ Tracing endpoint is configured correctly
3. ✅ No errors in collector logs
4. ✅ Sends a test LLM request
5. ✅ Verifies traces appear in Langfuse

## Resources

- **Solo AgentGateway Docs**: [docs.solo.io/agentgateway](https://docs.solo.io/agentgateway/)
- **AgentGateway OSS**: [agentgateway.dev](https://agentgateway.dev)
- **Langfuse Docs**: [langfuse.com/docs](https://langfuse.com/docs)
- **Langfuse OpenTelemetry**: [langfuse.com/docs/integrations/opentelemetry](https://langfuse.com/docs/integrations/opentelemetry)
- **OpenTelemetry GenAI Conventions**: [opentelemetry.io/docs/specs/semconv/gen-ai](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- **Report Issues**: [GitHub Issues](https://github.com/ProfessorSeb/agentgateway-langfuse/issues)

## Learn More About Solo AgentGateway

### What is AgentGateway?

[AgentGateway](https://agentgateway.dev) is an open-source, Kubernetes-native gateway purpose-built for AI traffic. Unlike traditional API gateways, it natively understands LLM protocols, MCP (Model Context Protocol), and A2A (Agent-to-Agent) communication. It uses the standard Kubernetes Gateway API for configuration.

### What can AgentGateway do?

- **LLM Routing**: Route requests to multiple LLM providers (OpenAI, Anthropic, xAI, Azure, Gemini, Ollama)
- **Model Failover**: Automatic failover between models with priority groups
- **MCP Proxying**: Proxy MCP tool servers with authentication, policy enforcement, and tracing
- **Security Policies**: PII protection, prompt injection prevention, credential leak detection
- **Rate Limiting**: Request-based and token-based rate limiting per user
- **Observability**: Native OpenTelemetry tracing for all traffic

### Is AgentGateway open source?

Yes. The core AgentGateway is open source at [agentgateway.dev](https://agentgateway.dev). Solo also offers an Enterprise edition with additional features like advanced rate limiting, model failover with priority groups, and a management UI.
