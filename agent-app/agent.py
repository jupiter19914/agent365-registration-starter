"""
LangGraph Payment Agent

Defines the agent graph that processes payment-related queries.
Replace this with your actual LangGraph agent logic.
"""

import os
from langchain_openai import AzureChatOpenAI
from langgraph.graph import StateGraph, MessagesState, START, END


def create_payment_agent():
    """Create and return a compiled LangGraph agent."""

    # Configure the LLM (uses Azure OpenAI via Managed Identity)
    llm = AzureChatOpenAI(
        azure_deployment=os.environ.get("AZURE_OPENAI_DEPLOYMENT", "gpt-4o"),
        azure_endpoint=os.environ.get("AZURE_OPENAI_ENDPOINT", ""),
        api_version=os.environ.get("AZURE_OPENAI_API_VERSION", "2024-10-21"),
        # No API key needed — uses DefaultAzureCredential via Workload Identity
    )

    # Define the agent graph
    async def process_message(state: MessagesState):
        """Process incoming message through the LLM."""
        system_prompt = (
            "You are a payment processing assistant for Navy Federal Credit Union. "
            "You help users with transaction status inquiries, payment routing questions, "
            "and general payment processing guidance. "
            "Be professional, concise, and helpful. "
            "If you don't know something, say so rather than guessing."
        )

        messages = [{"role": "system", "content": system_prompt}] + state["messages"]
        response = await llm.ainvoke(messages)
        return {"messages": [response]}

    # Build the graph
    graph = StateGraph(MessagesState)
    graph.add_node("agent", process_message)
    graph.add_edge(START, "agent")
    graph.add_edge("agent", END)

    return graph.compile()
