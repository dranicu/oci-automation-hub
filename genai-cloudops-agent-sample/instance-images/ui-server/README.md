# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# OCI Agent MVP

Single-container MVP that hosts:

- a FastAPI web UI
- a chat endpoint that calls an MCP server
- a LangGraph ReAct agent
- OCI Generative AI via `ChatOCIGenAI`

## Endpoints

- `/` - simple web UI
- `/api/chat` - chat API used by the UI
- `/healthz` - container health check

## Environment variables

Copy `.env.example` to `.env` and fill in:

- `COMPARTMENT_ID`
- `AUTH_TYPE`
- `CONFIG_PROFILE`
- `OCI_GENAI_ENDPOINT`
- `MODEL_ID`
- `MCP_SERVER_URL`

## Notes

- The UI shows a visible execution trace for tool use and model-visible steps.
- It does not expose private chain-of-thought.
- The container listens on port `8080`.
