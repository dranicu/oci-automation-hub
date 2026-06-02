# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# OCI Agent App Server

FastAPI application server with a static chat UI, SQLite conversation storage, OCI Generative AI / Enterprise AI integration, MCP tools, RAG, and OCI Identity Domain sign-in.

The deployment is intentionally opinionated to keep configuration small:

- The container listens on port `8000`.
- Local Docker Compose exposes it at `http://localhost:8080`.
- App data is stored in `/app/data`.
- TLS should terminate at an OCI Load Balancer, API Gateway, or reverse proxy.
- OCI calls use resource principal auth.
- The app base URL is `http://localhost:8080`.
- The OIDC redirect URI is `http://localhost:8080/auth/callback`.

## Build

```bash
docker build -t <image-name>:<image-tag> .
```

## Required Environment Variables

| Variable | Description |
| --- | --- |
| `OCI_IDENTITY_DOMAIN_ISSUER` | OCI Identity Domain issuer URL. |
| `OCI_OIDC_CLIENT_ID` | Confidential application client ID. |
| `OCI_OIDC_CLIENT_SECRET` | Confidential application client secret. |

Use `.env.example` as the minimal variable template for local testing or deployment input.

## OCI Setup

1. Enable resource principal for the container runtime.
2. Grant the resource principal permission to discover compartments, projects, models, and call Generative AI.
3. Create an OCI Identity Domain confidential application.
4. Register this redirect URI on the confidential application:

```text
http://localhost:8080/auth/callback
```

5. Deploy the image with the required environment variables above. Region, compartment, project, and model are selected in the UI after sign-in.

## Local Compose Test

Create `.env` from the minimal template and fill in the values:

```bash
cp .env.example .env
docker compose up --build
```

The health check calls:

```text
http://127.0.0.1:8000/healthz
```
