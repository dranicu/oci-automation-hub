# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# OCI Test MCP Server

A minimal MCP server designed to run as an OCI Container Instance.

## Endpoints
- MCP Streamable HTTP: `/`
- Health check: `/healthz`

## Run locally
```bash
cp .env.example .env
pip install -r requirements.txt
python app.py
```

## Docker
```bash
docker build -t oci-test-mcp-server .
docker run --rm -p 8080:8080 --env-file .env oci-test-mcp-server
```

## OCI notes
- Expose container port `8080`.
- Allow inbound traffic to `8080` in the subnet security list or NSG.
- Set the container instance public IP if you need direct internet access.
