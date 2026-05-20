# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
#!/usr/bin/env python3

from __future__ import annotations

import contextlib

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any, Dict, List, Literal, Optional, TypedDict, Annotated

import oci
from dotenv import load_dotenv

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

from langchain_oci import ChatOCIGenAI
from langgraph.prebuilt import create_react_agent
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from langchain_mcp_adapters.tools import load_mcp_tools

import operator
from typing import Any, Annotated, Dict, List, Literal, Optional, TypedDict
from langchain_core.messages import AIMessage, AnyMessage, HumanMessage, SystemMessage, ToolMessage
from langgraph.graph import END, START, StateGraph


load_dotenv()
# ---------------------------------------------------------------------------
# Environment + Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level="DEBUG",
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
logging.basicConfig(level="DEBUG")
logger = logging.getLogger("oci_agent_mvp")

MCP_SERVER_URL = os.getenv("MCP_SERVER_URL")
OCI_GENAI_ENDPOINT = os.getenv("OCI_GENAI_ENDPOINT")
COMPARTMENT_ID = os.getenv("COMPARTMENT_ID")
MODEL_ID = os.getenv("MODEL_ID")
AUTH_TYPE = "RESOURCE_PRINCIPAL"

if not COMPARTMENT_ID:
    logger.warning("COMPARTMENT_ID is not set. OCI GenAI calls will fail until it is configured.")

# ---------------------------------------------------------------------------
# LLM
# ---------------------------------------------------------------------------
grok_model = ChatOCIGenAI(
    model_id=MODEL_ID,
    service_endpoint=OCI_GENAI_ENDPOINT,
    compartment_id=COMPARTMENT_ID,
    provider="meta",
    model_kwargs={
        "temperature": float("0.5"),
        "max_tokens": int("16000"),
        "top_p": float("0.7"),
    },
    auth_type=AUTH_TYPE,
)


# ---------------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------------
SYSTEM_PROMPT = (
    "You are a helpful OCI DevOps assistant. Write naturally, clearly, and concisely. "
    "Use tools only when they are needed to answer an OCI-related question, inspect live OCI data, or perform an OCI operation. "
    "For general conversation, greetings, explanations, and questions that do not require live OCI data, answer directly without tools. "
    "If the user's request is unclear, incomplete, or ambiguous, ask one brief clarifying question before taking action. "
    "When tools are needed, choose the smallest useful set of tools, use them in a sensible order, and wait for each result before continuing. "
    "You do not need to ask for user credentials or configuration details; assume all necessary credentials are already part of the MCP Server configuration."
    "All the necessary permissions and configurations are in place. "
    "Use structured tool calls only; do not print tool calls in the response. "
    "Do not invent compartments, instances, images, shapes, or other OCI resources. "
    "If a tool returns an error, inspect the failure, correct the parameters if possible, and retry once or explain the problem clearly. "
    "Use rag_instructions only for runbook, remediation, or VM action guidance when such guidance is actually needed. "
    "If the information cannot be determined from the tools or the available context, say so plainly instead of guessing. "
    "Give the final answer in plain English, and include relevant results without unnecessary repetition."
)


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("OCI agent MVP starting")
    yield
    logger.info("OCI agent MVP shutting down")


app = FastAPI(lifespan=lifespan)


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------
class ChatMessage(BaseModel):
    role: Literal["user", "assistant"] = Field(...)
    content: str = Field(..., min_length=1)


class ChatInput(BaseModel):
    text: str = Field(..., min_length=1)
    thread_id: str = Field(default="default")
    history: List[ChatMessage] = Field(default_factory=list)
    allowed_tools: Optional[List[str]] = None


class ChatOutput(BaseModel):
    reply: str
    trace: List[str]
    thread_id: str
    timestamp_utc: str


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
class AgentState(TypedDict, total=False):
    messages: Annotated[List[AnyMessage], operator.add]
    tool_rounds: int


def _json_safe(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(k): _json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_safe(v) for v in value]
    if hasattr(value, "model_dump"):
        return _json_safe(value.model_dump())
    if hasattr(value, "__dict__"):
        return _json_safe(vars(value))
    return str(value)


async def summarize_tool_output(text: str, _model=None) -> str:
    if not text:
        return ""
    if len(text) <= 1000:
        return text
    logger.info("Truncating long tool output...")
    return text[:700] + "\n...[truncated output]..."


def _messages_from_history(history: List[ChatMessage], current_text: str) -> List[AnyMessage]:
    messages: List[AnyMessage] = []
    for item in history:
        if item.role == "user":
            messages.append(HumanMessage(content=item.content))
        elif item.role == "assistant":
            messages.append(AIMessage(content=item.content))
    messages.append(HumanMessage(content=current_text))
    return messages


def _normalize_allowed_tools(allowed_tools: Optional[List[str]]) -> Optional[set[str]]:
    if allowed_tools is None:
        return None
    normalized = {str(name).strip() for name in allowed_tools if str(name).strip()}
    return normalized


def _filter_tools(tools: List[Any], allowed_tools: Optional[List[str]] = None) -> List[Any]:
    requested_tools = _normalize_allowed_tools(allowed_tools)
    if requested_tools is None:
        filtered = list(tools)
        logger.info("No tool subset supplied; enabling all loaded MCP tools")
    else:
        filtered = [tool for tool in tools if getattr(tool, "name", None) in requested_tools]
        logger.info("Filtered to %d user-enabled MCP tools", len(filtered))
    logger.info(
        "Requested tool subset: %s",
        sorted(requested_tools) if requested_tools is not None else "all",
    )
    logger.info("Tools passed to agent: %s", [getattr(t, "name", "unknown") for t in filtered])
    return filtered


def _tool_result_to_text(result: Any) -> str:
    if result is None:
        return ""
    if isinstance(result, str):
        text = result
    else:
        text = json.dumps(_json_safe(result), ensure_ascii=False, indent=2)

    text = text.strip()
    if len(text) > 6000:
        return text[:5600] + "\n...[truncated tool output]..."
    return text


def _extract_trace(messages: List[AnyMessage], tool_count: int, mcp_url: str) -> List[str]:
    trace: List[str] = [
        f"Opened MCP session to {mcp_url}",
        "Initialized MCP session",
        f"Loaded {tool_count} MCP tools",
        "Built LangGraph planner node",
        "Built LangGraph tool-result chaining loop",
        "Invoked agent graph",
    ]

    for msg in messages:
        name = msg.__class__.__name__
        content = getattr(msg, "content", "") or ""
        if name == "ToolMessage":
            tool_name = getattr(msg, "name", "unknown_tool")
            trace.append(f"Tool result from {tool_name}: {content[:800]}")
        elif name == "AIMessage" and content.strip():
            tool_calls = getattr(msg, "tool_calls", None) or []
            if tool_calls:
                call_names = ", ".join(str(call.get("name", "unknown")) for call in tool_calls)
                trace.append(f"Planner requested tool call(s): {call_names}")
            else:
                trace.append(f"Assistant message: {content[:800]}")
    return trace


async def _clarification_check(text: str, history: List[ChatMessage]):
    recent = history[-6:]
    history_text = "\n".join(f"{item.role}: {item.content}" for item in recent)

    prompt = [
        SystemMessage(
            content=(
                "Decide if the user request needs clarification. Reply strictly with:\n"
                "NO\n"
                "or\n"
                "YES: <short question>"
            )
        ),
        HumanMessage(content=f"{history_text}\n\nUser: {text}"),
    ]

    resp = await grok_model.ainvoke(prompt)
    content = (getattr(resp, "content", "") or "").strip()

    if content.upper().startswith("YES:"):
        return True, content[4:].strip()

    return False, None


async def _load_mcp_server_tools(allowed_tools: Optional[List[str]] = None) -> List[Any]:
    logger.info("Opening MCP session to %s", MCP_SERVER_URL)
    async with streamablehttp_client(url=MCP_SERVER_URL) as (reader, writer, _):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            logger.info("MCP session initialized")
            tools = await load_mcp_tools(session)
            return _filter_tools(tools, allowed_tools=allowed_tools)


def _build_langgraph_agent(tools: List[Any]):
    tools_by_name = {
        getattr(tool, "name", None): tool for tool in tools if getattr(tool, "name", None)
    }

    try:
        model_with_tools = grok_model.bind_tools(tools)
    except Exception as exc:
        raise RuntimeError(
            f"Model does not support tool binding for the loaded MCP tools: {exc}"
        ) from exc

    async def planner(state: AgentState) -> Dict[str, Any]:
        prompt_messages = [SystemMessage(content=SYSTEM_PROMPT)] + list(state.get("messages", []))
        ai_message = await model_with_tools.ainvoke(prompt_messages)
        return {"messages": [ai_message]}

    async def tool_executor(state: AgentState) -> Dict[str, Any]:
        last_message = state["messages"][-1]
        tool_calls = getattr(last_message, "tool_calls", None) or []
        results: List[ToolMessage] = []

        for index, tool_call in enumerate(tool_calls):
            tool_name = tool_call.get("name", "unknown_tool")
            tool = tools_by_name.get(tool_name)
            tool_call_id = tool_call.get("id") or tool_call.get("tool_call_id") or f"{tool_name}-{index}"
            raw_args = tool_call.get("args") or tool_call.get("arguments") or {}
            args = raw_args if isinstance(raw_args, dict) else {"input": raw_args}

            if tool is None:
                results.append(
                    ToolMessage(
                        content=f"Tool '{tool_name}' is not available.",
                        tool_call_id=tool_call_id,
                        name=tool_name,
                    )
                )
                continue

            try:
                if hasattr(tool, "ainvoke"):
                    output = await tool.ainvoke(args)
                else:
                    output = tool.invoke(args)
                results.append(
                    ToolMessage(
                        content=_tool_result_to_text(output),
                        tool_call_id=tool_call_id,
                        name=tool_name,
                    )
                )
            except Exception as exc:
                logger.exception("Tool %s failed", tool_name)
                results.append(
                    ToolMessage(
                        content=f"Tool '{tool_name}' failed: {exc}",
                        tool_call_id=tool_call_id,
                        name=tool_name,
                    )
                )

        return {"messages": results, "tool_rounds": state.get("tool_rounds", 0) + 1}

    def should_continue(state: AgentState):
        if state.get("tool_rounds", 0) >= 6:
            return END
        last_message = state["messages"][-1]
        tool_calls = getattr(last_message, "tool_calls", None) or []
        return "tool_executor" if tool_calls else END

    builder = StateGraph(AgentState)
    builder.add_node("planner", planner)
    builder.add_node("tool_executor", tool_executor)
    builder.add_edge(START, "planner")
    builder.add_conditional_edges(
        "planner",
        should_continue,
        {"tool_executor": "tool_executor", END: END},
    )
    builder.add_edge("tool_executor", "planner")
    return builder.compile()


async def _run_agent(
    text: str,
    history: List[ChatMessage],
    allowed_tools: Optional[List[str]] = None,
    thread_id: str = "default",
) -> Dict[str, Any]:
    needs_clarification, question = await _clarification_check(text, history)
    if needs_clarification:
        return {
            "reply": question or "Could you clarify your request?",
            "trace": [
                "HITL gate: clarification needed",
                f"Clarifying question: {question}",
            ],
        }

    tools = await _load_mcp_server_tools(allowed_tools=allowed_tools)
    graph = _build_langgraph_agent(tools)
    logger.info("LangGraph planner graph created")

    conversation_messages = _messages_from_history(history, text)
    response = await graph.ainvoke(
        {"messages": conversation_messages, "tool_rounds": 0},
        config={"configurable": {"thread_id": thread_id}, "recursion_limit": 24},
    )

    messages = response.get("messages", []) if isinstance(response, dict) else response
    ai_msgs = [m for m in messages if m.__class__.__name__ == "AIMessage"]
    tool_msgs = [m for m in messages if m.__class__.__name__ == "ToolMessage"]

    if ai_msgs and getattr(ai_msgs[-1], "content", "").strip() and not getattr(ai_msgs[-1], "tool_calls", None):
        final_reply = ai_msgs[-1].content
    elif tool_msgs:
        tool_output = getattr(tool_msgs[-1], "content", "")
        final_reply = await summarize_tool_output(tool_output, grok_model)
    else:
        final_reply = "Sorry, I did not get a valid response."

    trace = _extract_trace(messages, len(tools), MCP_SERVER_URL)
    return {"reply": final_reply, "trace": trace}


def _sse(event: str, data: Any) -> str:
    payload = json.dumps(_json_safe(data), ensure_ascii=False)
    return f"event: {event}\ndata: {payload}\n\n"


async def _build_stream(
    text: str,
    history: List[ChatMessage],
    thread_id: str,
    allowed_tools: Optional[List[str]] = None,
):
    try:
        needs_clarification, question = await _clarification_check(text, history)

        if needs_clarification:
            question = question or "Could you clarify your request?"
            yield _sse("trace", {"line": "HITL gate: clarification needed"})
            yield _sse("trace", {"line": f"Clarifying question: {question}"})
            yield _sse(
                "done",
                {
                    "reply": question,
                    "needs_clarification": True,
                    "trace": [
                        "HITL gate: clarification needed",
                        f"Clarifying question: {question}",
                    ],
                    "thread_id": thread_id,
                    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
                },
            )
            return

        yield _sse("status", {"message": "Opening MCP session", "server": MCP_SERVER_URL})

        async with streamablehttp_client(url=MCP_SERVER_URL) as (reader, writer, _):
            async with ClientSession(reader, writer) as session:
                await session.initialize()
                yield _sse("status", {"message": "MCP session initialized"})

                tools = await load_mcp_tools(session)
                tools = _filter_tools(tools, allowed_tools=allowed_tools)
                yield _sse(
                    "tools",
                    {
                        "server": MCP_SERVER_URL,
                        "tool_count": len(tools),
                        "tools": [getattr(t, "name", "unknown") for t in tools],
                    },
                )

                graph = _build_langgraph_agent(tools)
                yield _sse("status", {"message": "LangGraph planner graph created"})

                conversation_messages = _messages_from_history(history, text)
                config = {"configurable": {"thread_id": thread_id}, "recursion_limit": 24}

                final_reply = ""
                trace_items: List[str] = []

                async for event in graph.astream_events(
                    {"messages": conversation_messages, "tool_rounds": 0},
                    config=config,
                    version="v2",
                ):
                    event_name = event.get("event", "")
                    event_data = event.get("data", {})
                    event_type = event.get("name", "") or event_name

                    if event_name == "on_chat_model_stream":
                        chunk = event_data.get("chunk")
                        content = getattr(chunk, "content", None)
                        if isinstance(content, str) and content:
                            final_reply += content
                            yield _sse("delta", {"text": content})
                    elif event_name == "on_tool_start":
                        tool_name = event.get("name", "tool")
                        tool_input = event_data.get("input") or event_data.get("arguments") or {}
                        trace_text = (
                            f"Tool start: {tool_name} | input: "
                            f"{json.dumps(_json_safe(tool_input), ensure_ascii=False)[:1200]}"
                        )
                        trace_items.append(trace_text)
                        yield _sse("trace", {"line": trace_text})
                    elif event_name == "on_tool_end":
                        tool_name = event.get("name", "tool")
                        output = event_data.get("output")
                        trace_text = (
                            f"Tool end: {tool_name} | output: "
                            f"{json.dumps(_json_safe(output), ensure_ascii=False)[:1200]}"
                        )
                        trace_items.append(trace_text)
                        yield _sse("trace", {"line": trace_text})
                    elif event_name in {"on_chain_start", "on_chain_end"}:
                        trace_text = f"{event_name}: {event_type}"
                        trace_items.append(trace_text)
                        yield _sse("trace", {"line": trace_text})

                if not final_reply:
                    final_reply = "Sorry, I did not get a valid response."

                yield _sse(
                    "done",
                    {
                        "reply": final_reply,
                        "trace": trace_items,
                        "thread_id": thread_id,
                        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
                    },
                )
    except Exception as exc:
        logger.exception("Streaming chat failed")
        yield _sse("error", {"message": str(exc)})


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/healthz")
async def healthz():
    return {"status": "ok", "service": "oci-agent-mvp"}


@app.get("/api/mcp-info")
async def mcp_info():
    try:
        async with streamablehttp_client(url=MCP_SERVER_URL) as (reader, writer, _):
            async with ClientSession(reader, writer) as session:
                await session.initialize()
                tools = await load_mcp_tools(session)
                tools = _filter_tools(tools)

                server_info = {
                    "name": "primary-mcp-server",
                    "url": MCP_SERVER_URL,
                    "tool_count": len(tools),
                    "tools": [],
                }

                for tool in tools:
                    schema = getattr(tool, "args_schema", {}) or {}
                    properties = {}
                    required = []
                    if isinstance(schema, dict):
                        properties = schema.get("properties", {}) or {}
                        required = schema.get("required", []) or []

                    params = []
                    for param_name, param_schema in properties.items():
                        params.append(
                            {
                                "name": param_name,
                                "type": param_schema.get("type", "unknown"),
                                "required": param_name in required,
                                "description": param_schema.get("description", ""),
                                "default": param_schema.get("default"),
                                "enum": param_schema.get("enum"),
                            }
                        )

                    server_info["tools"].append(
                        {
                            "name": getattr(tool, "name", "unknown"),
                            "description": getattr(tool, "description", "") or "",
                            "parameters": params,
                            "raw_schema": _json_safe(schema),
                        }
                    )

                return {"status": "success", "servers": [server_info]}
    except Exception as exc:
        logger.exception("Failed to load MCP info")
        return JSONResponse(status_code=500, content={"status": "error", "message": str(exc)})


@app.post("/api/chat")
async def chat_endpoint(input: ChatInput):
    try:
        result = await _run_agent(input.text, input.history, input.allowed_tools, input.thread_id)
        return ChatOutput(
            reply=result["reply"],
            trace=result["trace"],
            thread_id=input.thread_id,
            timestamp_utc=datetime.now(timezone.utc).isoformat(),
        )
    except Exception as exc:
        logger.exception("Error during chat invocation")
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/api/chat/stream")
async def chat_stream_endpoint(input: ChatInput):
    return StreamingResponse(
        _build_stream(input.text, input.history, input.thread_id, input.allowed_tools),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.get("/", response_class=HTMLResponse)
async def index():
    return HTMLResponse(INDEX_HTML)


# ---------------------------------------------------------------------------
# HTML UI
# ---------------------------------------------------------------------------
INDEX_HTML = r"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>OCI Agent MVP</title>
  <style>
    :root {
      --bg: #0b1020;
      --panel: #121a31;
      --panel-2: #0f1730;
      --text: #e7ecff;
      --muted: #9aa7d6;
      --border: #253055;
      --accent: #6ea8fe;
      --accent-2: #8b5cf6;
      --user: #22324f;
      --assistant: #162846;
      --trace: #0d2033;
      --danger: #ff7b7b;
      --ok: #4ade80;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: radial-gradient(circle at top, #111838 0%, var(--bg) 55%);
      color: var(--text);
      height: 100vh;
      overflow: auto;
    }

    .shell {
      width: 100%;
      height: 100dvh;
      min-height: 0;
      margin: 0 auto;
      padding: 10px;
      display: grid;
      grid-template-columns: minmax(0, 1.8fr) minmax(340px, 1fr);
      grid-template-rows: auto minmax(0, 1fr);
      grid-template-areas:
        "header header"
        "chat side";
      gap: 14px;
      align-items: stretch;
      overflow: auto;
    }

    .header {
      grid-area: header;
      background: linear-gradient(135deg, rgba(110,168,254,0.15), rgba(139,92,246,0.12));
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 10px 12px;
      backdrop-filter: blur(10px);
      display: flex;
      justify-content: space-between;
      gap: 16px;
      align-items: center;
    }

    .header h1 { margin: 0; font-size: 18px; }
    .header p { margin: 4px 0 0; color: var(--muted); font-size: 11px; }

    .badge {
      border: 1px solid var(--border);
      background: rgba(255,255,255,0.03);
      padding: 5px 8px;
      border-radius: 999px;
      font-size: 12px;
      color: var(--muted);
      white-space: nowrap;
    }

    .card {
      background: rgba(10, 15, 33, 0.82);
      border: 1px solid var(--border);
      border-radius: 14px;
      box-shadow: 0 12px 32px rgba(0,0,0,0.22);
      overflow: auto;
      min-width: 0;
      min-height: 0;
      display: flex;
      flex-direction: column;
    }

    .card-header {
      padding: 10px 12px;
      border-bottom: 1px solid var(--border);
      background: rgba(255,255,255,0.02);
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 8px;
      cursor: pointer;
      list-style: none;
    }

    .card-header::-webkit-details-marker {
      display: none;
    }

    .card-title {
      display: flex;
      flex-direction: column;
      gap: 2px;
      min-width: 0;
    }

    .card-title h2 {
      margin: 0;
      font-size: 13px;
    }

    .card-title span {
      color: var(--muted);
      font-size: 11px;
    }

    .card-chevron {
      color: var(--muted);
      transition: transform 0.2s ease;
      flex: none;
    }

    details.card:not([open]) > .card-header .card-chevron {
      transform: rotate(-90deg);
    }

    .card-body {
      padding: 10px;
      flex: 1 1 auto;
      min-height: 0;
      min-width: 0;
      display: flex;
      flex-direction: column;
      overflow-y: auto;
      overflow-x: auto;
    }

    .chat {
      grid-area: chat;
      display: flex;
      flex-direction: column;
      min-height: 0;
      overflow: auto;
    }

    .messages {
      flex: 1 1 auto;
      min-height: 0;
      min-width: 0;
      overflow-y: auto;
      overflow-x: hidden;
      overscroll-behavior: contain;
      display: flex;
      flex-direction: column;
      gap: 10px;
      padding-right: 6px;
      scrollbar-gutter: stable;
      max-height: none;
    }

    .msg {
      max-width: 88%;
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 10px 12px;
      line-height: 1.35;
      white-space: pre-wrap;
      word-wrap: break-word;
    }

    .msg.user {
      align-self: flex-end;
      background: var(--user);
    }

    .msg.assistant {
      align-self: flex-start;
      background: var(--assistant);
    }

    .msg.meta {
      align-self: center;
      max-width: 100%;
      background: rgba(255,255,255,0.03);
      color: var(--muted);
      font-size: 12px;
      padding: 5px 8px;
      border-style: dashed;
    }

    .chat-input {
      position: relative;
      margin-top: 8px;
      padding: 10px;
      border-top: 1px solid var(--border);
      background: linear-gradient(180deg, rgba(10, 15, 33, 0.2), rgba(10, 15, 33, 0.95));
      backdrop-filter: blur(10px);
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 8px;
      align-items: end;
      flex: none;
    }

    textarea {
      width: 100%;
      min-height: 96px;
      height: 96px;
      resize: none;
      border-radius: 14px;
      border: 1px solid var(--border);
      background: var(--panel-2);
      color: var(--text);
      padding: 12px;
      font: inherit;
      line-height: 1.4;
      outline: none;
    }

    textarea:focus { border-color: var(--accent); }

    .button-col {
      display: flex;
      flex-direction: column;
      gap: 8px;
    }

    button {
      border: none;
      border-radius: 14px;
      background: linear-gradient(135deg, var(--accent), var(--accent-2));
      color: white;
      font-weight: 700;
      padding: 11px 14px;
      cursor: pointer;
      min-width: 100px;
    }

    button.secondary {
      background: rgba(255,255,255,0.08);
      color: var(--text);
      min-width: 100px;
    }

    button:disabled { opacity: 0.55; cursor: not-allowed; }

    .typing-indicator {
      display: flex;
      align-items: center;
      gap: 8px;
      color: var(--muted);
      font-size: 12px;
      padding: 8px 0 8px;
      min-height: 28px;
    }

    .typing-indicator.hidden { display: none; }

    .typing-dots {
      display: inline-flex;
      gap: 4px;
      align-items: center;
    }

    .typing-dots span {
      width: 6px;
      height: 6px;
      border-radius: 999px;
      background: var(--muted);
      opacity: 0.45;
      animation: typingPulse 1s infinite ease-in-out;
    }

    .typing-dots span:nth-child(2) { animation-delay: 0.15s; }
    .typing-dots span:nth-child(3) { animation-delay: 0.3s; }

    @keyframes typingPulse {
      0%, 80%, 100% { transform: translateY(0); opacity: 0.35; }
      40% { transform: translateY(-3px); opacity: 1; }
    }

    .side {
      grid-area: side;
      display: flex;
      flex-direction: column;
      gap: 14px;
      min-height: 0;
    }

    .side-panel {
      flex: 1 1 0;
      min-height: 0;
      display: flex;
      flex-direction: column;
    }

    .side-panel > .card-body {
      flex: 1 1 auto;
      min-height: 0;
      overflow-x: auto;
      overflow-y: auto;
    }

    .side-panel:not([open]) {
      flex: 0 0 auto;
    }

    .panel {
      min-height: 0;
      width: 100%;
      flex: 1 1 auto;
      overflow-y: auto;
      overflow-x: hidden;
      scrollbar-gutter: stable;
      background: var(--trace);
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 12px;
      white-space: pre-wrap;
      line-height: 1.45;
      font-size: 13px;
    }

    .panel.empty {
      color: var(--muted);
      display: flex;
      align-items: center;
      justify-content: center;
      text-align: center;
    }

    .card-body > .small {
      flex: 0 0 auto;
    }

    .row {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
    }

    .pill {
      font-size: 12px;
      border-radius: 999px;
      padding: 5px 8px;
      border: 1px solid var(--border);
      color: var(--muted);
      background: rgba(255,255,255,0.03);
    }

    .server-card {
      border: 1px solid var(--border);
      background: rgba(255,255,255,0.02);
      border-radius: 14px;
      margin-bottom: 8px;
      overflow: auto;
    }

    .server-card > summary {
      list-style: none;
      cursor: pointer;
      padding: 10px;
      display: flex;
      justify-content: space-between;
      gap: 8px;
      align-items: center;
    }

    .server-card > summary::-webkit-details-marker {
      display: none;
    }

    .server-summary-left {
      min-width: 0;
      flex: 1;
    }

    .server-summary-left strong {
      display: block;
      font-size: 12px;
      margin-bottom: 2px;
    }

    .server-url {
      color: var(--muted);
      font-size: 12px;
      word-break: break-all;
    }

    .server-body {
      padding: 0 10px 10px;
      display: flex;
      flex-direction: column;
      gap: 10px;
      min-height: 0;
    }
    .tool {
      border-top: 1px solid rgba(255,255,255,0.06);
      margin-top: 4px;
      padding-top: 4px;
      overflow: hidden;
    }

    .tool > summary {
      list-style: none;
      cursor: pointer;
      display: flex;
      justify-content: space-between;
      gap: 10px;
      align-items: center;
    }

    .tool > summary::-webkit-details-marker {
      display: none;
    }

    .tool-summary-wrap {
      display: flex;
      justify-content: space-between;
      gap: 4px;
      width: 100%;
      align-items: center;
    }

    .tool-summary-left {
      min-width: 0;
      flex: 1;
    }

    .tool-header-row {
      display: flex;
      justify-content: space-between;
      gap: 4px;
      align-items: center;
    }

    .tool-header-row h4 {
      margin: 0;
      font-size: 12px;
    }

    .tool-meta {
      display: block;
      margin-top: 2px;
      color: var(--muted);
      font-size: 11px;
    }

    .tool-state {
      font-size: 11px;
      padding: 3px 7px;
      border-radius: 999px;
      border: 1px solid var(--border);
      white-space: nowrap;
    }

    .tool-state.on { color: var(--ok); }
    .tool-state.off { color: var(--danger); }

    .tool-switch {
      position: relative;
      display: inline-flex;
      align-items: center;
      width: 42px;
      height: 24px;
      flex: none;
      cursor: pointer;
      user-select: none;
    }

    .tool-switch input {
      position: absolute;
      opacity: 0;
      pointer-events: none;
      width: 0;
      height: 0;
    }

    .tool-switch-track {
      position: absolute;
      inset: 0;
      border-radius: 999px;
      background: rgba(255,255,255,0.10);
      border: 1px solid var(--border);
      transition: background 0.2s ease, border-color 0.2s ease;
    }

    .tool-switch-thumb {
      position: absolute;
      top: 2px;
      left: 2px;
      width: 18px;
      height: 18px;
      border-radius: 50%;
      background: var(--text);
      box-shadow: 0 2px 8px rgba(0,0,0,0.25);
      transition: transform 0.2s ease, background 0.2s ease;
    }

    .tool-switch input:checked + .tool-switch-track {
      background: rgba(74,222,128,0.20);
      border-color: rgba(74,222,128,0.45);
    }

    .tool-switch input:checked + .tool-switch-track .tool-switch-thumb {
      transform: translateX(18px);
      background: #dff8e7;
    }

    .tool-body {
      padding-top: 8px;
      display: flex;
      flex-direction: column;
      gap: 8px;
      min-height: 0;
    }
    .tool-body p {
      margin: 0 0 8px;
      color: var(--muted);
      font-size: 12px;
    }

    .small {
      color: var(--muted);
      font-size: 12px;
    }

    .param-list {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 8px;
    }

    .param {
      border: 1px solid var(--border);
      background: rgba(255,255,255,0.03);
      border-radius: 999px;
      padding: 4px 8px;
      font-size: 11px;
      color: var(--text);
    }

    .param.req {
      border-color: rgba(74,222,128,0.45);
    }

    .param.opt {
      border-color: rgba(110,168,254,0.45);
    }

    @media (max-width: 1280px) {
      body { overflow: auto; }
      .shell {
        grid-template-columns: 1fr;
        grid-template-rows: auto auto auto;
        grid-template-areas:
          "header"
          "chat"
          "side";
        height: auto;
        overflow: visible;
      }

      .side {
        display: flex;
        flex-direction: column;
      }
    }
  </style>
</head>
<body>
  <div class="shell">
    <div class="header">
      <div>
        <h1>OCI Agent MVP</h1>
        <p>FastAPI + LangGraph + MCP + OCI GenAI, packaged for a single OCI Container Instance.</p>
      </div>
      <div class="badge" id="sessionBadge">thread: loading...</div>
    </div>

    <div class="card chat">
      <div class="card-header">
        <div class="card-title">
          <h2>Chat</h2>
          <span>Ask about OCI or any connected MCP tool</span>
        </div>
        <span class="card-chevron">▾</span>
      </div>
      <div class="card-body">
        <div id="typingIndicator" class="typing-indicator hidden">Assistant is typing<span class="typing-dots"><span></span><span></span><span></span></span></div>
        <div id="messages" class="messages"></div>

        <div class="chat-input">
          <textarea id="input" placeholder="Ask about OCI, instances, compartments, or anything the MCP tools can handle..."></textarea>
          <div class="button-col">
            <button id="sendBtn">Send</button>
            <button id="newChatBtn" class="secondary" type="button">New Chat</button>
          </div>
        </div>
      </div>
    </div>

    <div class="side">
      <details class="card side-panel" open id="serversPanel">
        <summary class="card-header">
          <div class="card-title">
            <h2>Connected MCP Servers</h2>
            <span>tools + toggles</span>
          </div>
          <span class="card-chevron">▾</span>
        </summary>
        <div class="card-body">
          <div id="serversOutput" class="panel empty">Loading connected servers and tools...</div>
        </div>
      </details>

      <details class="card side-panel" open id="tracePanel">
        <summary class="card-header">
          <div class="card-title">
            <h2>Execution Trace</h2>
            <span>live tool flow</span>
          </div>
          <span class="card-chevron">▾</span>
        </summary>
        <div class="card-body">
          <div id="traceOutput" class="panel empty">Tool activity and model-visible steps will appear here.</div>
          <div class="small" style="margin-top:10px;">Note: this panel shows a visible execution trace, not private chain-of-thought.</div>
        </div>
      </details>

      <details class="card side-panel" open id="agentPanel">
        <summary class="card-header">
          <div class="card-title">
            <h2>Agent Output</h2>
            <span>latest response</span>
          </div>
          <span class="card-chevron">▾</span>
        </summary>
        <div class="card-body">
          <div id="agentOutput" class="panel empty">The assistant reply will appear here.</div>
        </div>
      </details>
    </div>
  </div>

  <script>
    const input = document.getElementById("input");
    const sendBtn = document.getElementById("sendBtn");
    const newChatBtn = document.getElementById("newChatBtn");
    const messagesEl = document.getElementById("messages");
    const agentOutputEl = document.getElementById("agentOutput");
    const traceOutputEl = document.getElementById("traceOutput");
    const typingIndicator = document.getElementById("typingIndicator");
    const serversOutputEl = document.getElementById("serversOutput");
    const sessionBadge = document.getElementById("sessionBadge");

    const threadKey = "oci-agent-thread-id";
    const historyKey = "oci-agent-history";
    const sidePanelStateKey = "oci-agent-side-panels";
    const disabledToolsKey = "oci-agent-disabled-tools";
    
    function generateThreadId() {
      if (window.crypto && typeof crypto.randomUUID === "function") {
        return crypto.randomUUID();
      }

      return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
        const r = Math.random() * 16 | 0;
        const v = c === "x" ? r : (r & 0x3) | 0x8;
        return v.toString(16);
      });
    }

    let threadId = localStorage.getItem(threadKey) || generateThreadId();
    localStorage.setItem(threadKey, threadId);
    sessionBadge.textContent = `thread: ${threadId}`;

    let history = JSON.parse(localStorage.getItem(historyKey) || "[]");
    let currentAssistantBubble = null;
    let traceLines = [];
    let availableToolNames = [];
    let disabledTools = loadDisabledToolsFromStorage();

    function loadDisabledToolsFromStorage() {
      const raw = localStorage.getItem(disabledToolsKey);
      if (raw === null) return new Set();
      try {
        const parsed = JSON.parse(raw);
        if (!Array.isArray(parsed)) return new Set();
        return new Set(parsed.map((name) => String(name)));
      } catch {
        return new Set();
      }
    }

    function persistDisabledTools() {
      localStorage.setItem(disabledToolsKey, JSON.stringify(Array.from(disabledTools)));
    }

    function getEnabledToolNames() {
      return availableToolNames.filter((name) => !disabledTools.has(name));
    }

    function isToolEnabled(name) {
      return !disabledTools.has(name);
    }

    function setToolEnabled(name, enabled) {
      if (enabled) {
        disabledTools.delete(name);
      } else {
        disabledTools.add(name);
      }
      persistDisabledTools();
    }

    function loadPanelState() {
      try {
        const raw = localStorage.getItem(sidePanelStateKey);
        if (!raw) return {};
        const parsed = JSON.parse(raw);
        return parsed && typeof parsed === "object" ? parsed : {};
      } catch {
        return {};
      }
    }

    function persistPanelState(state) {
      localStorage.setItem(sidePanelStateKey, JSON.stringify(state));
    }

    const sidePanelState = loadPanelState();

    function bindPanelState(detailsEl, key, defaultOpen = true) {
      if (Object.prototype.hasOwnProperty.call(sidePanelState, key)) {
        detailsEl.open = Boolean(sidePanelState[key]);
      } else {
        detailsEl.open = defaultOpen;
        sidePanelState[key] = detailsEl.open;
        persistPanelState(sidePanelState);
      }
      detailsEl.addEventListener("toggle", () => {
        sidePanelState[key] = detailsEl.open;
        persistPanelState(sidePanelState);
      });
    }

    bindPanelState(document.getElementById("agentPanel"), "agentPanel", true);
    bindPanelState(document.getElementById("tracePanel"), "tracePanel", true);
    bindPanelState(document.getElementById("serversPanel"), "serversPanel", true);

    function saveHistory() {
      localStorage.setItem(historyKey, JSON.stringify(history));
    }

    function renderHistory() {
      messagesEl.innerHTML = "";
      if (history.length === 0) {
        messagesEl.innerHTML = '<div class="msg meta">Start a conversation to see messages here.</div>';
        return;
      }
      for (const item of history) {
        const div = document.createElement("div");
        div.className = `msg ${item.role}`;
        div.textContent = item.content;
        messagesEl.appendChild(div);
      }
      messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    function renderPanel(el, value, emptyText) {
      if (!value || (Array.isArray(value) && value.length === 0)) {
        el.classList.add("empty");
        el.textContent = emptyText;
        return;
      }
      el.classList.remove("empty");
      if (Array.isArray(value)) {
        el.textContent = value.map((x, i) => `${i + 1}. ${x}`).join("\n\n");
      } else {
        el.textContent = value;
      }
    }

    function setBusy(busy) {
      sendBtn.disabled = busy || input.value.trim().length === 0;
      newChatBtn.disabled = busy;
      input.disabled = busy;
      sendBtn.textContent = busy ? "Sending..." : "Send";
      typingIndicator.classList.toggle("hidden", !busy);
    }

    function updateSendState() {
      if (input.disabled) return;
      sendBtn.disabled = input.value.trim().length === 0;
    }

    function resizeTextarea() {
      input.style.height = "110px";
    }

    function addMessage(role, content) {
      history.push({ role, content });
      saveHistory();
      renderHistory();
    }

    function resetLivePanels() {
      agentOutputEl.classList.add("empty");
      agentOutputEl.textContent = "The assistant reply will appear here.";
      traceOutputEl.classList.add("empty");
      traceOutputEl.textContent = "Tool activity and model-visible steps will appear here.";
      traceLines = [];
      currentAssistantBubble = null;
    }

    function updateSessionBadge() {
      sessionBadge.textContent = `thread: ${threadId}`;
    }

    function startNewChat() {
      history = [];
      saveHistory();
      renderHistory();

      currentAssistantBubble = null;
      traceLines = [];
      input.value = "";
      input.style.height = "110px";

      const nextThreadId = generateThreadId();
      threadId = nextThreadId;
      localStorage.setItem(threadKey, threadId);
      updateSessionBadge();

      resetLivePanels();
      sendBtn.disabled = true;
      input.disabled = false;
      newChatBtn.disabled = false;
      typingIndicator.classList.add("hidden");
      input.focus();
    }

    function ensureAssistantBubble() {
      if (currentAssistantBubble) return currentAssistantBubble;
      currentAssistantBubble = document.createElement("div");
      currentAssistantBubble.className = "msg assistant";
      currentAssistantBubble.textContent = "";
      messagesEl.appendChild(currentAssistantBubble);
      messagesEl.scrollTop = messagesEl.scrollHeight;
      return currentAssistantBubble;
    }

    function appendTrace(line) {
      traceLines.push(line);
      traceOutputEl.classList.remove("empty");
      traceOutputEl.textContent = traceLines.map((x, i) => `${i + 1}. ${x}`).join("\n\n");
      traceOutputEl.scrollTop = traceOutputEl.scrollHeight;
    }

    function appendAssistantDelta(text) {
      const bubble = ensureAssistantBubble();
      bubble.textContent += text;
      messagesEl.scrollTop = messagesEl.scrollHeight;
      agentOutputEl.classList.remove("empty");
      agentOutputEl.textContent = bubble.textContent;
    }

    function finalizeAssistantMessage() {
      if (!currentAssistantBubble) return;
      const content = currentAssistantBubble.textContent.trim();
      if (content) {
        history.push({ role: "assistant", content });
        saveHistory();
      }
      currentAssistantBubble = null;
      renderHistory();
    }

    async function loadMcpServers() {
      try {
        const res = await fetch("/api/mcp-info");
        const data = await res.json();
        if (!res.ok || data.status !== "success") {
          throw new Error(data.message || "Failed to load MCP info");
        }

        const servers = data.servers || [];
        const toolNames = [];
        for (const server of servers) {
          for (const tool of server.tools || []) {
            if (tool && tool.name) {
              toolNames.push(String(tool.name));
            }
          }
        }
        availableToolNames = toolNames;
        disabledTools = new Set(Array.from(disabledTools).filter((name) => availableToolNames.includes(name)));
        persistDisabledTools();

        if (!servers.length) {
          renderPanel(serversOutputEl, [], "No connected MCP servers found.");
          return;
        }

        serversOutputEl.classList.remove("empty");
        serversOutputEl.innerHTML = "";

        for (const server of servers) {
          const serverDetails = document.createElement("details");
          serverDetails.className = "server-card";
          serverDetails.open = true;

          const serverSummary = document.createElement("summary");
          serverSummary.innerHTML = `
            <div class="server-summary-left">
              <strong>${server.name || "MCP server"}</strong>
              <div class="server-url">${server.url || ""}</div>
            </div>
            <span class="pill">${server.tool_count || 0} tools</span>
          `;

          const serverBody = document.createElement("div");
          serverBody.className = "server-body";

          const tools = server.tools || [];
          if (tools.length === 0) {
            const empty = document.createElement("div");
            empty.className = "small";
            empty.textContent = "No tools available for this server.";
            serverBody.appendChild(empty);
          } else {
            for (const tool of tools) {
              const toolName = String(tool.name || "tool");
              const toolDetails = document.createElement("details");
              toolDetails.className = "tool";
              toolDetails.open = false;

              const desc = tool.description ? tool.description : "No description available.";
              const params = tool.parameters || [];
              const requiredCount = params.filter((p) => p.required).length;
              const enabled = isToolEnabled(toolName);

              const toolSummary = document.createElement("summary");
              const summaryWrap = document.createElement("div");
              summaryWrap.className = "tool-summary-wrap";

              const left = document.createElement("div");
              left.className = "tool-summary-left";
              left.innerHTML = `
                <div class="tool-header-row">
                  <h4>${toolName}</h4>
                  <span class="tool-state ${enabled ? "on" : "off"}">${enabled ? "Enabled" : "Disabled"}</span>
                </div>
                <span class="tool-meta">${params.length} parameters • ${requiredCount} required</span>
              `;

              const switchLabel = document.createElement("label");
              switchLabel.className = "tool-switch";
              switchLabel.title = `${enabled ? "Disable" : "Enable"} ${toolName}`;
              switchLabel.innerHTML = `
                <input type="checkbox" ${enabled ? "checked" : ""} aria-label="Toggle ${toolName}" />
                <span class="tool-switch-track"><span class="tool-switch-thumb"></span></span>
              `;
              const checkbox = switchLabel.querySelector("input");
              const stateBadge = left.querySelector(".tool-state");

              const syncVisualState = () => {
                const isEnabled = checkbox.checked;
                setToolEnabled(toolName, isEnabled);
                if (stateBadge) {
                  stateBadge.textContent = isEnabled ? "Enabled" : "Disabled";
                  stateBadge.classList.toggle("on", isEnabled);
                  stateBadge.classList.toggle("off", !isEnabled);
                }
                switchLabel.title = `${isEnabled ? "Disable" : "Enable"} ${toolName}`;
              };

              switchLabel.addEventListener("click", (e) => e.stopPropagation());
              switchLabel.addEventListener("mousedown", (e) => e.stopPropagation());
              checkbox.addEventListener("click", (e) => e.stopPropagation());
              checkbox.addEventListener("change", syncVisualState);

              summaryWrap.appendChild(left);
              summaryWrap.appendChild(switchLabel);
              toolSummary.appendChild(summaryWrap);

              const toolBody = document.createElement("div");
              toolBody.className = "tool-body";

              const descEl = document.createElement("p");
              descEl.textContent = desc;
              toolBody.appendChild(descEl);

              const small = document.createElement("div");
              small.className = "small";
              small.textContent = `${params.length} parameters • ${requiredCount} required`;
              toolBody.appendChild(small);

              const paramList = document.createElement("div");
              paramList.className = "param-list";

              if (params.length === 0) {
                const pill = document.createElement("span");
                pill.className = "param opt";
                pill.textContent = "No parameters";
                paramList.appendChild(pill);
              } else {
                for (const param of params) {
                  const pill = document.createElement("span");
                  pill.className = `param ${param.required ? "req" : "opt"}`;
                  const typeLabel = param.type ? `:${param.type}` : "";
                  pill.textContent = `${param.name}${typeLabel}${param.required ? " *" : ""}`;
                  paramList.appendChild(pill);
                }
              }

              toolBody.appendChild(paramList);
              toolDetails.appendChild(toolSummary);
              toolDetails.appendChild(toolBody);
              serverBody.appendChild(toolDetails);
            }
          }

          serverDetails.appendChild(serverSummary);
          serverDetails.appendChild(serverBody);
          serversOutputEl.appendChild(serverDetails);
        }
      } catch (err) {
        serversOutputEl.classList.add("empty");
        serversOutputEl.textContent = `Unable to load MCP servers: ${err.message}`;
      }
    }

    async function sendMessage() {
      const text = input.value.trim();
      if (!text) return;

      addMessage("user", text);
      input.value = "";
      setBusy(true);
      resetLivePanels();

      try {
        const res = await fetch("/api/chat/stream", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            text,
            thread_id: threadId,
            history: history.slice(0, -1),
            allowed_tools: getEnabledToolNames(),
          }),
        });

        if (!res.ok || !res.body) {
          const body = await res.text();
          throw new Error(body || "Streaming request failed");
        }

        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });

          while (true) {
            const splitIndex = buffer.indexOf("\n\n");
            if (splitIndex === -1) break;

            const rawEvent = buffer.slice(0, splitIndex);
            buffer = buffer.slice(splitIndex + 2);

            const lines = rawEvent.split("\n");
            let eventName = "message";
            let dataText = "";

            for (const line of lines) {
              if (line.startsWith("event:")) {
                eventName = line.slice(6).trim();
              } else if (line.startsWith("data:")) {
                dataText += line.slice(5).trim();
              }
            }

            let payload = {};
            try {
              payload = dataText ? JSON.parse(dataText) : {};
            } catch {
              payload = { text: dataText };
            }

            if (eventName === "status") {
              appendTrace(`Status: ${payload.message || "update"}`);
            } else if (eventName === "tools") {
              appendTrace(`Connected to MCP server with ${payload.tool_count || 0} tools`);
              if (Array.isArray(payload.tools)) {
                appendTrace(`Tools: ${payload.tools.join(", ")}`);
              }
            } else if (eventName === "trace") {
              appendTrace(payload.line || "trace event");
            } else if (eventName === "delta") {
              appendAssistantDelta(payload.text || "");
            } else if (eventName === "done") {
              if (payload.reply) {
                agentOutputEl.classList.remove("empty");
                agentOutputEl.textContent = payload.reply;

                const bubble = ensureAssistantBubble();
                bubble.textContent = payload.reply;
              }
              if (Array.isArray(payload.trace) && payload.trace.length) {
                traceLines = payload.trace;
                traceOutputEl.classList.remove("empty");
                traceOutputEl.textContent = traceLines.map((x, i) => `${i + 1}. ${x}`).join("\n\n");
              }
            } else if (eventName === "error") {
              const msg = payload.message || "Unknown streaming error";
              appendTrace(`ERROR: ${msg}`);
              agentOutputEl.classList.remove("empty");
              agentOutputEl.textContent = `Error: ${msg}`;
              throw new Error(msg);
            }
          }
        }

        finalizeAssistantMessage();
        await loadMcpServers();
      } catch (err) {
        const msg = `Error: ${err.message}`;
        addMessage("assistant", msg);
        renderPanel(agentOutputEl, msg, "The assistant reply will appear here.");
        renderPanel(traceOutputEl, [msg], "Tool activity and model-visible steps will appear here.");
      } finally {
        setBusy(false);
        input.focus();
      }
    }

    sendBtn.addEventListener("click", sendMessage);
    newChatBtn.addEventListener("click", startNewChat);

    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        sendMessage();
      }
    });

    input.addEventListener("input", () => {
      resizeTextarea();
      updateSendState();
    });

    resizeTextarea();
    updateSendState();

    renderHistory();
    loadMcpServers();
  </script>
</body>
</html>
"""


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app:app",
        host="0.0.0.0",
        port=8080,
        log_level="debug",
    )