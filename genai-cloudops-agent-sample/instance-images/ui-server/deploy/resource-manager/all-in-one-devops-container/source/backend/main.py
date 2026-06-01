# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import contextlib
import asyncio
import io
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse
from dotenv import load_dotenv
load_dotenv()
import oci
import httpx
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from langchain_mcp_adapters.tools import load_mcp_tools

from .agent import _build_stream, _client, _run_agent, _vector_client, _vector_legacy_client
from .auth import (
    allowed_compartments_for_user,
    allowed_regions_for_user,
    authenticated_user_from_request,
    auth_configured,
    auth_enabled,
    callback_response,
    current_user_from_request,
    login_redirect,
    logout_response,
    public_user,
    user_storage_key,
)
from .config import (
    COMPARTMENT_ID,
    CONFIG_PROFILE,
    FRONTEND_DIR,
    MODEL_ID,
    OCI_CONFIG,
    OCI_GENAI_MEMORY_ACCESS_POLICY,
    OCI_GENAI_MEMORY_SUBJECT_ID,
    OCI_GENAI_PROJECT_ID,
    OCI_GENAI_SHORT_TERM_MEMORY_OPTIMIZATION,
    PORT,
    APP_TLS_CERT_FILE,
    APP_TLS_KEY_FILE,
    logger,
)
from .models import ChatInput, ChatOutput, ConversationRenameInput, ConversationSaveInput, McpServerInput, McpServerUpdateInput, RagSourceInput
from .storage import (
    add_mcp_server,
    delete_conversation,
    delete_mcp_server,
    get_rag_source,
    get_conversation,
    init_storage,
    list_conversations,
    list_mcp_servers,
    rename_conversation,
    save_rag_source,
    save_conversation,
    update_mcp_server,
)
from .utils import _json_safe, _filter_tools


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("OCI agent MVP starting")
    init_storage()
    yield
    logger.info("OCI agent MVP shutting down")


app = FastAPI(lifespan=lifespan)
app.mount("/static", StaticFiles(directory=str(FRONTEND_DIR)), name="static")


FALLBACK_REGIONS = [
    "us-chicago-1",
    "us-ashburn-1",
    "eu-frankfurt-1",
    "uk-london-1",
    "ap-tokyo-1",
    "ap-osaka-1",
    "sa-saopaulo-1",
]


FALLBACK_MODELS = [
    {
        "id": MODEL_ID,
        "display_name": MODEL_ID,
        "provider": os.getenv("MODEL_PROVIDER", "meta"),
        "lifecycle_state": "ACTIVE",
    }
]

RESPONSES_SUPPORTED_MODEL_IDS = {
    item.strip()
    for item in os.getenv(
        "OCI_RESPONSES_SUPPORTED_MODELS",
        ",".join(
            [
                "xai.grok-3-mini-fast",
                "xai.grok-4-1-fast-reasoning",
                "xai.grok-3-mini",
                "xai.grok-3-fast",
                "xai.grok-3",
                "xai.grok-4-fast-non-reasoning",
                "xai.grok-4-fast-reasoning",
                "xai.grok-code-fast-1",
                "xai.grok-4",
                "xai.grok-4-1-fast-non-reasoning",
            ]
        ),
    ).split(",")
    if item.strip()
}
if MODEL_ID:
    RESPONSES_SUPPORTED_MODEL_IDS.add(MODEL_ID)


def _region_name(region: str) -> str:
    return region.replace("-", " ").title()


def _default_region() -> str:
    endpoint = os.getenv("OCI_GENAI_ENDPOINT", "")
    marker = "generativeai."
    if marker in endpoint:
        return endpoint.split(marker, 1)[1].split(".oci.", 1)[0]
    return OCI_CONFIG.get("region") or ""


def _subscribed_regions() -> list[dict]:
    client = oci.identity.IdentityClient(config=OCI_CONFIG)
    tenancy_id = OCI_CONFIG.get("tenancy")
    if not tenancy_id:
        raise RuntimeError("OCI tenancy is not configured in ~/.oci/config")

    response = client.list_region_subscriptions(tenancy_id)
    regions = []
    for item in response.data or []:
        region_id = str(getattr(item, "region_name", "") or "")
        if not region_id:
            continue
        regions.append(
            {
                "id": region_id,
                "name": _region_name(region_id),
                "region_key": str(getattr(item, "region_key", "") or ""),
                "status": str(getattr(item, "status", "") or ""),
                "is_home_region": bool(getattr(item, "is_home_region", False)),
            }
        )
    return sorted(regions, key=lambda item: (not item["is_home_region"], item["name"].lower()))


def _model_provider(model_id: str, vendor: str = "") -> str:
    text = f"{model_id} {vendor}".lower()
    if "cohere" in text or "command" in text:
        return "cohere"
    if "google" in text or "gemini" in text:
        return "google"
    if "openai" in text or "gpt" in text:
        return "openai"
    if "meta" in text or "llama" in text:
        return "meta"
    if "xai" in text or "grok" in text or "mistral" in text:
        return "generic"
    return os.getenv("MODEL_PROVIDER", "generic")


def _model_to_dict(model) -> dict:
    oci_model_id = getattr(model, "id", "") or getattr(model, "model_id", "") or getattr(model, "name", "")
    display_name = getattr(model, "display_name", None) or oci_model_id
    vendor = getattr(model, "vendor", "") or getattr(model, "provider", "") or ""
    capabilities = getattr(model, "capabilities", None) or []
    lifecycle_state = getattr(model, "lifecycle_state", None) or ""
    chat_model_id = str(display_name or oci_model_id)
    return {
        "id": chat_model_id,
        "display_name": str(display_name),
        "provider": _model_provider(chat_model_id, str(vendor)),
        "oci_id": str(oci_model_id),
        "vendor": str(vendor),
        "capabilities": _json_safe(capabilities),
        "lifecycle_state": str(lifecycle_state),
    }


def _responses_model_to_dict(model_id: str) -> dict:
    return {
        "id": model_id,
        "display_name": model_id,
        "provider": _model_provider(model_id),
        "oci_id": model_id,
        "vendor": "",
        "capabilities": ["responses", "chat", "on-demand"],
        "lifecycle_state": "ACTIVE",
    }


def _is_chat_model(model_info: dict) -> bool:
    capabilities = model_info.get("capabilities") or []
    capability_text = " ".join(str(item).lower() for item in capabilities)
    name_text = f"{model_info.get('id', '')} {model_info.get('display_name', '')}".lower()

    if "chat" in capability_text:
        return _is_enterprise_ai_model(name_text)
    if any(blocked in capability_text or blocked in name_text for blocked in ("embedding", "embed", "rerank", "guard")):
        return False
    return "command" in name_text or "instruct" in name_text or "gpt" in name_text or "grok" in name_text or "gemini" in name_text


def _is_enterprise_ai_model(name_text: str) -> bool:
    return any(model_id in name_text for model_id in RESPONSES_SUPPORTED_MODEL_IDS)


def _supported_catalog_models(models: list[dict]) -> list[dict]:
    by_id = {model["id"]: model for model in models if model.get("id") in RESPONSES_SUPPORTED_MODEL_IDS}
    return [by_id[model_id] for model_id in sorted(RESPONSES_SUPPORTED_MODEL_IDS) if model_id in by_id]


def _configured_response_models() -> list[dict]:
    model_ids = sorted(RESPONSES_SUPPORTED_MODEL_IDS)
    if MODEL_ID in model_ids:
        model_ids.remove(MODEL_ID)
        model_ids.insert(0, MODEL_ID)
    return [_responses_model_to_dict(model_id) for model_id in model_ids]


def _openai_compatible_models(region: str, project_id: str | None) -> list[dict]:
    if not project_id:
        return []

    client = _client(region, project_id)
    response = client.models.list()
    models = []
    for item in getattr(response, "data", []) or []:
        model_id = str(getattr(item, "id", "") or "")
        if model_id:
            models.append(_responses_model_to_dict(model_id))
    return models


def _config_for_region(region: str) -> dict:
    config = dict(OCI_CONFIG)
    if region:
        config["region"] = region
    return config


def _compartment_to_dict(compartment) -> dict:
    return {
        "id": str(getattr(compartment, "id", "")),
        "name": str(getattr(compartment, "name", "") or getattr(compartment, "display_name", "") or "Compartment"),
        "description": str(getattr(compartment, "description", "") or ""),
        "lifecycle_state": str(getattr(compartment, "lifecycle_state", "") or ""),
        "parent_compartment_id": str(getattr(compartment, "compartment_id", "") or ""),
    }


def _project_to_dict(project) -> dict:
    return {
        "id": str(getattr(project, "id", "")),
        "display_name": str(getattr(project, "display_name", "") or "Generative AI project"),
        "description": str(getattr(project, "description", "") or ""),
        "compartment_id": str(getattr(project, "compartment_id", "") or ""),
        "lifecycle_state": str(getattr(project, "lifecycle_state", "") or ""),
        "time_created": str(getattr(project, "time_created", "") or ""),
    }


def _clean_file_ids(file_ids: list[str]) -> list[str]:
    return list(dict.fromkeys(item.strip() for item in file_ids if item.strip()))


def _check_region_and_compartment(user: dict, region: str, compartment_id: str) -> None:
    allowed_regions = allowed_regions_for_user(user)
    if allowed_regions and region not in allowed_regions:
        raise HTTPException(status_code=403, detail="Region is not allowed for this user")

    allowed_compartments = allowed_compartments_for_user(user)
    if allowed_compartments and compartment_id not in allowed_compartments:
        raise HTTPException(status_code=403, detail="Compartment is not allowed for this user")


def _create_vector_store(region: str, compartment_id: str, project_id: str, name: str):
    client = _vector_client(region, project_id, compartment_id, control_plane=True)
    return client.vector_stores.create(
        name=name,
        description=f"{name} for OCI AI Chat",
        expires_after={"anchor": "last_active_at", "days": 30},
        metadata={"created_by": "oci-ai-chat"},
    )


def _wait_for_vector_store(region: str, compartment_id: str, project_id: str, vector_store_id: str) -> None:
    client = _vector_client(region, project_id, compartment_id, control_plane=True)
    for _ in range(8):
        try:
            client.vector_stores.retrieve(vector_store_id)
            return
        except Exception as exc:
            status = getattr(exc, "status_code", None) or getattr(exc, "status", None)
            if status != 404:
                raise
            time.sleep(1.5)


def _attach_vector_store_files(region: str, compartment_id: str, project_id: str, vector_store_id: str, file_ids: list[str]):
    if not file_ids:
        return None

    client = _vector_legacy_client(region, project_id, compartment_id)

    def attach_with(selected_client):
        if len(file_ids) == 1:
            return selected_client.vector_stores.files.create(vector_store_id=vector_store_id, file_id=file_ids[0])
        return selected_client.vector_stores.file_batches.create(
            vector_store_id=vector_store_id,
            file_ids=file_ids,
            attributes={"type": "batch"},
        )

    return attach_with(client)


def _vector_store_to_dict(vector_store) -> dict:
    payload = _json_safe(vector_store)
    if isinstance(payload, dict):
        return {
            "id": str(payload.get("id") or ""),
            "name": str(payload.get("name") or payload.get("display_name") or payload.get("displayName") or payload.get("id") or "Vector store"),
            "created_at": str(payload.get("created_at") or payload.get("time_created") or payload.get("timeCreated") or ""),
            "file_counts": payload.get("file_counts") or payload.get("fileCounts") or {},
            "status": str(payload.get("status") or payload.get("lifecycle_state") or payload.get("lifecycleState") or ""),
        }
    return {
        "id": str(getattr(vector_store, "id", "") or ""),
        "name": str(getattr(vector_store, "name", "") or getattr(vector_store, "display_name", "") or "Vector store"),
        "created_at": str(getattr(vector_store, "created_at", "") or getattr(vector_store, "time_created", "") or ""),
        "status": str(getattr(vector_store, "status", "") or getattr(vector_store, "lifecycle_state", "") or ""),
    }


def _list_vector_stores(region: str, compartment_id: str, project_id: str) -> list[dict]:
    client = _vector_client(region, project_id, compartment_id, control_plane=True)
    response = client.vector_stores.list(limit=100)
    data = getattr(response, "data", None)
    raw_items = data if isinstance(data, list) else None
    if raw_items is None and data is not None:
        raw_items = getattr(data, "items", None)
    if raw_items is None:
        raw_items = getattr(response, "items", None)
    if raw_items is None:
        raw_items = list(response) if hasattr(response, "__iter__") else []
    stores = [_vector_store_to_dict(item) for item in raw_items or []]
    return [store for store in stores if store.get("id")]


def _friendly_mcp_error(exc: BaseException, url: str) -> str:
    if isinstance(exc, BaseExceptionGroup):
        messages = [_friendly_mcp_error(item, url) for item in exc.exceptions]
        messages = [message for message in messages if message]
        return "; ".join(dict.fromkeys(messages)) or str(exc)

    if isinstance(exc, httpx.HTTPStatusError):
        status = exc.response.status_code
        if status in {404, 405} and url.rstrip("/") == urlparse(url)._replace(path="").geturl().rstrip("/"):
            return f"MCP endpoint returned HTTP {status}. If this is a streamable HTTP MCP server, try {url.rstrip('/')}/mcp."
        return f"MCP endpoint returned HTTP {status}."

    name = exc.__class__.__name__
    text = str(exc)
    if "ConnectError" in name or "ConnectError" in text:
        return "Could not connect to the MCP server. Check the URL, DNS, and network access."
    return text or name


async def _discover_mcp_server_tools(server_info: dict) -> dict:
    async with streamablehttp_client(url=server_info["url"]) as (reader, writer, _):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            tools = _filter_tools(await load_mcp_tools(session))

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

            server_info["tool_count"] = len(server_info["tools"])
            return server_info


async def _discover_mcp_server(server: dict) -> dict:
    server_info = {
        "server_id": server.get("server_id"),
        "name": server.get("name") or "MCP server",
        "url": server.get("url") or "",
        "enabled": bool(server.get("enabled", True)),
        "tool_count": 0,
        "tools": [],
    }

    try:
        return await asyncio.wait_for(_discover_mcp_server_tools(server_info), timeout=8)
    except asyncio.TimeoutError:
        server_info["error"] = "Tool discovery timed out. Check that the MCP server is reachable."
        return server_info
    except Exception as exc:
        logger.exception("Failed to discover MCP server %s", server_info["url"])
        server_info["error"] = _friendly_mcp_error(exc, server_info["url"])
        return server_info


@app.get("/healthz")
async def healthz():
    return {"status": "ok", "service": "oci-agent-mvp"}


@app.get("/api/auth/me")
async def auth_me(request: Request):
    user = current_user_from_request(request)
    return {
        "status": "success",
        "authenticated": auth_enabled(),
        "auth_configured": auth_configured(),
        "user": public_user(user),
    }


@app.get("/auth/login")
async def auth_login(request: Request):
    return login_redirect(request)


@app.get("/auth/callback")
async def auth_callback(request: Request, code: str, state: str):
    return callback_response(request, code, state)


@app.get("/auth/logout")
async def auth_logout(request: Request):
    return logout_response(request)


@app.get("/api/mcp-info")
async def mcp_info(request: Request):
    user = current_user_from_request(request)
    servers = list_mcp_servers(user_storage_key(user))
    discovered = [await _discover_mcp_server(server) for server in servers]
    return {"status": "success", "servers": discovered}


@app.post("/api/mcp-servers")
async def mcp_server_add(input_data: McpServerInput, request: Request):
    user = current_user_from_request(request)
    saved = add_mcp_server(user_storage_key(user), input_data.name, input_data.url, input_data.enabled)
    discovered = await _discover_mcp_server(saved)
    return {"status": "success", "server": discovered}


@app.patch("/api/mcp-servers/{server_id}")
async def mcp_server_update(server_id: str, input_data: McpServerUpdateInput, request: Request):
    user = current_user_from_request(request)
    updated = update_mcp_server(user_storage_key(user), server_id, input_data.name, input_data.enabled)
    if updated is None:
        raise HTTPException(status_code=404, detail="MCP server not found")
    discovered = await _discover_mcp_server(updated)
    return {"status": "success", "server": discovered}


@app.delete("/api/mcp-servers/{server_id}")
async def mcp_server_delete(server_id: str, request: Request):
    user = current_user_from_request(request)
    delete_mcp_server(user_storage_key(user), server_id)
    return {"status": "success"}


@app.get("/api/oci/regions")
async def oci_regions(request: Request):
    user = current_user_from_request(request)
    configured_region = _default_region()
    try:
        regions = _subscribed_regions()
    except Exception as exc:
        logger.exception("Failed to load subscribed OCI regions")
        return JSONResponse(
            status_code=500,
            content={"status": "error", "message": str(exc), "regions": []},
        )

    allowed_regions = allowed_regions_for_user(user)
    if allowed_regions:
        regions = [region for region in regions if region["id"] in allowed_regions]

    region_ids = {region["id"] for region in regions}
    default_region = configured_region if configured_region in region_ids else (regions[0]["id"] if regions else "")

    return {
        "status": "success",
        "default_region": default_region,
        "regions": regions,
    }


@app.get("/api/oci/models")
async def oci_models(region: str, request: Request, project_id: str = ""):
    user = current_user_from_request(request)
    allowed_regions = allowed_regions_for_user(user)
    if allowed_regions and region not in allowed_regions:
        raise HTTPException(status_code=403, detail="Region is not allowed for this user")
    config = _config_for_region(region)

    if os.getenv("OCI_ENABLE_OPENAI_MODEL_LISTING", "").lower() in {"1", "true", "yes", "on"}:
        try:
            responses_models = _openai_compatible_models(region, project_id or OCI_GENAI_PROJECT_ID)
            if responses_models:
                return {
                    "status": "success",
                    "region": region,
                    "models": responses_models,
                    "source": "oci-openai-compatible",
                }
        except Exception as exc:
            logger.info("OCI OpenAI-compatible model listing is unavailable for %s: %s", region, exc)

    try:
        client = oci.generative_ai.GenerativeAiClient(config=config, service_endpoint=f"https://generativeai.{region}.oci.oraclecloud.com")
        response = client.list_models(compartment_id=COMPARTMENT_ID, lifecycle_state="ACTIVE")
        models = [_model_to_dict(model) for model in getattr(response.data, "items", [])]
        chat_models = _supported_catalog_models([model for model in models if model.get("id") and _is_chat_model(model)])

        return {
            "status": "success",
            "region": region,
            "models": chat_models or _configured_response_models(),
            "source": "oci-supported-catalog" if chat_models else "configured-supported",
        }
    except Exception as exc:
        status = getattr(exc, "status", None) or getattr(exc, "status_code", None)
        if status == 404:
            logger.warning("OCI GenAI model catalog is unavailable for %s; using configured models.", region)
        else:
            logger.exception("Failed to load OCI GenAI models for %s", region)
        return JSONResponse(
            status_code=200,
            content={
                "status": "fallback",
                "region": region,
                "message": str(exc),
                "models": _configured_response_models(),
                "source": "configured-default-supported",
            },
        )


@app.get("/api/oci/compartments")
async def oci_compartments(region: str, request: Request):
    user = current_user_from_request(request)
    allowed_regions = allowed_regions_for_user(user)
    if allowed_regions and region not in allowed_regions:
        raise HTTPException(status_code=403, detail="Region is not allowed for this user")
    try:
        config = _config_for_region(region)
        tenancy_id = config.get("tenancy")
        client = oci.identity.IdentityClient(config=config)

        response = oci.pagination.list_call_get_all_results(
            client.list_compartments,
            compartment_id=tenancy_id,
            compartment_id_in_subtree=True,
            access_level="ACCESSIBLE",
            lifecycle_state="ACTIVE",
        )

        compartments = []
        if tenancy_id:
            compartments.append(
                {
                    "id": tenancy_id,
                    "name": "Tenancy root",
                    "description": "Root compartment",
                    "lifecycle_state": "ACTIVE",
                    "parent_compartment_id": "",
                }
            )
        compartments.extend(_compartment_to_dict(item) for item in response.data)
        allowed_compartments = allowed_compartments_for_user(user)
        if allowed_compartments:
            compartments = [item for item in compartments if item["id"] in allowed_compartments]
        compartments = sorted(compartments, key=lambda item: item["name"].lower())

        return {
            "status": "success",
            "region": region,
            "default_compartment_id": COMPARTMENT_ID,
            "compartments": compartments,
        }
    except Exception as exc:
        logger.exception("Failed to load OCI compartments for %s", region)
        return JSONResponse(
            status_code=500,
            content={"status": "error", "region": region, "message": str(exc), "compartments": []},
        )


@app.get("/api/oci/genai-projects")
async def oci_genai_projects(region: str, compartment_id: str, request: Request):
    user = current_user_from_request(request)
    allowed_regions = allowed_regions_for_user(user)
    if allowed_regions and region not in allowed_regions:
        raise HTTPException(status_code=403, detail="Region is not allowed for this user")
    allowed_compartments = allowed_compartments_for_user(user)
    if allowed_compartments and compartment_id not in allowed_compartments:
        raise HTTPException(status_code=403, detail="Compartment is not allowed for this user")
    try:
        config = _config_for_region(region)
        client = oci.generative_ai.GenerativeAiClient(
            config=config,
            service_endpoint=f"https://generativeai.{region}.oci.oraclecloud.com",
        )
        response = oci.pagination.list_call_get_all_results(
            client.list_generative_ai_projects,
            compartment_id=compartment_id,
            lifecycle_state="ACTIVE",
        )
        projects = sorted(
            (_project_to_dict(project) for project in response.data),
            key=lambda item: item["display_name"].lower(),
        )

        return {
            "status": "success",
            "region": region,
            "compartment_id": compartment_id,
            "default_project_id": OCI_GENAI_PROJECT_ID,
            "projects": projects,
        }
    except Exception as exc:
        logger.exception("Failed to load OCI GenAI projects for %s / %s", region, compartment_id)
        return JSONResponse(
            status_code=500,
            content={
                "status": "error",
                "region": region,
                "compartment_id": compartment_id,
                "message": str(exc),
                "projects": [],
            },
        )


@app.get("/api/enterprise-ai/config")
async def enterprise_ai_config(request: Request):
    current_user_from_request(request)
    return {
        "status": "success",
        "project_configured": bool(OCI_GENAI_PROJECT_ID),
        "project_id": OCI_GENAI_PROJECT_ID,
        "memory_subject_id": OCI_GENAI_MEMORY_SUBJECT_ID,
        "memory_access_policy": OCI_GENAI_MEMORY_ACCESS_POLICY,
        "short_term_memory_optimization": OCI_GENAI_SHORT_TERM_MEMORY_OPTIMIZATION,
    }


@app.get("/api/rag-source")
async def rag_source_get(region: str, compartment_id: str, project_id: str, request: Request):
    user = current_user_from_request(request)
    _check_region_and_compartment(user, region, compartment_id)
    source = get_rag_source(user_storage_key(user), region, compartment_id, project_id)
    try:
        vector_stores = _list_vector_stores(region, compartment_id, project_id)
        vector_store_error = ""
    except Exception as exc:
        logger.warning("Failed to list OCI vector stores for %s: %s", region, exc)
        vector_stores = []
        vector_store_error = str(exc)
    return {
        "status": "success",
        "source": source,
        "vector_stores": vector_stores,
        "vector_store_error": vector_store_error,
    }


@app.post("/api/rag-source")
async def rag_source_save(input_data: RagSourceInput, request: Request):
    user = current_user_from_request(request)
    _check_region_and_compartment(user, input_data.region, input_data.compartment_id)

    client_id = user_storage_key(user)
    existing = get_rag_source(client_id, input_data.region, input_data.compartment_id, input_data.project_id)
    file_ids = _clean_file_ids(input_data.file_ids)
    existing_file_ids = _clean_file_ids(existing.get("file_ids", []) if existing else [])

    try:
        selected_vector_store_id = (input_data.vector_store_id or "").strip()
        if selected_vector_store_id:
            vector_store_id = selected_vector_store_id
            created = False
        elif existing and existing.get("vector_store_id"):
            vector_store_id = str(existing["vector_store_id"])
            created = False
        else:
            vector_store = _create_vector_store(
                input_data.region,
                input_data.compartment_id,
                input_data.project_id,
                input_data.name,
            )
            vector_store_id = str(getattr(vector_store, "id", "") or "")
            if not vector_store_id:
                raise RuntimeError("OCI did not return a vector store id.")
            created = True

        new_file_ids = [file_id for file_id in file_ids if file_id not in existing_file_ids]
        if created and new_file_ids:
            _wait_for_vector_store(input_data.region, input_data.compartment_id, input_data.project_id, vector_store_id)
        batch = _attach_vector_store_files(
            input_data.region,
            input_data.compartment_id,
            input_data.project_id,
            vector_store_id,
            new_file_ids,
        )
        source = save_rag_source(
            client_id,
            input_data.region,
            input_data.compartment_id,
            input_data.project_id,
            input_data.name,
            vector_store_id,
            existing_file_ids + new_file_ids,
        )
        return {
            "status": "success",
            "source": source,
            "created": created,
            "attached_file_count": len(new_file_ids),
            "batch": _json_safe(batch) if batch is not None else None,
        }
    except Exception as exc:
        logger.exception("Failed to save RAG source")
        status = getattr(exc, "status_code", None) or getattr(exc, "status", None)
        if status == 404 and "NotAuthorizedOrNotFound" in str(exc):
            raise HTTPException(
                status_code=403,
                detail=(
                    "OCI could not create the vector store. Check that your OCI session/profile can manage "
                    "Generative AI vector stores in this compartment and region."
                ),
            )
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/api/rag-files")
async def rag_files_upload(
    request: Request,
    region: str = Form(...),
    compartment_id: str = Form(...),
    project_id: str = Form(...),
    files: list[UploadFile] = File(...),
):
    user = current_user_from_request(request)
    _check_region_and_compartment(user, region, compartment_id)

    if not files:
        raise HTTPException(status_code=400, detail="Choose at least one file to upload.")

    client = _vector_legacy_client(region, project_id, compartment_id)
    uploaded = []
    try:
        for upload in files:
            content = await upload.read()
            if not content:
                continue
            created = client.files.create(
                file=(
                    upload.filename or "document",
                    io.BytesIO(content),
                    upload.content_type or "application/octet-stream",
                ),
                purpose="assistants",
            )
            uploaded.append(
                {
                    "id": str(getattr(created, "id", "") or ""),
                    "filename": upload.filename or "document",
                    "bytes": len(content),
                }
            )
    except Exception as exc:
        logger.exception("Failed to upload RAG file")
        raise HTTPException(status_code=500, detail=str(exc))

    uploaded = [item for item in uploaded if item["id"]]
    return {"status": "success", "files": uploaded}


@app.get("/api/conversations")
async def conversations(request: Request):
    user = current_user_from_request(request)
    return {"status": "success", "conversations": list_conversations(user_storage_key(user))}


@app.get("/api/conversations/{thread_id}")
async def conversation_detail(thread_id: str, request: Request):
    user = current_user_from_request(request)
    conversation = get_conversation(user_storage_key(user), thread_id)
    if conversation is None:
        raise HTTPException(status_code=404, detail="Conversation not found")
    return {"status": "success", "conversation": conversation}


@app.post("/api/conversations")
async def conversation_save(input_data: ConversationSaveInput, request: Request):
    user = current_user_from_request(request)
    input_data.client_id = user_storage_key(user)
    return {"status": "success", "conversation": save_conversation(input_data)}


@app.patch("/api/conversations/{thread_id}")
async def conversation_rename(thread_id: str, input_data: ConversationRenameInput, request: Request):
    user = current_user_from_request(request)
    conversation = rename_conversation(user_storage_key(user), thread_id, input_data.title)
    if conversation is None:
        raise HTTPException(status_code=404, detail="Conversation not found")
    return {"status": "success", "conversation": conversation}


@app.delete("/api/conversations/{thread_id}")
async def conversation_delete(thread_id: str, request: Request):
    user = current_user_from_request(request)
    delete_conversation(user_storage_key(user), thread_id)
    return {"status": "success"}


@app.post("/api/chat")
async def chat_endpoint(input: ChatInput, request: Request):
    user = current_user_from_request(request)
    user_mcp_servers = list_mcp_servers(user_storage_key(user))
    selected_server_ids = set(input.enabled_mcp_servers or [])
    if selected_server_ids:
        user_mcp_servers = [server for server in user_mcp_servers if server["server_id"] in selected_server_ids]
    try:
        result = await _run_agent(
            input.text,
            input.history,
            input.allowed_tools,
            input.thread_id,
            input.mcp_enabled,
            user_mcp_servers,
            input.allowed_mcp_tools,
            input.region,
            input.compartment_id,
            input.project_id,
            input.model_id,
            input.model_provider,
            input.temperature,
            input.top_p,
            input.max_tokens,
            input.conversation_id,
            input.memory_subject_id,
            input.memory_access_policy,
            input.short_term_memory_optimization,
            input.rag_enabled,
            input.rag_vector_store_id,
            input.rag_max_results,
        )
        return ChatOutput(
            reply=result["reply"],
            trace=result["trace"],
            thread_id=input.thread_id,
            timestamp_utc=datetime.now(timezone.utc).isoformat(),
            conversation_id=result.get("conversation_id"),
        )
    except Exception as exc:
        logger.exception("Error during chat invocation")
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/api/chat/stream")
async def chat_stream_endpoint(input: ChatInput, request: Request):
    user = current_user_from_request(request)
    user_mcp_servers = list_mcp_servers(user_storage_key(user))
    selected_server_ids = set(input.enabled_mcp_servers or [])
    if selected_server_ids:
        user_mcp_servers = [server for server in user_mcp_servers if server["server_id"] in selected_server_ids]
    return StreamingResponse(
        _build_stream(
            input.text,
            input.history,
            input.thread_id,
            input.allowed_tools,
            input.mcp_enabled,
            user_mcp_servers,
            input.allowed_mcp_tools,
            input.region,
            input.compartment_id,
            input.project_id,
            input.model_id,
            input.model_provider,
            input.temperature,
            input.top_p,
            input.max_tokens,
            input.conversation_id,
            input.memory_subject_id,
            input.memory_access_policy,
            input.short_term_memory_optimization,
            input.rag_enabled,
            input.rag_vector_store_id,
            input.rag_max_results,
        ),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    if auth_enabled() and not authenticated_user_from_request(request):
        return login_redirect(request)
    index_path = FRONTEND_DIR / "index.html"
    return HTMLResponse(index_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "backend.main:app",
        host="0.0.0.0",
        port=PORT,
        log_level="INFO",
        ssl_certfile=APP_TLS_CERT_FILE or None,
        ssl_keyfile=APP_TLS_KEY_FILE or None,
    )
