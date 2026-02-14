# Quickstart: AgentGateway OSS 2.1 + Langfuse on Kind

Get AgentGateway OSS running on a local kind cluster with Langfuse tracing in under 10 minutes.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed and running
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [helm](https://helm.sh/docs/intro/install/) installed
- A [Langfuse](https://cloud.langfuse.com) account (free tier works) or self-hosted instance

## Step 1: Create a Kind Cluster

```bash
kind create cluster --name agentgateway
```

Verify the cluster is running:

```bash
kubectl cluster-info --context kind-agentgateway
```

## Step 2: Install Kubernetes Gateway API CRDs

AgentGateway uses the standard Kubernetes Gateway API. Install the CRDs:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

## Step 3: Install AgentGateway CRDs

```bash
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/helm/agentgateway-crds \
  --version 2.1.0 \
  --namespace agentgateway-system \
  --create-namespace
```

## Step 4: Install AgentGateway Control Plane

```bash
helm upgrade -i agentgateway oci://cr.agentgateway.dev/helm/agentgateway \
  --version 2.1.0 \
  --namespace agentgateway-system
```

Verify the control plane is running:

```bash
kubectl get pods -n agentgateway-system
```

You should see the agentgateway controller pod in `Running` state.

Verify the GatewayClass was created:

```bash
kubectl get gatewayclass agentgateway
```

## Step 5: Deploy the Langfuse OTel Collector

Get your Langfuse API keys from **Settings → API Keys** in the Langfuse UI.

Base64 encode your credentials:

```bash
echo -n "pk-lf-YOUR_PUBLIC_KEY:sk-lf-YOUR_SECRET_KEY" | base64
```

Deploy the collector (update the placeholders first):

```bash
# Edit the langfuse host and credentials
cp examples/basic/langfuse-collector.yaml /tmp/langfuse-collector.yaml

# Replace placeholders
sed -i 's|<YOUR_LANGFUSE_HOST>|cloud.langfuse.com|g' /tmp/langfuse-collector.yaml
sed -i 's|<YOUR_BASE64_CREDENTIALS>|YOUR_BASE64_HERE|g' /tmp/langfuse-collector.yaml

kubectl apply -f /tmp/langfuse-collector.yaml
```

## Step 6: Configure AgentGateway Tracing

For AgentGateway OSS, set the tracing endpoint via Helm values. Create a `values-tracing.yaml`:

```yaml
# values-tracing.yaml
gateway:
  envs:
    OTEL_EXPORTER_OTLP_ENDPOINT: "http://langfuse-otel-collector.agentgateway-system.svc.cluster.local:4317"
    OTEL_EXPORTER_OTLP_PROTOCOL: "grpc"
```

Upgrade the installation with tracing enabled:

```bash
helm upgrade agentgateway oci://cr.agentgateway.dev/helm/agentgateway \
  --version 2.1.0 \
  --namespace agentgateway-system \
  -f values-tracing.yaml
```

## Step 7: Create a Gateway and LLM Route

Create a Gateway resource:

```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ai-gateway
  namespace: agentgateway-system
spec:
  gatewayClassName: agentgateway
  listeners:
    - name: llm
      port: 8080
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: Same
```

Create an HTTPRoute for OpenAI:

```yaml
# openai-route.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openai
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: ai-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /openai
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: openai
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai
  namespace: agentgateway-system
spec:
  type: llm
  llm:
    provider:
      openai:
        authToken:
          secretRef:
            name: openai-api-key
            namespace: agentgateway-system
```

Create the OpenAI API key secret:

```bash
kubectl create secret generic openai-api-key \
  -n agentgateway-system \
  --from-literal=Authorization="Bearer $OPENAI_API_KEY"
```

Apply the resources:

```bash
kubectl apply -f gateway.yaml
kubectl apply -f openai-route.yaml
```

## Step 8: Test It

Port-forward the gateway:

```bash
kubectl port-forward -n agentgateway-system svc/ai-gateway 8080:8080 &
```

Send a test request:

```bash
curl -X POST http://localhost:8080/openai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4.1-mini",
    "messages": [{"role": "user", "content": "Hello from AgentGateway on kind!"}]
  }'
```

## Step 9: View Traces in Langfuse

Open your Langfuse UI → **Traces**. You should see the request with:

- Model name and provider
- Input/output token counts
- Full prompt and completion content
- Gateway metadata (route, backend, listener)

## Cleanup

```bash
kind delete cluster --name agentgateway
```

## Next Steps

- Add more LLM providers (Anthropic, xAI) — see the [main README](../README.md)
- Enable security policies (PII protection, prompt injection guard)
- Set up fan-out tracing to multiple backends — see [`examples/fan-out/`](../examples/fan-out/)
- Deploy with ArgoCD for GitOps — see [`examples/argocd/`](../examples/argocd/)
