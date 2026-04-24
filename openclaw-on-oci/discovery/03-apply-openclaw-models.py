#!/usr/bin/env python3

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

import json
import subprocess
import sys
from pathlib import Path

DISCOVERY_PATH = Path(
    sys.argv[1] if len(sys.argv) > 1 else "/opt/openclaw/runtime/03-oci-genai-chat-models.json"
)
OPENCLAW_BIN = sys.argv[2] if len(sys.argv) > 2 else "/home/opc/.npm-global/bin/openclaw"
PROVIDER_NAME = "oci"

with DISCOVERY_PATH.open("r", encoding="utf-8") as f:
    discovery = json.load(f)

regions = discovery.get("regions", [])
if not isinstance(regions, list) or not regions:
    print("ERROR: No usable regions found in discovery output", file=sys.stderr)
    sys.exit(1)

region = regions[0]
base_url = region.get("baseUrl")
if not isinstance(base_url, str) or not base_url:
    print("ERROR: Missing baseUrl in discovery output", file=sys.stderr)
    sys.exit(1)

chat_completions = region.get("chatCompletions", {})
if not isinstance(chat_completions, dict):
    print("ERROR: chatCompletions section is missing or invalid", file=sys.stderr)
    sys.exit(1)

models = chat_completions.get("models", [])
if not isinstance(models, list) or not models:
    print("ERROR: No chatCompletions models found in discovery output", file=sys.stderr)
    sys.exit(1)

primary_model = f"{PROVIDER_NAME}/{models[0]}"

provider_models = [
    {
        "id": model,
        "name": model
    }
    for model in models
]

provider_payload = [
    {
        "path": f"models.providers.{PROVIDER_NAME}",
        "value": {
            "baseUrl": base_url,
            "api": "openai-responses",
            "auth": "api-key",
            "apiKey": {
                "source": "env",
                "provider": "default",
                "id": "OCI_GENAI_API_KEY"
            },
            "models": provider_models
        }
    }
]

model_map = {
    f"{PROVIDER_NAME}/{model}": {"alias": model}
    for model in models
}

models_payload = [
    {
        "path": "agents.defaults.models",
        "value": model_map
    }
]

subprocess.run(
    [OPENCLAW_BIN, "config", "set", "--batch-json", json.dumps(provider_payload)],
    check=True,
)

subprocess.run(
    [OPENCLAW_BIN, "config", "set", "agents.defaults.model", primary_model],
    check=True,
)

subprocess.run(
    [OPENCLAW_BIN, "config", "set", "--batch-json", json.dumps(models_payload)],
    check=True,
)

subprocess.run(
    [OPENCLAW_BIN, "config", "validate"],
    check=True,
)

print(json.dumps({
    "ok": True,
    "provider": PROVIDER_NAME,
    "region": region.get("region"),
    "baseUrl": base_url,
    "primary_model": primary_model,
    "models": models,
    "provider_models": provider_models,
    "model_map": model_map,
    "api_mode": "openai-responses"
}, indent=2))
