# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# OCI Agent

FastAPI backend, static frontend, SQLite conversation storage, and OCI Generative AI integration.

## Run With Docker

1. Create the env file:

```bash
cp .env.example .env
```

2. Edit `.env` and set at least:

```bash
OCI_GENAI_PROJECT_ID=ocid1.generativeaiproject...
COMPARTMENT_ID=ocid1.compartment...
OCI_REGION=us-chicago-1
MODEL_ID=openai.gpt-oss-120b
```

3. Start it:

```bash
docker compose up --build -d
```

Open `http://localhost:8000`.

The app stores conversation data in a Docker volume named `app-data`. Your local OCI config is mounted read-only from `${HOME}/.oci` for API key or security-token auth.

Useful commands:

```bash
docker compose logs -f app
docker compose down
```

## Build Image

Build the Docker image:

```bash
sh scripts/build_image.sh
```

Build with a version tag:

```bash
VERSION=1.0.0 sh scripts/build_image.sh
```

Build and push to a registry:

```bash
IMAGE_NAME=iad.ocir.io/namespace/oci-agent VERSION=1.0.0 PUSH=true sh scripts/build_image.sh
```

Build and push directly to OCIR:

```bash
OCIR_REGION_KEY=iad \
OCIR_NAMESPACE=namespace \
IMAGE_REPOSITORY=oci-agent \
IMAGE_TAG=1.0.0 \
REGISTRY_USERNAME='namespace/user@example.com' \
REGISTRY_AUTH_TOKEN='oci-auth-token' \
sh scripts/build_and_push_ocir.sh
```

Or run the same build/push through Terraform from your publisher machine using the `kreuzwerker/docker` provider:

```bash
cd deploy/image-publisher
terraform init
terraform apply \
  -var='oci_region=us-ashburn-1' \
  -var='ocir_region_key=iad' \
  -var='ocir_namespace=namespace' \
  -var='image_repository=oci-agent' \
  -var='image_tag=1.0.0' \
  -var='registry_username=namespace/user@example.com' \
  -var='registry_auth_token=oci-auth-token' \
  -var='platform=linux/arm64' \
  -var='create_repository=true' \
  -var='repository_compartment_id=ocid1.compartment...'
```

Do not run this image publisher module in the customer Resource Manager stack unless you are willing to include the source code, Docker build context, and Docker access there.

To create the OCIR repository first:

```bash
CREATE_REPOSITORY=true \
REPOSITORY_COMPARTMENT_ID=ocid1.compartment... \
OCIR_REGION_KEY=iad \
OCIR_NAMESPACE=namespace \
IMAGE_REPOSITORY=oci-agent \
IMAGE_TAG=1.0.0 \
PLATFORM=linux/arm64 \
REGISTRY_USERNAME='namespace/user@example.com' \
REGISTRY_AUTH_TOKEN='oci-auth-token' \
sh scripts/build_and_push_ocir.sh
```

## One-Click OCI Deployment

For customers, do not send this source folder. Send a Resource Manager stack zip plus the image location details.

1. Build and push your image:

```bash
OCIR_REGION_KEY=iad \
OCIR_NAMESPACE=namespace \
IMAGE_REPOSITORY=oci-agent \
IMAGE_TAG=1.0.0 \
PLATFORM=linux/arm64 \
REGISTRY_USERNAME='namespace/user@example.com' \
REGISTRY_AUTH_TOKEN='oci-auth-token' \
sh scripts/build_and_push_ocir.sh
```

2. Package the Resource Manager stacks:

```bash
sh scripts/package_resource_manager.sh
```

3. Upload one of the generated stacks to OCI Resource Manager:

```text
dist/oci-agent-container-instance-lb-resource-manager.zip
dist/oci-agent-all-in-one-rm-docker-container-resource-manager.zip
dist/oci-agent-all-in-one-devops-container-resource-manager.zip
dist/oci-agent-enterprise-ai-application-resource-manager.zip
```

Use `container-instance-lb` when the image is already in OCIR. Use `all-in-one-rm-docker-container` when Resource Manager should build the bundled source with Docker, push to OCIR, and deploy the Container Instance. Use `all-in-one-devops-container` when you prefer OCI DevOps build pipelines. Use `enterprise-ai-application` when you want to deploy the image through OCI Generative AI hosted Applications and Deployments.

### All-In-One Resource Manager Docker + Container Instance

This stack includes app source in the Resource Manager zip and uses Docker on the Resource Manager Terraform host to build and push the image to OCIR before creating the Container Instance. OCI documents Docker as preinstalled on the Resource Manager Terraform host.

### All-In-One DevOps + Container Instance

This stack creates OCI DevOps build resources, OCIR repository, Load Balancer, and Container Instance in one Resource Manager stack. It uses customer-selected existing networking instead of creating a VCN/subnet.

It requires the app source to be in a repository that OCI DevOps can access:

```text
Source connection type: GITHUB/GITLAB/BITBUCKET_CLOUD/VBS/DEVOPS_CODE_REPOSITORY
DevOps connection OCID: required for external Git providers
Source repository URL
Source repository branch
build_spec.yaml in the repo
Existing VCN name
Existing LB subnet name(s)
Existing container backend subnet name
Existing ONS topic OCID for DevOps notifications
Container platform: linux/arm64 or linux/amd64
```

The source repo must include a build spec that builds and pushes the image tag expected by the stack.

### Container Instance + Load Balancer

The stack creates a public OCI Load Balancer, private OCI Container Instance backend, VCN, subnet, security rules, and runs the container. The customer provides OCI values such as compartment, region, availability domain, GenAI project/compartment IDs, and image fields:

```text
OCIR region key: iad
OCIR namespace: namespace
Image repository: oci-agent
Image tag: 1.0.0
Container Instance shape: CI.Standard.A1.Flex for ARM images
```

The stack builds the final image URL as `iad.ocir.io/namespace/oci-agent:1.0.0`. Use the full image URL override only for non-OCIR registries or unusual image paths.

For private OCIR images, provide the registry username and auth token as stack variables. The Container Instance pulls the image during deployment.

The load balancer always exposes HTTP on port 80 and forwards to the container on port 8000. To expose HTTPS, provide these stack variables:

```text
TLS Public Certificate PEM
TLS Private Key PEM
TLS CA Chain PEM, optional
```

For OIDC, point your DNS name to the load balancer IP, set `app_base_url` to that HTTPS URL, and register the redirect URI in the IAM confidential app:

```text
Stack app_base_url: https://chat.example.com
IAM confidential app redirect URI: https://chat.example.com/auth/callback
```

The app uses OCI Resource Principal auth inside the Container Instance. Either create a dynamic group and policy yourself, or enable the stack variable `create_iam_policy` and provide the tenancy OCID so the stack can create:

```text
Allow dynamic-group <name> to use generative-ai-family in compartment id <genai_compartment_id>
```

After apply, Resource Manager outputs `oidc_redirect_uri`; copy that exact value into the IAM confidential app.

### Enterprise AI Application

The second stack captures the values required for OCI Generative AI hosted Applications and Deployments:

```text
Application name
OCIR image repository and tag
Identity domain URL
OAuth scope
OAuth audience
Scaling settings
Endpoint type
```

OCI documents hosted Applications and Deployments as managed Generative AI resources where an application defines runtime, networking, storage, and authentication, and a deployment points to an OCIR container image. At the moment this stack emits the exact values and manual steps because the hosted application/deployment Terraform resources are not visible in the OCI Terraform provider docs I found.

## Local HTTPS

To generate self-signed certs and make the container serve HTTPS:

```bash
python3 scripts/generate_certs.py
docker compose up --build -d
```

Open `https://localhost:8000`. Your browser will warn because the cert is self-signed.

## Auth

For the simplest deployment, leave this in `.env`:

```bash
AUTH_ENABLED=false
```

If you need OCI Identity Domain sign-in, run the one-time helper:

```bash
python3 scripts/provision_auth.py \
  --app-base-url "https://your-chat-host.example.com" \
  --compartment-id "ocid1.compartment..." \
  --identity-domain-issuer "https://idcs-...identity.oraclecloud.com" \
  --region "us-ashburn-1" \
  --apply
```

It writes `.env.generated`. Copy those auth values into `.env`, then restart:

```bash
docker compose restart app
```

In production, keep the container on HTTP and put HTTPS in front with a load balancer, API Gateway, or reverse proxy. Set `APP_BASE_URL` to the public HTTPS URL and `AUTH_COOKIE_SECURE=true`.

## Local Development

```bash
pip install -r requirements.txt
uvicorn backend.main:app --reload --host 0.0.0.0 --port 8000
```
