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
echo "=== Step 3: Configure Blueprint for Agent 365 ==="
echo "Setting identifier URI and exposing API scope..."

# Set identifier URI (required for Agent 365 to recognize the Blueprint)
az ad app update --id "$BLUEPRINT_APP_ID" \
  --identifier-uris "api://$BLUEPRINT_APP_ID"

# Generate a scope ID for the exposed API
SCOPE_ID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || uuidgen)

# Expose an API scope (required for fmi_path token exchange)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$(az ad app show --id $BLUEPRINT_APP_ID --query id -o tsv)" \
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
  }"

echo "Blueprint configured with identifier URI and Agent 365 tags"

echo ""
echo "=== Step 4: Configure Agent Identity for Agent 365 ==="

# Set identifier URI on Agent Identity
az ad app update --id "$AGENT_APP_ID" \
  --identifier-uris "api://$AGENT_APP_ID"

# Get Agent Identity object ID for Graph calls
AGENT_OBJECT_ID=$(az ad app show --id "$AGENT_APP_ID" --query id -o tsv)

# Tag as Agent Identity and pre-authorize the Blueprint
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$AGENT_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"tags\": [\"WindowsAzureActiveDirectoryIntegratedApp\", \"M365AgentIdentity\"],
    \"api\": {
      \"preAuthorizedApplications\": [{
        \"appId\": \"$BLUEPRINT_APP_ID\",
        \"delegatedPermissionIds\": [\"$SCOPE_ID\"]
      }]
    }
  }"

# Add Microsoft Agent Service permission (AgentSession.ReadWrite.All)
# Microsoft Agent Service app ID: 48ac35b8-9aa8-4d74-927d-1f4a14a0b239
echo "Adding Microsoft Agent Service API permission..."
az ad app permission add --id "$AGENT_APP_ID" \
  --api "48ac35b8-9aa8-4d74-927d-1f4a14a0b239" \
  --api-permissions "bf512614-4309-43bc-a7b5-a3b3460e4a4b=Scope" 2>/dev/null || \
  echo "  (Note: If the Microsoft Agent Service is not available in your tenant,"
  echo "   add AgentSession.ReadWrite.All manually via Azure Portal > API Permissions)"

echo "Agent Identity configured with tags and Blueprint pre-authorization"

echo ""
echo "=== Step 5: Create Federated Identity Credential (FIC) ==="
echo "Binding Blueprint to Managed Identity via fmi_path..."

# The FIC allows the MI to request tokens as the Blueprint,
# which then exchanges via fmi_path for the Agent Identity token.
FIC_BODY=$(cat <<EOF
{
  "name": "${AGENT_NAME}-fic",
  "issuer": "https://login.microsoftonline.com/${TENANT_ID}/v2.0",
  "subject": "${MI_OBJECT_ID}",
  "audiences": ["api://${BLUEPRINT_APP_ID}"],
  "description": "FIC binding MI to ${BLUEPRINT_NAME} for Agent 365"
}
EOF
)

az ad app federated-credential create \
  --id "$BLUEPRINT_APP_ID" \
  --parameters "$FIC_BODY"

echo ""
echo "=== Step 6: Admin Consent ==="
echo "Granting admin consent for Agent Identity permissions..."
az ad app permission admin-consent --id "$AGENT_APP_ID" 2>/dev/null || \
  echo "  (Note: Admin consent may require Global Admin. Grant manually if needed.)"

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
echo ""
echo "IMPORTANT: Verify in Azure Portal:"
echo "  1. App Registrations > $BLUEPRINT_NAME > should show 'M365Agent' tag"
echo "  2. App Registrations > $AGENT_NAME > should show 'M365AgentIdentity' tag"
echo "  3. Both should appear in Agent 365 admin views within a few minutes"
