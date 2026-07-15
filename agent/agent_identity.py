"""Entra Agent ID — fmi_path token acquisition.

Provides governed identity tokens via the Federated Managed Identity path (fmi_path).
The agent uses this token for downstream API calls so every action is cryptographically
attributable to the Agent Identity.

Token flow:
  1. Acquire bootstrap credential (MI on App Service, or client secret locally)
  2. Exchange via fmi_path for Agent Identity token scoped to target resource

The resulting token's `sub` claim = Agent Identity app ID, enabling audit trail.
"""

from __future__ import annotations

import json
import logging
import os
import time
from base64 import urlsafe_b64decode
from dataclasses import dataclass, field
from threading import Lock
from typing import Any

import httpx

logger = logging.getLogger(__name__)

_TOKEN_REFRESH_BUFFER_SECONDS = 300


@dataclass
class AgentIdentityToken:
    """Cached Agent Identity token with expiry tracking."""

    access_token: str = ""
    expires_on: float = 0.0
    resource: str = ""
    claims: dict[str, Any] = field(default_factory=dict)

    @property
    def is_valid(self) -> bool:
        return bool(self.access_token) and time.time() < (
            self.expires_on - _TOKEN_REFRESH_BUFFER_SECONDS
        )


class AgentIdentityProvider:
    """Acquires and caches Agent Identity tokens via fmi_path exchange.

    Usage:
        provider = AgentIdentityProvider()
        token = provider.get_token("https://your-api.example.com/.default")
        headers = {"Authorization": f"Bearer {token.access_token}"}
    """

    def __init__(
        self,
        tenant_id: str | None = None,
        blueprint_app_id: str | None = None,
        agent_identity_app_id: str | None = None,
        blueprint_client_secret: str | None = None,
    ):
        self._tenant_id = tenant_id or os.getenv("AZURE_TENANT_ID", "")
        self._blueprint_app_id = blueprint_app_id or os.getenv("AGENT_BLUEPRINT_APP_ID", "")
        self._agent_identity_app_id = agent_identity_app_id or os.getenv("AGENT_IDENTITY_APP_ID", "")
        self._blueprint_secret = blueprint_client_secret or os.getenv("BLUEPRINT_CLIENT_SECRET", "")
        self._token_endpoint = (
            f"https://login.microsoftonline.com/{self._tenant_id}/oauth2/v2.0/token"
        )
        self._cache: dict[str, AgentIdentityToken] = {}
        self._lock = Lock()
        self._is_app_service = bool(os.getenv("IDENTITY_ENDPOINT"))

    def get_token(self, scope: str = "https://graph.microsoft.com/.default") -> AgentIdentityToken:
        """Get a cached or fresh Agent Identity token for the given scope."""
        with self._lock:
            cached = self._cache.get(scope)
            if cached and cached.is_valid:
                return cached
            token = self._acquire_token(scope)
            self._cache[scope] = token
            return token

    def _acquire_token(self, scope: str) -> AgentIdentityToken:
        """Execute the 2-step fmi_path token exchange."""
        bootstrap_token = self._get_bootstrap_token()

        exchange_data = {
            "grant_type": "client_credentials",
            "client_id": self._agent_identity_app_id,
            "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            "client_assertion": bootstrap_token,
            "scope": scope,
        }

        with httpx.Client(timeout=httpx.Timeout(15.0)) as client:
            resp = client.post(self._token_endpoint, data=exchange_data)

        if resp.status_code != 200:
            raise RuntimeError(
                f"Agent Identity token exchange failed: HTTP {resp.status_code} - {resp.text[:500]}"
            )

        token_data = resp.json()
        access_token = token_data["access_token"]
        expires_in = token_data.get("expires_in", 3600)
        claims = self._decode_jwt_claims(access_token)

        logger.info(
            "Agent Identity token acquired: sub=%s, aud=%s, expires_in=%ds",
            claims.get("sub", "unknown"),
            claims.get("aud", "unknown"),
            expires_in,
        )

        return AgentIdentityToken(
            access_token=access_token,
            expires_on=time.time() + expires_in,
            resource=scope,
            claims=claims,
        )

    def _get_bootstrap_token(self) -> str:
        """Get bootstrap token (T1) from Blueprint with fmi_path=agent_identity."""
        base_data = {
            "grant_type": "client_credentials",
            "client_id": self._blueprint_app_id,
            "scope": "api://AzureADTokenExchange/.default",
            "fmi_path": self._agent_identity_app_id,
        }

        if self._is_app_service:
            from azure.identity import ManagedIdentityCredential

            mi_cred = ManagedIdentityCredential()
            mi_token = mi_cred.get_token("api://AzureADTokenExchange")
            base_data["client_assertion_type"] = (
                "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
            )
            base_data["client_assertion"] = mi_token.token
        elif self._blueprint_secret:
            base_data["client_secret"] = self._blueprint_secret
        else:
            raise RuntimeError(
                "No bootstrap credential available. "
                "Set BLUEPRINT_CLIENT_SECRET for local dev, or run on App Service with MI."
            )

        with httpx.Client(timeout=httpx.Timeout(10.0)) as client:
            resp = client.post(self._token_endpoint, data=base_data)

        if resp.status_code != 200:
            raise RuntimeError(
                f"Bootstrap token (T1) failed: HTTP {resp.status_code} - {resp.text[:300]}"
            )

        return resp.json()["access_token"]

    @staticmethod
    def _decode_jwt_claims(token: str) -> dict[str, Any]:
        """Decode JWT payload without verification (logging/audit only)."""
        try:
            parts = token.split(".")
            if len(parts) < 2:
                return {}
            payload = parts[1] + "=" * (4 - len(parts[1]) % 4)
            return json.loads(urlsafe_b64decode(payload))
        except Exception:
            return {}


# --- Module-level convenience functions ---

_provider: AgentIdentityProvider | None = None


def get_agent_identity_provider() -> AgentIdentityProvider:
    """Get or create the singleton AgentIdentityProvider."""
    global _provider
    if _provider is None:
        _provider = AgentIdentityProvider()
    return _provider


def get_agent_token(scope: str = "https://graph.microsoft.com/.default") -> str:
    """Convenience: get a valid Agent Identity access token string."""
    return get_agent_identity_provider().get_token(scope).access_token
