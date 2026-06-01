<!--
Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
-->

# OCI GenAI Cloud Operations Agent

This repository provides the necessary Terraform configuration and container deployment artifacts to deploy an AI-powered Cloud Operations Assistant on Oracle Cloud Infrastructure (OCI). The solution combines OCI Generative AI Agents, Model Context Protocol (MCP) tooling, OCI Logging, Streaming, and Retrieval-Augmented Generation (RAG) capabilities to create an intelligent operational assistant for cloud infrastructure management and troubleshooting.

The solution deploys:

* OCI Generative AI Agent
* Knowledge Base with RAG integration
* MCP Server for OCI operational tooling
* Application Server UI
* OCI Logging and Streaming resources
* Test compute infrastructure
* OCI Container Registry repositories

# How It Works

The repository is structured as a Terraform-based deployment project combined with containerized application services.

* `infra-stack/`: 
  * `kb_file`: Sample process document for handling high cpu usage alerts.
  * `modules`: Reusable Terraform modules.
  * `main.tf`: Main Terraform file that sets up the infrastructure components.
  * `output.tf`: Output Terraform file to record output variables for other RMS stack.
  * `schema.yaml`: OCI Resource Manager schema for guided deployment.
  * `variable.tf`: Configure the OCI variables for the infrastructure components.
* `instance_images/`:
  * `mcp-server/`:
    * `app.py`: Application file for the MCP server.
    * `Dockerfile`: Main docker file to create the application container image:
    * `README.md`: Sample readme file for isolated instance deployment.
    * `requirements.txt`: Requirements file for python packages needed for the deployment.
  * `ui-server/`:
    * `backend/`: Applicatino backend files to handle authentication, agent configuration, storage configuration etc.
    * `certs/`: Local application certificates.
    * `deploy/`: Terraform modules for standalone application development.
    * `frontend/`: Application UI.
    * `scripts/`: Shell Scripts to setup application for local deployment.
    * `app.py`: Application file for the frontend server.
    * `build_spec.yaml`: Container build specifications.
    * `docker-compose.yml`: Docker Compose configurations.
    * `Dockerfile`: Main docker file to create the application container image:
    * `README.md`: Sample readme file for isolated instance deployment.
    * `requirements.txt`: Requirements file for python packages needed for the deployment.
  * `README.md`: Instructions file to create and store the container images in OCIR created in last deployment step.
* `container-instances-stack/`:
  * `modules`: Reusable Terraform modules.
  * `main.tf`: Main Terraform file that sets up the container instances.
  * `schema.yaml`: OCI Resource Manager schema for guided deployment.
  * `variable.tf`: Configure the OCI variables for the infrastructure components.
  * `version.tf`: Terraform file that controls the TF provider version for OCI.

The solution works as follows:

1. A user interacts with the Application Server UI.
2. Requests are sent to the OCI Generative AI Agent.
3. The agent determines whether operational tooling is required.
4. If needed, the agent invokes MCP tools exposed through the MCP Server.
5. The MCP Server interacts with OCI services using OCI SDKs and APIs.
6. Results are returned back to the AI Agent.
7. The AI Agent generates a contextual response for the user.

# Solution Deployment
The solution is deployed in three steps. 

1. Deploy the Infrastructure Stack
2. Build and Push the MCP Server and Application container images.
3. Deploy the Container Instance Stack

## Prerequisites

* Docker installed on the workstation
* Access to OCI Container Registry (OCIR)
* Auth token for OCI registry login
* Existing VCN with Public and Private Subnets
  * Public Subnet
    * Should have port **443** allowed for LB Listener Deployment
  * Private Subnet
    * Should have port **8000** allowed from public subnet for LB to Application Communication
    * Should have port **8080** allowed for Application Container to MCP Server Communication

## Part 1: Deploy the Infrastructure Stack

**Note:** The following steps deploy the base OCI infrastructure, AI Agent resources, logging pipeline, and container registry repositories required for the solution.

1. Clone the repository from GitHub.
2. Use Oracle Resource Manager to create and apply the stack.
    * Using the hamburger menu, go to Oracle Resource Manager
    * Choose `Stacks`
    * Click `Create stack`
    * Select `My configuration`
    * In the configuration section select folder
    * Upload the `infrastructure-stack` from the repository
    * Provide a meaningful stack name
    * Click `Next`
    * Choose the target `compartment`
    * Provide the required variables:
        * Display name prefix
        * Component description
        * Availability Domain
        * Instance Shape
        * Image ID
        * VCN Compartment
        * VCN and subnet information
        * SSH public key
    * Click `Next`
    * Select `Run apply`
    * Click `Create`
3. Wait for the stack deployment to complete successfully, Gen AI Agent creation and Document ingestion can take over 30 minutes depending on the region you are deploying in.
4. After deployment, collect the outputs from the stack:
    * MCP OCIR repository path
    * Application OCIR repository path
    * Agent Endpoint
    * Stream OCIDs

## Part 2: Create and Push the OCIR Images

The solution uses two container images:

* MCP Server image
* Application Server image

### Prerequisites

* Docker installed
* Access to OCI Container Registry (OCIR)
* Auth token for OCI registry login

### Build and Push Images

1. Login to OCIR
   ~~~
   docker login <region-key>.ocir.io
   ~~~

    Example:
    ~~~
    docker login iad.ocir.io
    ~~~
    **Use**:
      - OCI Username
      - OCI auth token
2. Navigate to the instance-image directory:
      ~~~
      cd instance-images
      ~~~
3. Build and Push MCP Server Image
   1. Navigate to the MCP Server directory:
        ~~~
        cd mcp-server
        ~~~
   2. Build and tag the mcp server image
        ~~~
        docker build . -t <mcp-repository-path>:latest
        ~~~
   3. Push the mcp server image
        ~~~
        docker push <mcp-repository-path>:latest
        ~~~
4. Build and Push Application Server Image
    1. Navigate to the Application Server directory:
        ~~~
        cd ui-server
        ~~~
    2. Build and tag the mcp server image
        ~~~
        docker build . -t 'application-server-repository-path':latest
        ~~~
    3. Push the application server image
        ~~~
        docker push 'application-server-repository-path':latest
        ~~~

## Part 3: Deploy the Application and MCP Containers

Once the container images are available in OCIR, deploy the runtime components.

### **Deployment Requirements**

You will need:

* Agent Endpoint from Part 1
* OCIR image paths from Part 2
* OCI subnet configuration

### Recommended Deployment Topology

- MCP Server
    - Deploy in:
      - `Private subnet`
- Application Server
  - Deploy in:
    - `Private subnet`
- Load Balancer
  - Deploy in:
    - `Public subnet`

### Deploy with OCI Resource Manager

1. Use Oracle Resource Manager to create and apply the stack.
    * Using the hamburger menu, go to Oracle Resource Manager
    * Choose `Stacks`
    * click `Create stack`
    * Select `My configuration`
    * In the configuration section select folder
    * Upload the `container-instance-stack` directory from the repository
    * Provide a meaningful stack name
    * Click `Next`
    * Provide the `Display Name Prefix`.
    * Choose the target `compartment`
    * Choose the Availability Domain for the container instance deployment.
    * Select the `Identity Domain` to create the Integrated Application for application authentication.
    * Provide the required variables for Container Instance deployment:
        * Container Configuration
          * Shape
          * OCPU
          * Memory
        * VCN information.
        * VCN Name
        * Subnet for Load Balancer Deployment (**Public Subnet Preferred**)
        * MCP Container Image URL from last step.
        * Subnet for MCP Server Deployment (**Private Subnet Preferred**)
        * RAG Agent endpoint from first stack deployment.
        * Application Container image URL from last step.
        * Subnet for Application UI (**Private Subnet Preferred**)
    * Click `Next`
    * Select `Run apply`
    * Click `Create`
2. Wait for the stack deployment to complete successfully.
3. After deployment, validate the load balancer information
   1. Check the public IP address of the load balancer.
   2. Open a new browser window to the following address
      1. https://**Load Balancer Public IP**

# Post-Installation

Once the deployment is complete, the AI-powered DevOps Agent can be used for:

* OCI operational troubleshooting
* Infrastructure visibility
* Monitoring and alarm inspection
* Log analysis
* AI-assisted DevOps workflows
* Natural language operational automation

# Clean-Up

1. Navigate to Oracle Resource Manager
2. Select the deployed stack
3. Click Destroy