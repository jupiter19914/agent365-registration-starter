"""Minimal LangGraph agent with Agent 365 registration.

This is a starter template — replace the echo tool with your actual tools.
"""

from __future__ import annotations

import os
from dotenv import load_dotenv

load_dotenv()

from langchain_azure_ai import AzureChatOpenAI
from langchain_core.tools import tool
from langgraph.graph import StateGraph, END
from langgraph.prebuilt import ToolNode
from typing import Annotated, TypedDict

from agent.agent_identity import get_agent_identity_provider
from agent.agent365_sdk import configure_observability, create_invoke_scope


# --- 1. Define your tools ---

@tool
def echo(message: str) -> str:
    """Echo the user's message back. Replace this with your actual tools."""
    return f"Echo: {message}"


# --- 2. Define agent state ---

class AgentState(TypedDict):
    messages: Annotated[list, "append"]


# --- 3. Build the graph ---

def build_graph():
    llm = AzureChatOpenAI(
        azure_endpoint=os.getenv("AZURE_AI_FOUNDRY_ENDPOINT"),
        azure_deployment=os.getenv("AZURE_AI_FOUNDRY_DEPLOYMENT", "gpt-5.4"),
        api_version=os.getenv("AZURE_AI_FOUNDRY_API_VERSION", "2025-01-01"),
    )

    tools = [echo]
    llm_with_tools = llm.bind_tools(tools)

    def call_model(state: AgentState):
        response = llm_with_tools.invoke(state["messages"])
        return {"messages": [response]}

    def should_continue(state: AgentState):
        last = state["messages"][-1]
        if hasattr(last, "tool_calls") and last.tool_calls:
            return "tools"
        return END

    workflow = StateGraph(AgentState)
    workflow.add_node("agent", call_model)
    workflow.add_node("tools", ToolNode(tools))
    workflow.set_entry_point("agent")
    workflow.add_conditional_edges("agent", should_continue, {"tools": "tools", END: END})
    workflow.add_edge("tools", "agent")

    return workflow.compile()


# --- 4. App startup ---

def main():
    # Configure Agent 365 observability (graceful no-op if SDK not installed)
    configure_observability(
        agent_id=os.getenv("AGENT_IDENTITY_APP_ID", ""),
        agent_name="my-langchain-agent",
        blueprint_id=os.getenv("AGENT_BLUEPRINT_APP_ID", ""),
        tenant_id=os.getenv("AZURE_TENANT_ID", ""),
        environment=os.getenv("ENVIRONMENT", "poc"),
    )

    # Initialize Agent Identity provider (for downstream API auth)
    provider = get_agent_identity_provider()

    # Build graph
    graph = build_graph()

    # Example invocation with Agent 365 scope
    session_id = "demo-session-001"
    user_id = "user-001"
    user_message = "Hello, can you echo this?"

    scope = create_invoke_scope(
        agent_id=os.getenv("AGENT_IDENTITY_APP_ID", ""),
        agent_name="my-langchain-agent",
        session_id=session_id,
        user_id=user_id,
        user_message=user_message,
    )

    if scope:
        with scope:
            result = graph.invoke({"messages": [("user", user_message)]})
    else:
        result = graph.invoke({"messages": [("user", user_message)]})

    print("Agent response:", result["messages"][-1].content)

    # Example: get a governed token for a downstream API
    # token = provider.get_token("https://your-api.example.com/.default")
    # requests.get(url, headers={"Authorization": f"Bearer {token.access_token}"})


if __name__ == "__main__":
    main()
