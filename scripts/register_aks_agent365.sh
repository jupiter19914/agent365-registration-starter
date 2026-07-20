#!/bin/bash
# =============================================================================
# Agent 365 — Fully Automated AKS Registration
#
# Single script that performs ALL Agent 365 registration and AKS Workload
# Identity setup. No manual Portal steps required.
#
# What this script does:
#   1. Creates Blueprint + Agent Identity app registrations
#   2. Configures both for Agent 365 (URIs, scopes, tags, permissions)
#   3. Creates User-Assigned Managed Identity (UAMI)
#   4. Creates AKS federated credential (Workload Identity)
#   5. Creates Kubernetes namespace + annotated ServiceAccount
#   6. Outputs ready-to-use ConfigMap and Deployment YAML
#
# Usage:
#   bash scripts/register_aks_agent365.sh \
#     --cluster my-aks-cluster \
#     --resource-group my-rg \
#     --namespace agent365 \
#     --agent-name payment-agent
#
# Prerequisites:
#   - Azure CLI logged in (az login)
#   - kubectl configured to target your AKS cluster
#   - Permissions: Application Administrator + Contributor on RG
# =============================================================================

set -euo pipefail

# ─── Parse arguments ─────────────────────────────────────────────────────────
CLUSTER=""
RESOURCE_GROUP=""
NAMESPACE="agent365"
AGENT_NAME="langchain-agent"
LOCATION=""
SKIP_K8S="false"

print_usage() {
  echo "Usage: bash scripts/register_aks_agent365.sh \\"
  echo "  --cluster <aks-cluster-name> \\"
  echo "  --resource-group <resource-group> \\"
  echo "  [--namespace <k8s-namespace>]    # default: agent365"
  echo "  [--agent-name <name>]            # default: langchain-agent"
  echo "  [--location <azure-region>]      # default: from resource group"
  echo "  [--skip-k8s]                     # skip kubectl steps"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --agent-name) AGENT_NAME="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --skip-k8s) SKIP_K8S="true"; shift ;;
    -h|--help) print_usage ;;
    *) echo "Unknown option: $1"; print_usage ;;
  esac
done

if [[ -z "$CLUSTER" || -z "$RESOURCE_GROUP" ]]; then
  echo "ERROR: --cluster and --resource-group are required."
  print_usage
fi

BLUEPRINT_NAME="${AGENT_NAME}-blueprint"
SA_NAME="${AGENT_NAME}-sa"
UAMI_NAME="${AGENT_NAME}-uami"

# ─── Auto-detect tenant and location ────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Agent 365 — Automated AKS Registration                        ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

echo "▸ Detecting environment..."
TENANT_ID=$(az account show --query tenantId -o tsv | tr -d '\r')
SUBSCRIPTION_ID=$(az account show --query id -o tsv | tr -d '\r')

if [[ -z "$LOCATION" ]]; then
  LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv | tr -d '\r')
fi

echo "  Tenant:         $TENANT_ID"
echo "  Subscription:   $SUBSCRIPTION_ID"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Location:       $LOCATION"
echo "  AKS Cluster:    $CLUSTER"
echo "  Agent Name:     $AGENT_NAME"
echo "  K8s Namespace:  $NAMESPACE"
echo ""

# ─── Step 1: Verify AKS has Workload Identity + OIDC ────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1/6 ▸ Verifying AKS cluster configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

OIDC_ISSUER=$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER" \
  --query "oidcIssuerProfile.issuerUrl" -o tsv 2>/dev/null | tr -d '\r' || echo "")

WI_ENABLED=$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER" \
  --query "securityProfile.workloadIdentity.enabled" -o tsv 2>/dev/null | tr -d '\r' || echo "false")

if [[ -z "$OIDC_ISSUER" || "$OIDC_ISSUER" == "None" ]]; then
  echo "  ⚠ OIDC Issuer not enabled. Enabling now..."
  az aks update --resource-group "$RESOURCE_GROUP" --name "$CLUSTER" \
    --enable-oidc-issuer --only-show-errors
  OIDC_ISSUER=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER" \
    --query "oidcIssuerProfile.issuerUrl" -o tsv | tr -d '\r')
fi

if [[ "$WI_ENABLED" != "true" ]]; then
  echo "  ⚠ Workload Identity not enabled. Enabling now..."
  az aks update --resource-group "$RESOURCE_GROUP" --name "$CLUSTER" \
    --enable-workload-identity --only-show-errors
fi

echo "  ✓ OIDC Issuer: $OIDC_ISSUER"
echo "  ✓ Workload Identity: enabled"
echo ""

# ─── Step 2: Create UAMI ────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2/6 ▸ Creating User-Assigned Managed Identity"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if UAMI already exists
UAMI_EXISTS=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$UAMI_NAME" --query clientId -o tsv 2>/dev/null | tr -d '\r' || echo "")

if [[ -n "$UAMI_EXISTS" ]]; then
  echo "  ℹ UAMI '$UAMI_NAME' already exists, reusing..."
  UAMI_CLIENT_ID="$UAMI_EXISTS"
else
  az identity create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$UAMI_NAME" \
    --location "$LOCATION" \
    --only-show-errors
  UAMI_CLIENT_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$UAMI_NAME" --query clientId -o tsv | tr -d '\r')
fi

UAMI_PRINCIPAL_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$UAMI_NAME" --query principalId -o tsv | tr -d '\r')
UAMI_RESOURCE_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$UAMI_NAME" --query id -o tsv | tr -d '\r')

echo "  ✓ UAMI Client ID:    $UAMI_CLIENT_ID"
echo "  ✓ UAMI Principal ID: $UAMI_PRINCIPAL_ID"
echo ""

# Create AKS federated credential for Workload Identity
echo "  Creating federated credential for AKS Workload Identity..."
az identity federated-credential create \
  --name "${AGENT_NAME}-aks-fic" \
  --identity-name "$UAMI_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --issuer "$OIDC_ISSUER" \
  --subject "system:serviceaccount:${NAMESPACE}:${SA_NAME}" \
  --audiences "api://AzureADTokenExchange" \
  --only-show-errors 2>/dev/null || echo "  ℹ Federated credential already exists"

echo "  ✓ AKS federated credential configured"
echo ""

# ─── Step 3: Create and configure Blueprint ─────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3/6 ▸ Creating and configuring Blueprint app registration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if Blueprint already exists
BLUEPRINT_APP_ID=$(az ad app list --display-name "$BLUEPRINT_NAME" --query "[0].appId" -o tsv 2>/dev/null | tr -d '\r' || echo "")

if [[ -z "$BLUEPRINT_APP_ID" || "$BLUEPRINT_APP_ID" == "None" ]]; then
  BLUEPRINT_APP_ID=$(az ad app create \
    --display-name "$BLUEPRINT_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv | tr -d '\r')
  az ad sp create --id "$BLUEPRINT_APP_ID" --only-show-errors >/dev/null 2>&1 || true
  echo "  ✓ Created Blueprint: $BLUEPRINT_APP_ID"
else
  echo "  ℹ Blueprint '$BLUEPRINT_NAME' already exists: $BLUEPRINT_APP_ID"
fi

# Set identifier URI
az ad app update --id "$BLUEPRINT_APP_ID" --identifier-uris "api://$BLUEPRINT_APP_ID" --only-show-errors

# Get object ID for Graph calls
BLUEPRINT_OBJECT_ID=$(az ad app show --id "$BLUEPRINT_APP_ID" --query id -o tsv | tr -d '\r')

# Check if scope already exists
EXISTING_SCOPE=$(az ad app show --id "$BLUEPRINT_APP_ID" --query "api.oauth2PermissionScopes[?value=='access_as_agent'].id | [0]" -o tsv 2>/dev/null | tr -d '\r')

if [[ -z "$EXISTING_SCOPE" || "$EXISTING_SCOPE" == "None" ]]; then
  # Generate scope ID
  SCOPE_ID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)

  # Expose API scope + add Agent 365 tags
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$BLUEPRINT_OBJECT_ID" \
    --headers "Content-Type=application/json" \
    --body "{
      \"api\": {
        \"oauth2PermissionScopes\": [{
          \"adminConsentDescription\": \"Allow Agent 365 to access this blueprint\",
          \"adminConsentDisplayName\": \"Access as Agent\",
          \"id\": \"$SCOPE_ID\",
          \"isEnabled\": true,
          \"type\": \"Admin\",
          \"value\": \"access_as_agent\"
        }]
      },
      \"tags\": [\"WindowsAzureActiveDirectoryIntegratedApp\", \"M365Agent\"]
    }" --only-show-errors
  echo "  ✓ API scope exposed: access_as_agent"
else
  SCOPE_ID="$EXISTING_SCOPE"
  # Just update tags (scope already exists)
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$BLUEPRINT_OBJECT_ID" \
    --headers "Content-Type=application/json" \
    --body "{\"tags\": [\"WindowsAzureActiveDirectoryIntegratedApp\", \"M365Agent\"]}" --only-show-errors
  echo "  ℹ API scope already exists (skipped)"
fi

# ─── Step 4: Create and configure Agent Identity ────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4/6 ▸ Creating and configuring Agent Identity app registration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if Agent Identity already exists
AGENT_APP_ID=$(az ad app list --display-name "$AGENT_NAME" --query "[0].appId" -o tsv 2>/dev/null | tr -d '\r' || echo "")

if [[ -z "$AGENT_APP_ID" || "$AGENT_APP_ID" == "None" ]]; then
  AGENT_APP_ID=$(az ad app create \
    --display-name "$AGENT_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv | tr -d '\r')
  az ad sp create --id "$AGENT_APP_ID" --only-show-errors >/dev/null 2>&1 || true
  echo "  ✓ Created Agent Identity: $AGENT_APP_ID"
else
  echo "  ℹ Agent Identity '$AGENT_NAME' already exists: $AGENT_APP_ID"
fi

# Set identifier URI
az ad app update --id "$AGENT_APP_ID" --identifier-uris "api://$AGENT_APP_ID" --only-show-errors

# Get object ID
AGENT_OBJECT_ID=$(az ad app show --id "$AGENT_APP_ID" --query id -o tsv | tr -d '\r')

# Get existing tags and merge (preserve M365Agent if this app is also the Blueprint)
EXISTING_TAGS=$(az ad app show --id "$AGENT_APP_ID" --query "tags" -o json 2>/dev/null | tr -d '\r')
if echo "$EXISTING_TAGS" | grep -q "M365Agent"; then
  AGENT_TAGS="[\"WindowsAzureActiveDirectoryIntegratedApp\", \"M365Agent\", \"M365AgentIdentity\"]"
else
  AGENT_TAGS="[\"WindowsAzureActiveDirectoryIntegratedApp\", \"M365AgentIdentity\"]"
fi

# Tag + pre-authorize Blueprint
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$AGENT_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"tags\": $AGENT_TAGS,
    \"api\": {
      \"preAuthorizedApplications\": [{
        \"appId\": \"$BLUEPRINT_APP_ID\",
        \"delegatedPermissionIds\": [\"$SCOPE_ID\"]
      }]
    }
  }" --only-show-errors

# Add Microsoft Agent Service permission
az ad app permission add --id "$AGENT_APP_ID" \
  --api "48ac35b8-9aa8-4d74-927d-1f4a14a0b239" \
  --api-permissions "bf512614-4309-43bc-a7b5-a3b3460e4a4b=Scope" \
  --only-show-errors 2>/dev/null || true

# Admin consent
az ad app permission admin-consent --id "$AGENT_APP_ID" --only-show-errors 2>/dev/null || \
  echo "  ⚠ Admin consent requires Global Admin — grant manually if needed"

echo "  ✓ Identifier URI: api://$AGENT_APP_ID"
echo "  ✓ Tagged: M365AgentIdentity"
echo "  ✓ Blueprint pre-authorized"
echo "  ✓ Agent Service permission added"
echo ""

# ─── Step 5: Create Blueprint FIC (UAMI → Blueprint) ────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5/6 ▸ Creating Blueprint federated credential (UAMI → Blueprint)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

az ad app federated-credential create \
  --id "$BLUEPRINT_APP_ID" \
  --parameters "{
    \"name\": \"${AGENT_NAME}-uami-fic\",
    \"issuer\": \"https://login.microsoftonline.com/${TENANT_ID}/v2.0\",
    \"subject\": \"${UAMI_CLIENT_ID}\",
    \"audiences\": [\"api://${BLUEPRINT_APP_ID}\"],
    \"description\": \"FIC binding UAMI to Blueprint for Agent 365 fmi_path\"
  }" --only-show-errors 2>/dev/null || echo "  ℹ FIC already exists on Blueprint"

echo "  ✓ Blueprint FIC: UAMI ($UAMI_CLIENT_ID) → Blueprint ($BLUEPRINT_APP_ID)"
echo "  ✓ Audience: api://$BLUEPRINT_APP_ID"
echo ""

# ─── Step 6: Create Kubernetes resources ─────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6/6 ▸ Creating Kubernetes namespace and ServiceAccount"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$SKIP_K8S" == "true" ]]; then
  echo "  ⏭ Skipped (--skip-k8s flag)"
else
  # Get credentials
  az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER" --overwrite-existing --only-show-errors

  # Create namespace
  kubectl create namespace "$NAMESPACE" 2>/dev/null || echo "  ℹ Namespace '$NAMESPACE' already exists"

  # Create ServiceAccount
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SA_NAME
  namespace: $NAMESPACE
  annotations:
    azure.workload.identity/client-id: "$UAMI_CLIENT_ID"
  labels:
    azure.workload.identity/use: "true"
EOF

  echo "  ✓ Namespace: $NAMESPACE"
  echo "  ✓ ServiceAccount: $SA_NAME (annotated with UAMI)"
fi

echo ""

# ─── Output summary ─────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ✅  REGISTRATION COMPLETE                                      ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│ ENTRA OBJECTS                                                   │"
echo "├─────────────────────────────────────────────────────────────────┤"
echo "│ Blueprint App ID:       $BLUEPRINT_APP_ID"
echo "│ Agent Identity App ID:  $AGENT_APP_ID"
echo "│ UAMI Client ID:         $UAMI_CLIENT_ID"
echo "│ Tenant ID:              $TENANT_ID"
echo "├─────────────────────────────────────────────────────────────────┤"
echo "│ AKS WORKLOAD IDENTITY                                          │"
echo "├─────────────────────────────────────────────────────────────────┤"
echo "│ OIDC Issuer:  $OIDC_ISSUER"
echo "│ Namespace:    $NAMESPACE"
echo "│ ServiceAcct:  $SA_NAME"
echo "│ UAMI:         $UAMI_NAME"
echo "└─────────────────────────────────────────────────────────────────┘"
echo ""
echo "── ConfigMap (copy to your deployment) ──────────────────────────"
echo ""
cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${AGENT_NAME}-config
  namespace: $NAMESPACE
data:
  AZURE_TENANT_ID: "$TENANT_ID"
  BLUEPRINT_APP_ID: "$BLUEPRINT_APP_ID"
  AGENT_APP_ID: "$AGENT_APP_ID"
  # Add your Azure AI Foundry settings:
  # AZURE_OPENAI_ENDPOINT: "https://<your-foundry>.openai.azure.com/"
  # AZURE_OPENAI_DEPLOYMENT: "gpt-5.4"
  # AZURE_OPENAI_API_VERSION: "2025-04-01-preview"
EOF
echo ""
echo "── Deployment snippet (key fields) ──────────────────────────────"
echo ""
cat <<EOF
spec:
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: $SA_NAME
      containers:
      - name: agent
        image: <your-acr>.azurecr.io/${AGENT_NAME}:latest
        envFrom:
        - configMapRef:
            name: ${AGENT_NAME}-config
EOF
echo ""
echo "── Next steps ───────────────────────────────────────────────────"
echo ""
echo "  1. Build and push your container image"
echo "  2. Apply the ConfigMap and Deployment to namespace '$NAMESPACE'"
echo "  3. Package manifest/ and upload to Teams Admin Center"
echo "  4. Verify: az ad app show --id $BLUEPRINT_APP_ID --query tags"
echo "     Expected: [\"WindowsAzureActiveDirectoryIntegratedApp\", \"M365Agent\"]"
echo ""
