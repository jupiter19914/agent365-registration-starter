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
Write-Host "=== Step 3: Create Federated Identity Credential (FIC) ===" -ForegroundColor Cyan

$FicBody = @{
    name        = "$AgentName-fic"
    issuer      = "https://login.microsoftonline.com/$TenantId/v2.0"
    subject     = $MiObjectId
    audiences   = @("api://AzureADTokenExchange")
    description = "FIC binding App Service MI to $BlueprintName"
} | ConvertTo-Json -Compress

az ad app federated-credential create `
    --id $BlueprintAppId `
    --parameters $FicBody

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
