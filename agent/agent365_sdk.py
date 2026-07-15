"""Agent 365 SDK integration — observability for LangChain/LangGraph agents.

Provides:
- OpenTelemetry tracing via Agent 365 SDK (LangChain extension)
- InvokeAgentScope wrapping for each conversation turn
- Graceful degradation when SDK packages are not installed

The SDK sits on top of the Entra Agent ID (fmi_path) identity layer:
  Entra Agent ID  = identity foundation (Blueprint + Agent Identity + fmi_path)
  Agent 365 SDK   = enterprise capabilities (observability, notifications, Work IQ)
"""

from __future__ import annotations

import logging
import os
from typing import Optional

logger = logging.getLogger(__name__)

# SDK availability — agent works without SDK (just loses observability)
_SDK_AVAILABLE = False
_instrumentor = None
_configured = False

try:
    from microsoft_agents_a365.observability import core as a365_observability
    from microsoft_agents_a365.observability.core import (
        AgentDetails,
        InvokeAgentScope,
        InvokeAgentScopeDetails,
    )
    from microsoft_agents_a365.observability.core.models.caller_details import CallerDetails
    from microsoft_agents_a365.observability.core.models.user_details import UserDetails
    from microsoft_agents_a365.observability.extensions.langchain import CustomLangChainInstrumentor

    _SDK_AVAILABLE = True
    logger.info("Agent 365 SDK packages loaded")
except ImportError as e:
    logger.warning("Agent 365 SDK not installed: %s", e)


def configure_observability(
    agent_id: str,
    agent_name: str,
    blueprint_id: str,
    tenant_id: str,
    environment: str = "poc",
) -> bool:
    """Configure Agent 365 SDK with OpenTelemetry + LangChain auto-instrumentation.

    Args:
        agent_id:     The Agent Identity app ID
        agent_name:   Display name for the agent
        blueprint_id: The Blueprint app ID
        tenant_id:    Azure AD tenant ID
        environment:  Deployment environment (poc, nonprod, prod)

    Returns:
        True if configured, False if SDK unavailable.
    """
    global _instrumentor, _configured

    if not _SDK_AVAILABLE:
        logger.warning("Agent 365 SDK not available — observability disabled")
        return False

    if _configured:
        return True

    try:
        success = a365_observability.configure(
            service_name=agent_name,
            service_namespace=f"agents.{environment}",
            logger_name=agent_name,
            cluster_category=environment,
            suppress_invoke_agent_input=False,
        )

        if not success:
            logger.error("Agent 365 configure() returned False")
            return False

        _instrumentor = CustomLangChainInstrumentor()
        _instrumentor.instrument()
        logger.info("Agent 365 SDK configured (agent=%s, blueprint=%s)", agent_id, blueprint_id)

        _configured = True
        return True

    except Exception as exc:
        logger.exception("Failed to configure Agent 365: %s", exc)
        return False


def create_invoke_scope(
    agent_id: str,
    agent_name: str,
    session_id: str,
    user_id: str,
    user_message: str,
    hostname: str = "",
) -> Optional["InvokeAgentScope"]:
    """Create an InvokeAgentScope for a conversation turn.

    Wraps a user turn in an observable scope for the Agent 365 surface.

    Returns:
        InvokeAgentScope context manager, or None if SDK unavailable.
    """
    if not _SDK_AVAILABLE or not _configured:
        return None

    try:
        from microsoft_agents_a365.observability.core import (
            Request,
            InputMessages,
            ChatMessage,
            MessageRole,
            TextPart,
            ServiceEndpoint,
        )

        agent_details = AgentDetails(
            agent_id=agent_id,
            agent_name=agent_name,
            agent_description=agent_name,
            tenant_id=os.getenv("AZURE_TENANT_ID", ""),
            agent_version="1.0.0",
            provider_name="Microsoft",
        )

        scope_details = InvokeAgentScopeDetails(
            endpoint=ServiceEndpoint(
                hostname=hostname or os.getenv("WEBSITE_HOSTNAME", "localhost"),
                port=443,
            )
        )

        msg = ChatMessage(role=MessageRole.USER, parts=[TextPart(content=user_message)])
        request = Request(content=InputMessages(messages=[msg]), session_id=session_id)

        caller_details = CallerDetails(
            user_details=UserDetails(user_id=user_id, user_name=user_id)
        )

        return InvokeAgentScope(
            request=request,
            scope_details=scope_details,
            agent_details=agent_details,
            caller_details=caller_details,
        )

    except Exception as exc:
        logger.debug("Could not create InvokeAgentScope: %s", exc)
        return None


def is_configured() -> bool:
    """Check if Agent 365 SDK observability is active."""
    return _configured and _SDK_AVAILABLE
