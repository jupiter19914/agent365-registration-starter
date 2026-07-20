#!/bin/bash
# =============================================================================
# Agent 365 AKS Registration — Automated Test & Verification
#
# Creates a test AKS cluster, runs the registration script, verifies all
# outputs, tests token flow from inside a pod, and reports pass/fail.
#
# Usage:
#   bash scripts/test_aks_registration.sh [--cleanup]
#
# Options:
#   --cleanup    Delete all test resources after verification
#
# Prerequisites:
#   - Azure CLI logged in to your TEST tenant
#   - Sufficient quota for 1x Standard_B2s node in eastus
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="rg-agent365-test"
CLUSTER="aks-agent365-test"
LOCATION="westus2"
AGENT_NAME="test-payment-agent"
NAMESPACE="agent365"
CLEANUP="false"
PASS_COUNT=0
FAIL_COUNT=0

[[ "${1:-}" == "--cleanup" ]] && CLEANUP="true"

# ─── Helpers ─────────────────────────────────────────────────────────────────
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  ❌ FAIL: $1"; }
check() {
  if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Agent 365 AKS Registration — Test Suite                        ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Tenant:  $(az account show --query tenantId -o tsv)"
echo "Sub:     $(az account show --query name -o tsv)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Create Test Infrastructure
# ═══════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PHASE 1: Creating test infrastructure"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create RG
echo "▸ Creating resource group..."
az group create --name $RESOURCE_GROUP --location $LOCATION --only-show-errors -o none

# Create AKS with WI + OIDC
echo "▸ Creating AKS cluster (this takes 3-5 minutes)..."
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER \
  --location $LOCATION \
  --node-count 1 \
  --node-vm-size Standard_D2as_v4 \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --generate-ssh-keys \
  --only-show-errors -o none

# Get credentials
echo "▸ Getting kubectl credentials..."
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER \
  --overwrite-existing --only-show-errors

echo "  ✓ Test infrastructure ready"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: Run the registration script
# ═══════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PHASE 2: Running register_aks_agent365.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/register_aks_agent365.sh" \
  --cluster $CLUSTER \
  --resource-group $RESOURCE_GROUP \
  --agent-name $AGENT_NAME

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: Verify Entra Objects
# ═══════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PHASE 3: Verifying Entra objects"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

BLUEPRINT_APP_ID=$(az ad app list --display-name "${AGENT_NAME}-blueprint" --query "[0].appId" -o tsv)
AGENT_APP_ID=$(az ad app list --display-name "$AGENT_NAME" --query "[0].appId" -o tsv)

echo "  Blueprint: $BLUEPRINT_APP_ID"
echo "  Agent ID:  $AGENT_APP_ID"
echo ""

# Check Blueprint tags
BP_TAGS=$(az ad app show --id "$BLUEPRINT_APP_ID" --query "tags" -o tsv 2>/dev/null || echo "")
if echo "$BP_TAGS" | grep -q "M365Agent"; then
  pass "Blueprint has M365Agent tag"
else
  fail "Blueprint missing M365Agent tag (got: $BP_TAGS)"
fi

# Check Agent Identity tags
AI_TAGS=$(az ad app show --id "$AGENT_APP_ID" --query "tags" -o tsv 2>/dev/null || echo "")
if echo "$AI_TAGS" | grep -q "M365AgentIdentity"; then
  pass "Agent Identity has M365AgentIdentity tag"
else
  fail "Agent Identity missing M365AgentIdentity tag (got: $AI_TAGS)"
fi

# Check Blueprint identifier URI
BP_URI=$(az ad app show --id "$BLUEPRINT_APP_ID" --query "identifierUris[0]" -o tsv 2>/dev/null || echo "")
if [[ "$BP_URI" == "api://$BLUEPRINT_APP_ID" ]]; then
  pass "Blueprint identifier URI is api://<app-id>"
else
  fail "Blueprint identifier URI incorrect (got: $BP_URI)"
fi

# Check Agent Identity identifier URI
AI_URI=$(az ad app show --id "$AGENT_APP_ID" --query "identifierUris[0]" -o tsv 2>/dev/null || echo "")
if [[ "$AI_URI" == "api://$AGENT_APP_ID" ]]; then
  pass "Agent Identity identifier URI is api://<app-id>"
else
  fail "Agent Identity identifier URI incorrect (got: $AI_URI)"
fi

# Check exposed scope on Blueprint
BP_SCOPE=$(az ad app show --id "$BLUEPRINT_APP_ID" --query "api.oauth2PermissionScopes[0].value" -o tsv 2>/dev/null || echo "")
if [[ "$BP_SCOPE" == "access_as_agent" ]]; then
  pass "Blueprint exposes 'access_as_agent' scope"
else
  fail "Blueprint missing exposed scope (got: $BP_SCOPE)"
fi

# Check pre-authorization
PREAUTH=$(az ad app show --id "$AGENT_APP_ID" --query "api.preAuthorizedApplications[0].appId" -o tsv 2>/dev/null || echo "")
if [[ "$PREAUTH" == "$BLUEPRINT_APP_ID" ]]; then
  pass "Agent Identity pre-authorizes Blueprint"
else
  fail "Agent Identity not pre-authorizing Blueprint (got: $PREAUTH)"
fi

# Check FIC on Blueprint
FIC_AUD=$(az ad app federated-credential list --id "$BLUEPRINT_APP_ID" --query "[0].audiences[0]" -o tsv 2>/dev/null || echo "")
if [[ "$FIC_AUD" == "api://$BLUEPRINT_APP_ID" ]]; then
  pass "Blueprint FIC audience is api://<blueprint-id>"
else
  fail "Blueprint FIC audience incorrect (got: $FIC_AUD)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: Verify Kubernetes Resources
# ═══════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PHASE 4: Verifying Kubernetes resources"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check namespace exists
if kubectl get namespace $NAMESPACE >/dev/null 2>&1; then
  pass "Namespace '$NAMESPACE' exists"
else
  fail "Namespace '$NAMESPACE' not found"
fi

# Check ServiceAccount exists and has annotation
SA_ANNOTATION=$(kubectl get sa "${AGENT_NAME}-sa" -n $NAMESPACE -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}' 2>/dev/null || echo "")
if [[ -n "$SA_ANNOTATION" ]]; then
  pass "ServiceAccount has workload identity annotation: $SA_ANNOTATION"
else
  fail "ServiceAccount missing workload identity annotation"
fi

# Check UAMI federated credential
UAMI_FIC=$(az identity federated-credential list \
  --identity-name "${AGENT_NAME}-uami" \
  --resource-group $RESOURCE_GROUP \
  --query "[0].subject" -o tsv 2>/dev/null || echo "")
if [[ "$UAMI_FIC" == "system:serviceaccount:${NAMESPACE}:${AGENT_NAME}-sa" ]]; then
  pass "UAMI federated credential subject matches ServiceAccount"
else
  fail "UAMI federated credential subject mismatch (got: $UAMI_FIC)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5: Test Token Acquisition from Pod
# ═══════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PHASE 5: Testing token acquisition from pod"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Deploy test pod
echo "  ▸ Deploying test pod..."
kubectl delete pod token-test -n $NAMESPACE 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: token-test
  namespace: $NAMESPACE
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: ${AGENT_NAME}-sa
  containers:
  - name: test
    image: python:3.11-slim
    command: ["sleep", "600"]
  restartPolicy: Never
EOF

echo "  ▸ Waiting for pod to be ready (up to 90s)..."
kubectl wait --for=condition=Ready pod/token-test -n $NAMESPACE --timeout=90s 2>/dev/null || {
  fail "Test pod did not become ready"
  echo ""
  echo "Pod status:"
  kubectl describe pod token-test -n $NAMESPACE | tail -10
}

# Check env vars injected
echo "  ▸ Checking Workload Identity env vars..."
AZURE_VARS=$(kubectl exec -n $NAMESPACE token-test -- env 2>/dev/null | grep "^AZURE_" || echo "")
if echo "$AZURE_VARS" | grep -q "AZURE_FEDERATED_TOKEN_FILE"; then
  pass "AZURE_FEDERATED_TOKEN_FILE injected into pod"
else
  fail "AZURE_FEDERATED_TOKEN_FILE not found in pod env"
fi

if echo "$AZURE_VARS" | grep -q "AZURE_CLIENT_ID"; then
  pass "AZURE_CLIENT_ID injected into pod"
else
  fail "AZURE_CLIENT_ID not found in pod env"
fi

# Install azure-identity and test token
echo "  ▸ Installing azure-identity in pod..."
kubectl exec -n $NAMESPACE token-test -- pip install azure-identity --quiet 2>/dev/null

echo "  ▸ Testing DefaultAzureCredential..."
TOKEN_RESULT=$(kubectl exec -n $NAMESPACE token-test -- python -c "
from azure.identity import DefaultAzureCredential
try:
    c = DefaultAzureCredential()
    t = c.get_token('https://management.azure.com/.default')
    print('SUCCESS')
except Exception as e:
    print(f'FAILED: {e}')
" 2>/dev/null || echo "FAILED: kubectl exec error")

if echo "$TOKEN_RESULT" | grep -q "SUCCESS"; then
  pass "DefaultAzureCredential token acquisition succeeded"
else
  fail "Token acquisition failed: $TOKEN_RESULT"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 6: Test Idempotency (re-run)
# ═══════════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PHASE 6: Testing idempotency (re-run)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if bash "$SCRIPT_DIR/register_aks_agent365.sh" \
  --cluster $CLUSTER \
  --resource-group $RESOURCE_GROUP \
  --agent-name $AGENT_NAME >/dev/null 2>&1; then
  pass "Re-run completed without errors (idempotent)"
else
  fail "Re-run produced errors"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  TEST RESULTS                                                   ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  ✅ Passed: $PASS_COUNT                                              ║"
echo "║  ❌ Failed: $FAIL_COUNT                                              ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
  echo "🎉 ALL TESTS PASSED"
else
  echo "⚠️  SOME TESTS FAILED — review output above"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# CLEANUP (optional)
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$CLEANUP" == "true" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "CLEANUP: Removing test resources"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  echo "  ▸ Deleting app registrations..."
  az ad app delete --id "$BLUEPRINT_APP_ID" 2>/dev/null || true
  az ad app delete --id "$AGENT_APP_ID" 2>/dev/null || true

  echo "  ▸ Deleting resource group (async)..."
  az group delete --name $RESOURCE_GROUP --yes --no-wait

  echo "  ✓ Cleanup initiated (RG deletion is async)"
else
  echo "── To clean up later, run: ──────────────────────────────────────"
  echo ""
  echo "  az ad app delete --id $BLUEPRINT_APP_ID"
  echo "  az ad app delete --id $AGENT_APP_ID"
  echo "  az group delete --name $RESOURCE_GROUP --yes --no-wait"
  echo ""
fi
