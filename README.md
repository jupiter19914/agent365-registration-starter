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

Run the registration script to create Blueprint + Agent Identity + FIC in your tenant:

```bash
# Set your tenant and App Service Managed Identity object ID
export TENANT_ID="your-tenant-id"
export APP_SERVICE_MI_OBJECT_ID="your-app-service-mi-object-id"
export AGENT_NAME="my-langchain-agent"

# Run registration
bash scripts/register_agent_identity.sh
```

The script creates 3 Entra objects:
| Object | Purpose |
|--------|---------|
| **Blueprint** | App registration that holds the FIC (trust anchor) |
| **Agent Identity** | App registration whose `sub` claim appears in audit logs |
| **FIC** | Federated Identity Credential binding App Service MI → Blueprint |

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

## References

- [Agent 365 SDK Developer Guide](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/agent-365-sdk)
- [M365 App Manifest Schema v1.19](https://learn.microsoft.com/en-us/microsoft-365/extensibility/schema/)
- [Declarative Agent Schema v1.7](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/declarative-agent-manifest-1.7)
- [API Plugin Schema v2.2](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/api-plugin-manifest)
- [Entra Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
