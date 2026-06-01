# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import httpx
from langchain_core.messages import SystemMessage, ToolMessage
from langchain_core.tools import tool
from langgraph.graph import END, StateGraph
from openai import OpenAI

from .config import (
    AUTH_TYPE,
    CONFIG_PROFILE,
    MODEL_ID,
    OCI_GENAI_API_KEY,
    OCI_GENAI_AUTH_MODE,
    OCI_GENAI_MEMORY_ACCESS_POLICY,
    OCI_GENAI_MEMORY_SUBJECT_ID,
    OCI_GENAI_PROJECT_ID,
    OCI_GENAI_SHORT_TERM_MEMORY_OPTIMIZATION,
    logger,
)
from .models import AgentState, ChatMessage
from .utils import _extract_trace, _json_safe, _message_content_to_text, _messages_from_history, _sse

SYSTEM_PROMPT = (
    "You are a helpful OCI DevOps assistant. Write naturally, clearly, and concisely. "
    "Use tools only when they are needed to answer an OCI-related question, inspect live OCI data, or perform an OCI operation. "
    "For general conversation, greetings, explanations, and questions that do not require live OCI data, answer directly without tools. "
    "If the user's request is unclear, incomplete, or ambiguous, ask one brief clarifying question before taking action. "
    "When tools are needed, choose the smallest useful set of tools. "
    "When a RAG file_search tool is available, use it for questions about uploaded documents, runbooks, SOPs, policies, architecture notes, incidents, troubleshooting guides, or any user-specific knowledge that may be in the selected RAG source. "
    "Prefer RAG over general knowledge for those document-grounded questions, and cite or summarize the retrieved evidence rather than guessing. "
    "Do not invent compartments, instances, images, shapes, or other OCI resources. "
    "If a tool returns an error, inspect the failure and explain the problem clearly. "
    "If the information cannot be determined from the tools or the available context, say so plainly instead of guessing."
)


def _base_url_for_region(region: Optional[str]) -> str:
    selected_region = region or os.getenv("OCI_REGION") or "us-chicago-1"
    return f"https://inference.generativeai.{selected_region}.oci.oraclecloud.com/openai/v1"


def _vector_base_url_for_region(region: Optional[str], control_plane: bool = False) -> str:
    selected_region = region or os.getenv("OCI_REGION") or "us-chicago-1"
    if control_plane:
        return f"https://generativeai.{selected_region}.oci.oraclecloud.com/20231130"
    return f"https://inference.generativeai.{selected_region}.oci.oraclecloud.com/openai/v1"


def _vector_legacy_base_url_for_region(region: Optional[str]) -> str:
    selected_region = region or os.getenv("OCI_REGION") or "us-chicago-1"
    return f"https://inference.generativeai.{selected_region}.oci.oraclecloud.com/20231130"


def _oci_auth(force_iam: bool = False) -> Optional[httpx.Auth]:
    mode = (OCI_GENAI_AUTH_MODE or AUTH_TYPE or "API_KEY").upper()
    if not force_iam and mode == "API_KEY" and OCI_GENAI_API_KEY:
        return None

    try:
        from oci_genai_auth import (
            OciInstancePrincipalAuth,
            OciResourcePrincipalAuth,
            OciSessionAuth,
            OciUserPrincipalAuth,
        )
    except ImportError as exc:
        raise RuntimeError(
            "OCI IAM auth requires the oci-genai-auth package. Install requirements.txt or set OCI_GENAI_API_KEY."
        ) from exc

    if mode in {"INSTANCE_PRINCIPAL", "INSTANCE_PRINCIPALS"}:
        return OciInstancePrincipalAuth()
    if mode in {"RESOURCE_PRINCIPAL", "RESOURCE_PRINCIPALS"}:
        return OciResourcePrincipalAuth()
    if mode in {"SECURITY_TOKEN", "SESSION_TOKEN"}:
        return OciSessionAuth(profile_name=CONFIG_PROFILE)
    return OciUserPrincipalAuth(profile_name=CONFIG_PROFILE)


def _client(region: Optional[str], project_id: Optional[str]) -> OpenAI:
    selected_project_id = project_id or OCI_GENAI_PROJECT_ID
    if not selected_project_id:
        raise RuntimeError(
            "Select an OCI Generative AI project before chatting, or set OCI_GENAI_PROJECT_ID."
        )

    auth = _oci_auth()
    http_client = httpx.Client(auth=auth, timeout=httpx.Timeout(120.0, read=300.0)) if auth else None
    return OpenAI(
        base_url=_base_url_for_region(region),
        api_key=OCI_GENAI_API_KEY or "oci-iam-auth",
        project=selected_project_id,
        http_client=http_client,
    )


def _vector_client(
    region: Optional[str],
    project_id: Optional[str],
    compartment_id: Optional[str] = None,
    control_plane: bool = False,
) -> OpenAI:
    selected_project_id = project_id or OCI_GENAI_PROJECT_ID
    if not selected_project_id:
        raise RuntimeError("Select an OCI Generative AI project before using RAG.")

    auth = _oci_auth(force_iam=control_plane)
    if control_plane:
        try:
            from oci_openai import OciOpenAI
        except ImportError as exc:
            raise RuntimeError("OCI vector store management requires the oci-openai package.") from exc

        return OciOpenAI(
            service_endpoint=_vector_base_url_for_region(region, control_plane),
            auth=auth,
            compartment_id=compartment_id,
            project=selected_project_id,
            default_headers={"opc-compartment-id": compartment_id} if compartment_id else None,
        )

    headers = {"opc-compartment-id": compartment_id} if control_plane and compartment_id else None
    http_client = httpx.Client(auth=auth, timeout=httpx.Timeout(120.0, read=300.0)) if auth else None
    kwargs: Dict[str, Any] = {
        "base_url": _vector_base_url_for_region(region, control_plane),
        "api_key": "oci-iam-auth" if control_plane else OCI_GENAI_API_KEY or "oci-iam-auth",
        "project": selected_project_id,
        "http_client": http_client,
    }
    if headers:
        kwargs["default_headers"] = headers
    return OpenAI(
        **kwargs,
    )


def _vector_legacy_client(region: Optional[str], project_id: Optional[str], compartment_id: Optional[str] = None) -> OpenAI:
    selected_project_id = project_id or OCI_GENAI_PROJECT_ID
    if not selected_project_id:
        raise RuntimeError("Select an OCI Generative AI project before using RAG.")

    try:
        from oci_openai import OciOpenAI
    except ImportError as exc:
        raise RuntimeError("OCI vector store data-plane operations require the oci-openai package.") from exc

    auth = _oci_auth(force_iam=True)
    return OciOpenAI(
        service_endpoint=_vector_legacy_base_url_for_region(region),
        auth=auth,
        compartment_id=compartment_id,
        project=selected_project_id,
        default_headers={"opc-compartment-id": compartment_id} if compartment_id else None,
    )


def _conversation_metadata(
    thread_id: str,
    memory_subject_id: Optional[str],
    memory_access_policy: Optional[str],
    short_term_memory_optimization: Optional[str],
) -> Dict[str, str]:
    metadata = {
        "app_thread_id": thread_id,
        "memory_access_policy": memory_access_policy or OCI_GENAI_MEMORY_ACCESS_POLICY or "recall_and_store",
    }

    subject_id = memory_subject_id or OCI_GENAI_MEMORY_SUBJECT_ID
    if subject_id:
        metadata["memory_subject_id"] = subject_id

    optimization = short_term_memory_optimization or OCI_GENAI_SHORT_TERM_MEMORY_OPTIMIZATION
    if optimization:
        metadata["short_term_memory_optimization"] = optimization

    return metadata


def _ensure_conversation(
    client: OpenAI,
    conversation_id: Optional[str],
    thread_id: str,
    memory_subject_id: Optional[str],
    memory_access_policy: Optional[str],
    short_term_memory_optimization: Optional[str],
) -> str:
    if conversation_id:
        return conversation_id

    conversation = client.conversations.create(
        metadata=_conversation_metadata(
            thread_id,
            memory_subject_id,
            memory_access_policy,
            short_term_memory_optimization,
        )
    )
    return str(conversation.id)


def _mcp_tools(
    mcp_enabled: bool,
    mcp_servers: Optional[List[Dict[str, Any]]],
    allowed_mcp_tools: Optional[Dict[str, List[str]]] = None,
    allowed_tools: Optional[List[str]] = None,
) -> List[Dict[str, Any]]:
    if not mcp_enabled:
        return []

    selected_servers = [server for server in mcp_servers or [] if server.get("enabled", True)]
    if not selected_servers:
        return []

    legacy_allowed = [str(name).strip() for name in allowed_tools or [] if str(name).strip()]
    if allowed_tools is not None and not legacy_allowed and not allowed_mcp_tools:
        return []

    tools: List[Dict[str, Any]] = []
    for server in selected_servers:
        server_id = str(server.get("server_id") or server.get("id") or server.get("name") or "mcp-server")
        allowed = [
            str(name).strip()
            for name in (allowed_mcp_tools or {}).get(server_id, [])
            if str(name).strip()
        ]
        if not allowed and legacy_allowed:
            allowed = legacy_allowed

        if allowed_mcp_tools is not None and not allowed:
            continue

        tool: Dict[str, Any] = {
            "type": "mcp",
            "server_label": server_id,
            "server_description": f"Connected MCP server: {server.get('name') or server_id}",
            "server_url": server.get("url"),
            "require_approval": "never",
        }

        if allowed:
            tool["allowed_tools"] = allowed

        token = os.getenv("MCP_AUTHORIZATION_TOKEN", "").strip()
        if token:
            tool["authorization"] = token.removeprefix("Bearer ").strip()

        tools.append(tool)

    return tools


def _rag_tools(
    rag_enabled: bool,
    vector_store_id: Optional[str],
    max_results: Optional[int],
) -> List[Dict[str, Any]]:
    if not rag_enabled or not vector_store_id:
        return []

    tool: Dict[str, Any] = {
        "type": "file_search",
        "vector_store_ids": [vector_store_id],
    }
    if max_results:
        tool["max_num_results"] = max_results
    return [tool]


def _response_text(response: Any) -> str:
    text = getattr(response, "output_text", None)
    if isinstance(text, str) and text:
        return text

    parts: List[str] = []
    for item in getattr(response, "output", []) or []:
        for content in getattr(item, "content", []) or []:
            value = getattr(content, "text", None)
            if value:
                parts.append(str(value))
    return "".join(parts).strip()


def _trace_from_response(response: Any, conversation_id: str, project_id: str, tools: List[Dict[str, Any]]) -> List[str]:
    mcp_tool_count = sum(1 for tool in tools if tool.get("type") == "mcp")
    rag_tool_count = sum(1 for tool in tools if tool.get("type") == "file_search")
    trace = [
        f"OCI Enterprise AI project: {project_id}",
        f"Conversation: {conversation_id}",
        f"MCP tools declared: {mcp_tool_count}",
        f"RAG file search tools declared: {rag_tool_count}",
    ]

    for item in getattr(response, "output", []) or []:
        item_type = getattr(item, "type", "")
        if item_type == "mcp_list_tools":
            imported = getattr(item, "tools", []) or []
            trace.append(f"MCP tools imported: {len(imported)}")
        elif item_type == "mcp_call":
            name = getattr(item, "name", "tool")
            status = getattr(item, "status", "")
            error = getattr(item, "error", "")
            trace.append(f"MCP call: {name} | status: {status}{f' | error: {error}' if error else ''}")
        elif "file_search" in item_type:
            status = getattr(item, "status", "")
            results = getattr(item, "results", None) or []
            trace.append(
                f"RAG file search: {item_type}"
                f"{f' | status: {status}' if status else ''}"
                f" | results: {len(results)}"
            )
    return trace


def _rag_search_context(
    region: Optional[str],
    project_id: Optional[str],
    compartment_id: Optional[str],
    vector_store_id: Optional[str],
    query: str,
    max_results: Optional[int],
) -> tuple[str, List[str]]:
    if not vector_store_id or not query.strip():
        return "", []

    client = _vector_client(region, project_id)
    try:
        result = client.vector_stores.search(
            vector_store_id=vector_store_id,
            query=query,
            max_num_results=max_results or 6,
            rewrite_query=False,
        )
    except Exception as exc:
        status = getattr(exc, "status_code", None) or getattr(exc, "status", None)
        if status != 404:
            raise
        logger.info("Retrying OCI vector store search with 20231130 data-plane endpoint.")
        result = _vector_legacy_client(region, project_id, compartment_id).vector_stores.search(
            vector_store_id=vector_store_id,
            query=query,
            max_num_results=max_results or 6,
            rewrite_query=False,
        )
    items = getattr(result, "data", []) or []
    trace = [f"RAG source: searched vector store {vector_store_id} ({len(items)} result(s))"]
    blocks: List[str] = []

    for index, item in enumerate(items, start=1):
        payload = _json_safe(item)
        if not isinstance(payload, dict):
            continue

        content = payload.get("content")
        if isinstance(content, list):
            text = "\n".join(
                str(part.get("text") if isinstance(part, dict) else part)
                for part in content
                if str(part.get("text") if isinstance(part, dict) else part).strip()
            )
        else:
            text = str(
                payload.get("text")
                or payload.get("content_text")
                or payload.get("chunk_text")
                or content
                or ""
            )

        text = text.strip()
        if text:
            blocks.append(f"[{index}] file_id={payload.get('file_id', '')}\n{text}")

    if not blocks:
        return "", trace

    context = (
        "Use the following RAG source excerpts when they are relevant. "
        "If they do not answer the question, say so.\n\n"
    )
    context += "\n\n".join(blocks)
    context += f"\n\nUser question:\n{query}"
    return context, trace


def _response_kwargs(
    text: str,
    model_id: Optional[str],
    temperature: Optional[float],
    top_p: Optional[float],
    max_tokens: Optional[int],
    conversation_id: str,
    tools: List[Dict[str, Any]],
) -> Dict[str, Any]:
    kwargs: Dict[str, Any] = {
        "model": model_id or MODEL_ID,
        "instructions": SYSTEM_PROMPT,
        "input": text,
        "conversation": conversation_id,
        "store": True,
        "stream": False,
    }
    if tools:
        kwargs["tools"] = tools
    if temperature is not None:
        kwargs["temperature"] = temperature
    if top_p is not None:
        kwargs["top_p"] = top_p
    if max_tokens is not None:
        kwargs["max_output_tokens"] = max_tokens
    return kwargs


def _langgraph_chat_client(
    region: Optional[str],
    compartment_id: Optional[str],
    project_id: Optional[str],
    model_id: Optional[str],
    temperature: Optional[float],
    top_p: Optional[float],
    max_tokens: Optional[int],
):
    try:
        from langchain_oci import ChatOCIOpenAI
    except ImportError as exc:
        raise RuntimeError("LangGraph RAG tools require the langchain-oci package.") from exc

    kwargs: Dict[str, Any] = {
        "auth": _oci_auth(force_iam=True),
        "compartment_id": compartment_id or "",
        "model": model_id or MODEL_ID,
        "base_url": _base_url_for_region(region),
        "store": False,
        "default_headers": {"OpenAi-Project": project_id or OCI_GENAI_PROJECT_ID},
    }
    if temperature is not None:
        kwargs["temperature"] = temperature
    if top_p is not None:
        kwargs["top_p"] = top_p
    if max_tokens is not None:
        kwargs["max_completion_tokens"] = max_tokens
    return ChatOCIOpenAI(**kwargs)


def _rag_langgraph_tool(
    region: Optional[str],
    compartment_id: Optional[str],
    project_id: Optional[str],
    vector_store_id: str,
    max_results: Optional[int],
):
    @tool("search_rag_source")
    def search_rag_source(query: str) -> str:
        """Search the selected RAG source for runbooks, SOPs, policies, architecture notes, incident notes, and uploaded documents."""
        context, _ = _rag_search_context(region, project_id, compartment_id, vector_store_id, query, max_results)
        return context or "No relevant RAG source excerpts were found."

    return search_rag_source


def _run_langgraph_tool_agent(
    text: str,
    history: List[ChatMessage],
    mcp_enabled: bool,
    mcp_servers: Optional[List[Dict[str, Any]]],
    allowed_mcp_tools: Optional[Dict[str, List[str]]],
    allowed_tools: Optional[List[str]],
    region: Optional[str],
    compartment_id: Optional[str],
    project_id: Optional[str],
    model_id: Optional[str],
    temperature: Optional[float],
    top_p: Optional[float],
    max_tokens: Optional[int],
    rag_vector_store_id: str,
    rag_max_results: Optional[int],
) -> Dict[str, Any]:
    selected_project_id = project_id or OCI_GENAI_PROJECT_ID
    rag_tool = _rag_langgraph_tool(region, compartment_id, selected_project_id, rag_vector_store_id, rag_max_results)
    tools = [
        rag_tool,
        *_mcp_tools(mcp_enabled, mcp_servers, allowed_mcp_tools, allowed_tools),
    ]
    llm = _langgraph_chat_client(region, compartment_id, selected_project_id, model_id, temperature, top_p, max_tokens)
    llm_with_tools = llm.bind_tools(tools)

    def call_model(state: AgentState) -> AgentState:
        response = llm_with_tools.invoke(state["messages"])
        return {"messages": [response]}

    def call_local_tools(state: AgentState) -> AgentState:
        last = state["messages"][-1]
        tool_messages = []
        for call in getattr(last, "tool_calls", []) or []:
            if call.get("name") != rag_tool.name:
                continue
            result = rag_tool.invoke(call.get("args") or {})
            tool_messages.append(
                ToolMessage(
                    content=str(result),
                    name=rag_tool.name,
                    tool_call_id=str(call.get("id") or rag_tool.name),
                )
            )
        return {"messages": tool_messages}

    def route_after_model(state: AgentState) -> str:
        last = state["messages"][-1]
        local_calls = [
            call for call in getattr(last, "tool_calls", []) or []
            if call.get("name") == rag_tool.name
        ]
        return "tools" if local_calls else END

    graph = StateGraph(AgentState)
    graph.add_node("model", call_model)
    graph.add_node("tools", call_local_tools)
    graph.set_entry_point("model")
    graph.add_conditional_edges("model", route_after_model, {"tools": "tools", END: END})
    graph.add_edge("tools", "model")
    app = graph.compile()

    rag_system_prompt = (
        f"{SYSTEM_PROMPT} "
        "You have a local LangGraph tool named search_rag_source. "
        "For any question about runbooks, troubleshooting steps, operational procedures, SOPs, policies, incidents, uploaded documents, or user-specific knowledge, call search_rag_source before answering. "
        "Do not answer those questions from general knowledge until you have used search_rag_source and considered its result. "
        "Use MCP tools only for live OCI resource discovery or operations."
    )
    messages = [SystemMessage(content=rag_system_prompt), *_messages_from_history([], text)]
    result = app.invoke({"messages": messages})
    output_messages = result.get("messages", [])
    reply = ""
    for message in reversed(output_messages):
        raw_content = getattr(message, "content", "") or ""
        content = _message_content_to_text(raw_content)
        if content.strip() and message.__class__.__name__ == "AIMessage":
            reply = content.strip()
            break

    trace = _extract_trace(output_messages, len(tools), "LangGraph RAG + OCI MCP tools")
    trace.insert(0, f"RAG LangGraph tool available: {rag_tool.name} ({rag_vector_store_id})")
    return {
        "reply": reply or "Sorry, I did not get a valid response.",
        "trace": trace,
        "conversation_id": "",
    }


async def _run_agent(
    text: str,
    history: List[ChatMessage],
    allowed_tools: Optional[List[str]] = None,
    thread_id: str = "default",
    mcp_enabled: bool = True,
    mcp_servers: Optional[List[Dict[str, Any]]] = None,
    allowed_mcp_tools: Optional[Dict[str, List[str]]] = None,
    region: Optional[str] = None,
    compartment_id: Optional[str] = None,
    project_id: Optional[str] = None,
    model_id: Optional[str] = None,
    model_provider: Optional[str] = None,
    temperature: Optional[float] = None,
    top_p: Optional[float] = None,
    max_tokens: Optional[int] = None,
    conversation_id: Optional[str] = None,
    memory_subject_id: Optional[str] = None,
    memory_access_policy: Optional[str] = None,
    short_term_memory_optimization: Optional[str] = None,
    rag_enabled: bool = False,
    rag_vector_store_id: Optional[str] = None,
    rag_max_results: Optional[int] = 6,
) -> Dict[str, Any]:
    selected_project_id = project_id or OCI_GENAI_PROJECT_ID
    if rag_enabled and rag_vector_store_id:
        return _run_langgraph_tool_agent(
            text,
            history,
            mcp_enabled,
            mcp_servers,
            allowed_mcp_tools,
            allowed_tools,
            region,
            compartment_id,
            selected_project_id,
            model_id,
            temperature,
            top_p,
            max_tokens,
            rag_vector_store_id,
            rag_max_results,
        )

    client = _client(region, selected_project_id)
    conversation_id = _ensure_conversation(
        client,
        conversation_id,
        thread_id,
        memory_subject_id,
        memory_access_policy,
        short_term_memory_optimization,
    )
    tools = [
        *_mcp_tools(mcp_enabled, mcp_servers, allowed_mcp_tools, allowed_tools),
        *_rag_tools(rag_enabled, rag_vector_store_id, rag_max_results),
    ]
    response = client.responses.create(
        **_response_kwargs(text, model_id, temperature, top_p, max_tokens, conversation_id, tools)
    )
    reply = _response_text(response) or "Sorry, I did not get a valid response."
    return {
        "reply": reply,
        "trace": _trace_from_response(response, conversation_id, selected_project_id, tools),
        "conversation_id": conversation_id,
    }


async def _build_stream(
    text: str,
    history: List[ChatMessage],
    thread_id: str,
    allowed_tools: Optional[List[str]] = None,
    mcp_enabled: bool = True,
    mcp_servers: Optional[List[Dict[str, Any]]] = None,
    allowed_mcp_tools: Optional[Dict[str, List[str]]] = None,
    region: Optional[str] = None,
    compartment_id: Optional[str] = None,
    project_id: Optional[str] = None,
    model_id: Optional[str] = None,
    model_provider: Optional[str] = None,
    temperature: Optional[float] = None,
    top_p: Optional[float] = None,
    max_tokens: Optional[int] = None,
    conversation_id: Optional[str] = None,
    memory_subject_id: Optional[str] = None,
    memory_access_policy: Optional[str] = None,
    short_term_memory_optimization: Optional[str] = None,
    rag_enabled: bool = False,
    rag_vector_store_id: Optional[str] = None,
    rag_max_results: Optional[int] = 6,
):
    try:
        selected_project_id = project_id or OCI_GENAI_PROJECT_ID
        if rag_enabled and rag_vector_store_id:
            yield _sse("status", {"message": f"Using LangGraph RAG tool agent with {model_id or MODEL_ID}"})
            result = _run_langgraph_tool_agent(
                text,
                history,
                mcp_enabled,
                mcp_servers,
                allowed_mcp_tools,
                allowed_tools,
                region,
                compartment_id,
                selected_project_id,
                model_id,
                temperature,
                top_p,
                max_tokens,
                rag_vector_store_id,
                rag_max_results,
            )
            for line in result["trace"]:
                yield _sse("trace", {"line": line})
            yield _sse("delta", {"text": result["reply"]})
            yield _sse(
                "done",
                {
                    "reply": result["reply"],
                    "trace": result["trace"],
                    "thread_id": thread_id,
                    "conversation_id": conversation_id,
                    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
                },
            )
            return

        client = _client(region, selected_project_id)
        conversation_id = _ensure_conversation(
            client,
            conversation_id,
            thread_id,
            memory_subject_id,
            memory_access_policy,
            short_term_memory_optimization,
        )
        tools = [
            *_mcp_tools(mcp_enabled, mcp_servers, allowed_mcp_tools, allowed_tools),
            *_rag_tools(rag_enabled, rag_vector_store_id, rag_max_results),
        ]
        yield _sse(
            "conversation",
            {
                "conversation_id": conversation_id,
                "project_id": selected_project_id,
                "memory_subject_id": memory_subject_id or OCI_GENAI_MEMORY_SUBJECT_ID,
            },
        )
        yield _sse("status", {"message": f"Using OCI Enterprise AI Responses API with {model_id or MODEL_ID}"})
        if rag_enabled and rag_vector_store_id:
            yield _sse("trace", {"line": f"RAG file_search tool enabled for vector store {rag_vector_store_id}"})
        yield _sse(
            "tools",
            {
                "servers": [server.get("name") for server in mcp_servers or [] if server.get("enabled", True)],
                "tool_count": sum(len(item.get("allowed_tools", [])) for item in tools) if mcp_enabled else 0,
                "rag_enabled": bool(rag_enabled and rag_vector_store_id),
                "rag_vector_store_id": rag_vector_store_id,
                "tools": allowed_mcp_tools or allowed_tools or [],
                "enabled": mcp_enabled,
            },
        )

        stream = client.responses.create(
            **{
                **_response_kwargs(text, model_id, temperature, top_p, max_tokens, conversation_id, tools),
                "stream": True,
            }
        )

        final_reply = ""
        trace_items = [
            f"OCI Enterprise AI project: {selected_project_id}",
            f"Conversation: {conversation_id}",
            f"Memory subject: {memory_subject_id or OCI_GENAI_MEMORY_SUBJECT_ID or 'project default'}",
            f"Memory access policy: {memory_access_policy or OCI_GENAI_MEMORY_ACCESS_POLICY}",
            f"RAG file_search tool: {'enabled' if rag_enabled and rag_vector_store_id else 'disabled'}",
        ]

        for event in stream:
            event_type = getattr(event, "type", "")
            if event_type == "response.output_text.delta":
                delta = getattr(event, "delta", "") or ""
                final_reply += delta
                yield _sse("delta", {"text": delta})
            elif event_type == "response.mcp_list_tools.completed":
                trace_text = "MCP tools imported by OCI Enterprise AI"
                trace_items.append(trace_text)
                yield _sse("trace", {"line": trace_text})
            elif event_type in {"response.mcp_call.in_progress", "response.mcp_call.completed", "response.mcp_call.failed"}:
                item = getattr(event, "item", None)
                tool_name = getattr(item, "name", "MCP tool")
                trace_text = f"{event_type}: {tool_name}"
                trace_items.append(trace_text)
                yield _sse("trace", {"line": trace_text})
            elif "file_search" in event_type:
                trace_text = f"RAG {event_type}"
                trace_items.append(trace_text)
                yield _sse("trace", {"line": trace_text})
            elif event_type == "response.completed":
                response = getattr(event, "response", None)
                if response is not None:
                    final_reply = _response_text(response) or final_reply
                    trace_items = _trace_from_response(response, conversation_id, selected_project_id, tools) or trace_items
            elif event_type == "response.failed":
                response = getattr(event, "response", None)
                error = getattr(response, "error", None)
                raise RuntimeError(str(_json_safe(error) if error else "OCI Enterprise AI response failed"))

        if not final_reply:
            final_reply = "Sorry, I did not get a valid response."

        yield _sse(
            "done",
            {
                "reply": final_reply,
                "trace": trace_items,
                "thread_id": thread_id,
                "conversation_id": conversation_id,
                "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            },
        )
    except Exception as exc:
        logger.exception("Streaming chat failed")
        yield _sse("error", {"message": str(exc)})
