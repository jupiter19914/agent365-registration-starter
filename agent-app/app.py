"""
Agent 365 Payment Agent — M365 Agents SDK + LangGraph

This adapter bridges M365 Copilot/Teams with a LangGraph agent running on AKS.
Uses Workload Identity for authentication (no secrets in code).
LangSmith tracing is enabled via environment variables.
"""

import os
import logging

from aiohttp.web import Application, Request, Response, run_app
from dotenv import load_dotenv

from microsoft_agents.hosting.core import (
    AgentApplication,
    TurnContext,
    MemoryStorage,
    AgentAuthConfiguration,
)
from microsoft_agents.hosting.aiohttp import (
    start_agent_process,
    jwt_authorization_middleware,
    CloudAdapter,
)

from agent import create_payment_agent

load_dotenv()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class PaymentAgentApp(AgentApplication):
    """M365 Agents SDK application that routes messages to a LangGraph agent."""

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.agent = create_payment_agent()
        logger.info("LangGraph payment agent initialized")

    async def on_message_activity(self, turn_context: TurnContext):
        user_message = turn_context.activity.text or ""
        logger.info(f"Received message: {user_message[:100]}")

        try:
            # Invoke the LangGraph agent
            result = await self.agent.ainvoke(
                {"messages": [{"role": "user", "content": user_message}]},
                config={"configurable": {"thread_id": turn_context.activity.conversation.id}},
            )

            # Extract the agent's response
            response_messages = result.get("messages", [])
            if response_messages:
                reply = response_messages[-1].content
            else:
                reply = "I processed your request but have no response to share."

            await turn_context.send_activity(reply)

        except Exception as e:
            logger.error(f"Agent error: {e}")
            await turn_context.send_activity(
                f"⚠️ I encountered an error processing your request. "
                f"Please try again or contact support."
            )

    async def on_members_added_activity(self, members_added, turn_context: TurnContext):
        for member in members_added:
            if member.id != turn_context.activity.recipient.id:
                await turn_context.send_activity(
                    "👋 Hello! I'm the **Payment Agent** powered by LangGraph, "
                    "running on AKS with Agent 365 Workload Identity. "
                    "Ask me about payment processing, transaction status, or routing."
                )


# Health check endpoint
async def health_check(request: Request) -> Response:
    return Response(
        text='{"status":"healthy","agent":"test-payment-agent","sdk":"m365-agents-sdk","framework":"langgraph"}',
        content_type="application/json",
        status=200,
    )


def create_app() -> Application:
    config = AgentAuthConfiguration()
    storage = MemoryStorage()
    agent_app = PaymentAgentApp(storage=storage)
    adapter = CloudAdapter(config)

    async def messages_handler(req: Request) -> Response:
        return await start_agent_process(req, agent_app, adapter)

    app = Application(middlewares=[jwt_authorization_middleware])
    app.router.add_post("/api/messages", messages_handler)
    app.router.add_get("/api/messages", lambda _: Response(status=200))
    app.router.add_get("/health", health_check)
    app["agent_app"] = agent_app
    app["adapter"] = adapter

    return app


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "3978"))
    logger.info(f"Starting Payment Agent on port {port}")
    logger.info(f"Blueprint: {os.environ.get('BLUEPRINT_APP_ID', 'not set')}")
    logger.info(f"LangSmith: {'enabled' if os.environ.get('LANGSMITH_API_KEY') else 'disabled'}")
    run_app(create_app(), port=port)
