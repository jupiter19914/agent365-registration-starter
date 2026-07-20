# Agent 365 Registration Starter — Python LangChain/LangGraph

Minimal repo for registering a Python LangChain/LangGraph agent with Microsoft Agent 365.

## What's Included

```
agent365-registration-starter/
├── agent/                         # Python agent code
│   ├── app.py                     # Minimal LangGraph agent with Agent 365 integration
│   ├── agent_identity.py          # Entra Agent ID — fmi_path token exchange
│   ├── agent365_sdk.py            # Agent 365 SDK — observability wrapper
│   └── __init__.py
│
├── manifest/                      # M365 app manifest (for Teams/Copilot publishing)
│   ├── manifest.json              # M365 app manifest (v1.19)
│   ├── declarativeAgent.json      # Declarative agent definition (v1.7)
│   └── apiPlugin.json             # API plugin → OpenAPI mapping (v2.2)
│
├── scripts/                       # Entra ID registration automation
│   ├── register_agent_identity.sh    # Bash (Linux/Mac)
│   └── register_agent_identity.ps1   # PowerShell (Windows)
│
├── requirements.txt               # Python dependencies
├── .env.sample                    # Environment variable template
└── .gitignore
```

## Quick Start

### 1. Register Entra Agent ID Objects

Run the registration script to create and configure all Agent 365 Entra objects:

```bash
# Set your tenant and Managed Identity object ID
export TENANT_ID="your-tenant-id"
export APP_SERVICE_MI_OBJECT_ID="your-app-service-mi-object-id"  # or UAMI client ID for AKS
export AGENT_NAME="my-langchain-agent"

# Run registration (6 steps)
bash scripts/register_agent_identity.sh
```

The script performs 6 steps:

| Step | Action | Why |
|------|--------|-----|
| 1 | Create Blueprint app registration | Trust anchor that holds the FIC |
| 2 | Create Agent Identity app registration | Runtime identity (sub claim in audit logs) |
| 3 | **Configure Blueprint for Agent 365** | Sets `api://<id>` URI, exposes API scope, adds `M365Agent` tag |
| 4 | **Configure Agent Identity for Agent 365** | Sets `api://<id>` URI, pre-authorizes Blueprint, adds `M365AgentIdentity` tag, grants Microsoft Agent Service permission |
| 5 | Create FIC | Binds MI → Blueprint with correct audience (`api://<blueprint-id>`) |
| 6 | Admin consent | Grants consent on Agent Identity permissions |

> **Important:** Steps 3–4 are what make the app registrations appear in Agent 365 admin views (Blueprint and Identity sections). Without these steps, the registrations exist in Entra but are not recognized by Agent 365.

> **Alternative:** If you prefer a GUI-based approach, use [Teams Toolkit CLI](https://learn.microsoft.com/en-us/microsoftteams/platform/toolkit/teams-toolkit-cli):
> ```bash
> npm install -g @microsoft/teamsapp-cli
> teamsapp init --capability declarative-agent
> teamsapp provision --env dev
> ```
> This handles all tagging and configuration automatically.

### 2. Configure Environment

Copy `.env.sample` to `.env` and fill in the values from step 1:

```bash
cp .env.sample .env
# Edit .env with your Blueprint/Agent Identity app IDs
```

### 3. Install Dependencies

```bash
pip install -r requirements.txt
```

### 4. Run the Agent

```bash
python -m agent.app
```

## How It Works

### Identity Flow (fmi_path)

```
App Service (Managed Identity)
  │  Step 1: MI gets bootstrap token
  ▼
Blueprint (FIC bound to MI)
  │  fmi_path = Agent Identity app ID
  ▼  Step 2: Exchange for named token
Agent Identity (sub = your-agent-app-id)
  │  Token passed to downstream APIs
  ▼
Your APIs / Cosmos DB / Graph
```

### Observability Flow (Agent 365 SDK)

```
User message arrives
  │
  ▼
InvokeAgentScope (wraps the turn)
  ├── LangGraph: route_node
  ├── LangGraph: tool_call_node
  │     ├── Tool: your_tool (auto-traced)
  │     └── LLM: GPT-5.4 (tokens counted)
  └── Spans exported to Agent 365 surface
```

### Graceful Degradation

The agent works **without** the Agent 365 SDK packages installed — it just
loses observability tracing. The `_SDK_AVAILABLE` flag guards all SDK code paths.
This means you can develop and test locally without the SDK.

## M365 Manifest Publishing

To make your agent discoverable in Teams / M365 Copilot:

1. Replace `{{AGENT_IDENTITY_APP_ID}}` in `manifest/manifest.json`
2. Update `validDomains` with your App Service hostname
3. Update `apiPlugin.json` → `spec.url` with your OpenAPI endpoint
4. Add icons: `color.png` (192×192) and `outline.png` (32×32) to `manifest/`
5. Package:
   ```powershell
   Compress-Archive -Path manifest/* -DestinationPath my-agent.zip
   ```
6. Upload to M365 Admin Center → Settings → Integrated apps

## Key Files to Customize

| File | What to Change |
|------|---------------|
| `agent/app.py` | Replace `echo` tool with your actual tools; update graph logic |
| `agent/agent365_sdk.py` | No changes needed (generic wrapper) |
| `agent/agent_identity.py` | No changes needed (generic provider) |
| `manifest/declarativeAgent.json` | Your agent's instructions and conversation starters |
| `manifest/apiPlugin.json` | Your function definitions and OpenAPI URL |
| `manifest/manifest.json` | Your app identity, description, and valid domains |

## Required Entra Roles

| Role | Who Needs It | Purpose |
|------|-------------|---------|
| Agent ID Administrator | Tenant admin | Create/manage blueprints and agent identities |
| Agent ID Developer | Developer | Create agent identities under existing blueprints |
| Application Developer | Developer | Create app registrations |

## Troubleshooting

### App registrations not appearing in Agent 365 admin views

**Symptom:** You ran the registration script but the Blueprint/Identity don't show up in the Agent 365 portal.

**Causes and fixes:**

| Cause | Fix |
|-------|-----|
| Missing `M365Agent` / `M365AgentIdentity` tags | Re-run steps 3–4 of the script, or manually add tags via Graph Explorer |
| No `identifierUris` set | Run `az ad app update --id <APP_ID> --identifier-uris "api://<APP_ID>"` |
| Blueprint doesn't expose an API scope | Check `api.oauth2PermissionScopes` in the Blueprint's manifest |
| Agent Identity not pre-authorized | Verify `api.preAuthorizedApplications` includes the Blueprint app ID |
| Propagation delay | Wait 5–10 minutes; Entra changes can take time to propagate to Agent 365 |
| Insufficient permissions | Ensure you have Application Administrator or Cloud Application Administrator role |

**Verify tags via CLI:**
```bash
# Check Blueprint tags
az ad app show --id $BLUEPRINT_APP_ID --query tags

# Check Agent Identity tags
az ad app show --id $AGENT_APP_ID --query tags

# Expected output for Blueprint: ["WindowsAzureActiveDirectoryIntegratedApp", "M365Agent"]
# Expected output for Identity:  ["WindowsAzureActiveDirectoryIntegratedApp", "M365AgentIdentity"]
```

**Verify identifier URIs:**
```bash
az ad app show --id $BLUEPRINT_APP_ID --query identifierUris
# Expected: ["api://<blueprint-app-id>"]
```

**Verify exposed API scope:**
```bash
az ad app show --id $BLUEPRINT_APP_ID --query "api.oauth2PermissionScopes[].value"
# Expected: ["access_as_agent"]
```

### FIC audience mismatch

**Symptom:** Token exchange fails with "AADSTS700024: Client assertion audience claim does not match."

**Fix:** The FIC audience must be `api://<BLUEPRINT_APP_ID>` (not `api://AzureADTokenExchange` for Agent 365 scenarios):
```bash
# Delete old FIC and recreate with correct audience
az ad app federated-credential delete --id $BLUEPRINT_APP_ID --federated-credential-id <fic-id>
az ad app federated-credential create --id $BLUEPRINT_APP_ID --parameters '{
  "name": "agent365-fic",
  "issuer": "https://login.microsoftonline.com/<TENANT_ID>/v2.0",
  "subject": "<MI_OBJECT_ID>",
  "audiences": ["api://<BLUEPRINT_APP_ID>"]
}'
```

## References

- [Agent 365 SDK Developer Guide](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/agent-365-sdk)
- [M365 App Manifest Schema v1.19](https://learn.microsoft.com/en-us/microsoft-365/extensibility/schema/)
- [Declarative Agent Schema v1.7](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/declarative-agent-manifest-1.7)
- [API Plugin Schema v2.2](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/api-plugin-manifest)
- [Entra Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [Teams Toolkit CLI](https://learn.microsoft.com/en-us/microsoftteams/platform/toolkit/teams-toolkit-cli)
