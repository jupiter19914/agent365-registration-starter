#!/bin/bash
# =============================================================================
# Register Agent 365 identity objects in Entra ID
#
# Creates: Blueprint → Agent Identity → Federated Identity Credential (FIC)
#
# Prerequisites:
#   - Azure CLI logged in with permissions to create app registrations
#   - App Service with system-assigned Managed Identity enabled
#
# Usage:
#   export TENANT_ID="your-tenant-id"
#   export APP_SERVICE_MI_OBJECT_ID="your-mi-object-id"
#   bash scripts/register_agent_identity.sh
# =============================================================================

set -euo pipefail

TENANT_ID="${TENANT_ID:?Set TENANT_ID}"
MI_OBJECT_ID="${APP_SERVICE_MI_OBJECT_ID:?Set APP_SERVICE_MI_OBJECT_ID}"
AGENT_NAME="${AGENT_NAME:-my-langchain-agent}"
BLUEPRINT_NAME="${AGENT_NAME}-blueprint"

echo "=== Step 1: Create Blueprint App Registration ==="
BLUEPRINT_APP_ID=$(az ad app create \
  --display-name "$BLUEPRINT_NAME" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)
echo "Blueprint App ID: $BLUEPRINT_APP_ID"

# Create service principal for the blueprint
az ad sp create --id "$BLUEPRINT_APP_ID" --query id -o tsv

echo ""
echo "=== Step 2: Create Agent Identity App Registration ==="
AGENT_APP_ID=$(az ad app create \
  --display-name "$AGENT_NAME" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)
echo "Agent Identity App ID: $AGENT_APP_ID"

az ad sp create --id "$AGENT_APP_ID" --query id -o tsv

echo ""
echo "=== Step 3: Create Federated Identity Credential (FIC) ==="
echo "Binding Blueprint to App Service Managed Identity via fmi_path..."

# The FIC allows the App Service MI to request tokens as the Blueprint,
# which then exchanges via fmi_path for the Agent Identity token.
FIC_BODY=$(cat <<EOF
{
  "name": "${AGENT_NAME}-fic",
  "issuer": "https://login.microsoftonline.com/${TENANT_ID}/v2.0",
  "subject": "${MI_OBJECT_ID}",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "FIC binding App Service MI to ${BLUEPRINT_NAME}"
}
EOF
)

az ad app federated-credential create \
  --id "$BLUEPRINT_APP_ID" \
  --parameters "$FIC_BODY"

echo ""
echo "=== Registration Complete ==="
echo ""
echo "Add these to your .env file:"
echo "  AZURE_TENANT_ID=$TENANT_ID"
echo "  AGENT_BLUEPRINT_APP_ID=$BLUEPRINT_APP_ID"
echo "  AGENT_IDENTITY_APP_ID=$AGENT_APP_ID"
echo ""
echo "For local dev, also create a client secret on the Blueprint:"
echo "  az ad app credential reset --id $BLUEPRINT_APP_ID --display-name local-dev"
echo ""
echo "For manifest packaging, replace {{AGENT_IDENTITY_APP_ID}} with: $AGENT_APP_ID"
