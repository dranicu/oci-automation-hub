# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import logging
import os
import secrets
import json
from pathlib import Path

import oci
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
logger = logging.getLogger("oci_agent_mvp")

OCI_GENAI_ENDPOINT = os.getenv(
    "OCI_GENAI_ENDPOINT",
    "https://inference.generativeai.us-chicago-1.oci.oraclecloud.com",
)
AUTH_TYPE = os.getenv("AUTH_TYPE", "API_KEY")
OCI_GENAI_PROJECT_ID = os.getenv("OCI_GENAI_PROJECT_ID", os.getenv("GENAI_PROJECT_ID", ""))
OCI_GENAI_API_KEY = os.getenv("OCI_GENAI_API_KEY", "")
OCI_GENAI_AUTH_MODE = os.getenv("OCI_GENAI_AUTH_MODE", AUTH_TYPE)
OCI_GENAI_MEMORY_SUBJECT_ID = os.getenv("OCI_GENAI_MEMORY_SUBJECT_ID", "")
OCI_GENAI_MEMORY_ACCESS_POLICY = os.getenv("OCI_GENAI_MEMORY_ACCESS_POLICY", "recall_and_store")
OCI_GENAI_SHORT_TERM_MEMORY_OPTIMIZATION = os.getenv("OCI_GENAI_SHORT_TERM_MEMORY_OPTIMIZATION", "")
COMPARTMENT_ID = os.getenv(
    "COMPARTMENT_ID",
    "ocid1.compartment.oc1..aaaaaaaamjlz5jgh7uspm7h6cppdgrmlj76r7232737dsom4flwq2m4w723a",
)
CONFIG_PROFILE = os.getenv("CONFIG_PROFILE", "DEFAULT")
MODEL_ID = os.getenv("MODEL_ID", "openai.gpt-oss-120b")
PORT = int(os.getenv("PORT", "8000"))
APP_SESSION_SECRET = os.getenv("APP_SESSION_SECRET", secrets.token_urlsafe(32))
APP_BASE_URL = os.getenv("APP_BASE_URL", f"http://localhost:{PORT}")
APP_TLS_CERT_FILE = os.getenv("APP_TLS_CERT_FILE", "")
APP_TLS_KEY_FILE = os.getenv("APP_TLS_KEY_FILE", "")

OCI_IDENTITY_DOMAIN_ISSUER = os.getenv("OCI_IDENTITY_DOMAIN_ISSUER", "").rstrip("/")
OCI_OIDC_CLIENT_ID = os.getenv("OCI_OIDC_CLIENT_ID", "")
OCI_OIDC_CLIENT_SECRET = os.getenv("OCI_OIDC_CLIENT_SECRET", "")
OCI_OIDC_REDIRECT_URI = os.getenv("OCI_OIDC_REDIRECT_URI", f"{APP_BASE_URL}/auth/callback")
AUTH_COOKIE_NAME = os.getenv("AUTH_COOKIE_NAME", "oci_ai_chat_session")
AUTH_ENABLED = os.getenv("AUTH_ENABLED", "false").lower() in {"1", "true", "yes", "on"}
AUTH_COOKIE_SECURE = os.getenv("AUTH_COOKIE_SECURE", "false").lower() in {"1", "true", "yes", "on"}
AUTH_ALLOWED_GROUPS = {
    item.strip()
    for item in os.getenv("AUTH_ALLOWED_GROUPS", "").split(",")
    if item.strip()
}
AUTH_GROUP_REGION_MAP = json.loads(os.getenv("AUTH_GROUP_REGION_MAP", "{}") or "{}")
AUTH_GROUP_COMPARTMENT_MAP = json.loads(os.getenv("AUTH_GROUP_COMPARTMENT_MAP", "{}") or "{}")

if not COMPARTMENT_ID:
    logger.warning("COMPARTMENT_ID is not set. OCI GenAI calls will fail until it is configured.")


def _load_oci_config() -> dict:
    config_file = os.getenv("OCI_CONFIG_FILE", os.path.expanduser("~/.oci/config"))
    try:
        return dict(oci.config.from_file(config_file, CONFIG_PROFILE))
    except Exception as exc:
        logger.warning(
            "OCI config was not loaded from %s profile %s: %s. "
            "Mount an OCI config file or use instance/resource principal auth for OCI calls.",
            config_file,
            CONFIG_PROFILE,
            exc,
        )
        region = os.getenv("OCI_REGION") or os.getenv("OCI_CLI_REGION") or "us-chicago-1"
        return {"region": region}


OCI_CONFIG = _load_oci_config()

PROJECT_ROOT = Path(__file__).resolve().parents[1]
FRONTEND_DIR = PROJECT_ROOT / "frontend"
DATA_DIR = Path(os.getenv("APP_DATA_DIR", str(PROJECT_ROOT / "data")))
CONVERSATION_DB_PATH = DATA_DIR / "conversations.sqlite3"
