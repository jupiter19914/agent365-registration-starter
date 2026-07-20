# =============================================================================
# Register Agent 365 identity objects in Entra ID (PowerShell)
#
# Creates: Blueprint -> Agent Identity -> Federated Identity Credential (FIC)
#
# Prerequisites:
#   - Azure CLI logged in with permissions to create app registrations
#   - App Service with system-assigned Managed Identity enabled
#
# Usage:
#   $env:TENANT_ID = "your-tenant-id"
#   $env:APP_SERVICE_MI_OBJECT_ID = "your-mi-object-id"
#   .\scripts\register_agent_identity.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

$TenantId = $env:TENANT_ID
$MiObjectId = $env:APP_SERVICE_MI_OBJECT_ID
$AgentName = if ($env:AGENT_NAME) { $env:AGENT_NAME } else { "my-langchain-agent" }
$BlueprintName = "$AgentName-blueprint"

if (-not $TenantId) { throw "Set TENANT_ID environment variable" }
if (-not $MiObjectId) { throw "Set APP_SERVICE_MI_OBJECT_ID environment variable" }

Write-Host "=== Step 1: Create Blueprint App Registration ===" -ForegroundColor Cyan
$BlueprintAppId = az ad app create `
    --display-name $BlueprintName `
    --sign-in-audience AzureADMyOrg `
    --query appId -o tsv
Write-Host "Blueprint App ID: $BlueprintAppId"

az ad sp create --id $BlueprintAppId --query id -o tsv | Out-Null

Write-Host ""
Write-Host "=== Step 2: Create Agent Identity App Registration ===" -ForegroundColor Cyan
$AgentAppId = az ad app create `
    --display-name $AgentName `
    --sign-in-audience AzureADMyOrg `
    --query appId -o tsv
Write-Host "Agent Identity App ID: $AgentAppId"

az ad sp create --id $AgentAppId --query id -o tsv | Out-Null

Write-Host ""
Write-Host "=== Step 3: Configure Blueprint for Agent 365 ===" -ForegroundColor Cyan
Write-Host "Setting identifier URI and exposing API scope..."

# Set identifier URI (required for Agent 365 to recognize the Blueprint)
az ad app update --id $BlueprintAppId --identifier-uris "api://$BlueprintAppId"

# Generate a scope ID
$ScopeId = [guid]::NewGuid().ToString()

# Get Blueprint object ID for Graph calls
$BlueprintObjectId = az ad app show --id $BlueprintAppId --query id -o tsv

# Expose API scope and add Agent 365 tags
$BlueprintPatch = @{
    api = @{
        oauth2PermissionScopes = @(@{
            adminConsentDescription = "Allow Agent 365 to access this blueprint"
            adminConsentDisplayName = "Access as Agent"
            id = $ScopeId
            isEnabled = $true
            type = "Admin"
            value = "access_as_agent"
        })
    }
    tags = @("WindowsAzureActiveDirectoryIntegratedApp", "M365Agent")
} | ConvertTo-Json -Depth 4 -Compress

az rest --method PATCH `
    --uri "https://graph.microsoft.com/v1.0/applications/$BlueprintObjectId" `
    --headers "Content-Type=application/json" `
    --body $BlueprintPatch

Write-Host "Blueprint configured with identifier URI and Agent 365 tags"

Write-Host ""
Write-Host "=== Step 4: Configure Agent Identity for Agent 365 ===" -ForegroundColor Cyan

# Set identifier URI on Agent Identity
az ad app update --id $AgentAppId --identifier-uris "api://$AgentAppId"

# Get Agent Identity object ID
$AgentObjectId = az ad app show --id $AgentAppId --query id -o tsv

# Tag as Agent Identity and pre-authorize the Blueprint
$AgentPatch = @{
    tags = @("WindowsAzureActiveDirectoryIntegratedApp", "M365AgentIdentity")
    api = @{
        preAuthorizedApplications = @(@{
            appId = $BlueprintAppId
            delegatedPermissionIds = @($ScopeId)
        })
    }
} | ConvertTo-Json -Depth 4 -Compress

az rest --method PATCH `
    --uri "https://graph.microsoft.com/v1.0/applications/$AgentObjectId" `
    --headers "Content-Type=application/json" `
    --body $AgentPatch

# Add Microsoft Agent Service permission (AgentSession.ReadWrite.All)
Write-Host "Adding Microsoft Agent Service API permission..."
try {
    az ad app permission add --id $AgentAppId `
        --api "48ac35b8-9aa8-4d74-927d-1f4a14a0b239" `
        --api-permissions "bf512614-4309-43bc-a7b5-a3b3460e4a4b=Scope"
} catch {
    Write-Host "  (Note: If Microsoft Agent Service is not in your tenant," -ForegroundColor Yellow
    Write-Host "   add AgentSession.ReadWrite.All manually via Portal > API Permissions)" -ForegroundColor Yellow
}

Write-Host "Agent Identity configured with tags and Blueprint pre-authorization"

Write-Host ""
Write-Host "=== Step 5: Create Federated Identity Credential (FIC) ===" -ForegroundColor Cyan

$FicBody = @{
    name        = "$AgentName-fic"
    issuer      = "https://login.microsoftonline.com/$TenantId/v2.0"
    subject     = $MiObjectId
    audiences   = @("api://$BlueprintAppId")
    description = "FIC binding MI to $BlueprintName for Agent 365"
} | ConvertTo-Json -Compress

az ad app federated-credential create `
    --id $BlueprintAppId `
    --parameters $FicBody

Write-Host ""
Write-Host "=== Step 6: Admin Consent ===" -ForegroundColor Cyan
Write-Host "Granting admin consent for Agent Identity permissions..."
try {
    az ad app permission admin-consent --id $AgentAppId
} catch {
    Write-Host "  (Note: Admin consent may require Global Admin. Grant manually if needed.)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Registration Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Add to .env:"
Write-Host "  AZURE_TENANT_ID=$TenantId"
Write-Host "  AGENT_BLUEPRINT_APP_ID=$BlueprintAppId"
Write-Host "  AGENT_IDENTITY_APP_ID=$AgentAppId"
Write-Host ""
Write-Host "For local dev, create a Blueprint client secret:"
Write-Host "  az ad app credential reset --id $BlueprintAppId --display-name local-dev"
Write-Host ""
Write-Host "For manifest, replace {{AGENT_IDENTITY_APP_ID}} with: $AgentAppId"
Write-Host ""
Write-Host "IMPORTANT: Verify in Azure Portal:" -ForegroundColor Yellow
Write-Host "  1. App Registrations > $BlueprintName > should show 'M365Agent' tag"
Write-Host "  2. App Registrations > $AgentName > should show 'M365AgentIdentity' tag"
Write-Host "  3. Both should appear in Agent 365 admin views within a few minutes"
