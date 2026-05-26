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
  * `CloudOps_Infra_RMS`.zip: Complete Resource Manager stack to deploy solution infrastructure components.
  * `main.tf`: Main Terraform file that sets up the infrastructure components.
  * `output.tf`: Output Terraform file to record output variables for other RMS stack.
  * `schema.yaml`: OCI Resource Manager schema for guided deployment.
  * `variable.tf`: Configure the OCI variables for the infrastructure components.
* `container_images/`:
  * `MCP_Server/`:
    * `app.py`: Application file for the MCP server.
    * `Dockerfile`: Main docker file to create the application container image:
    * `README.md`: Sample readme file for isolated instance deployment.
    * `requirements.txt`: Requirements file for python packages needed for the deployment.
  * `Agent and UI/`:
    * `app.py`: Application file for the frontend server.
    * `Dockerfile`: Main docker file to create the application container image:
    * `README.md`: Sample readme file for isolated instance deployment.
    * `requirements.txt`: Requirements file for python packages needed for the deployment.
  * `README.md`: Instructions file to create and store the container images in OCIR created in last deployment step.
* `container-instances-stack/`:
  * `modules`: Reusable Terraform modules.
  * `Container_Instance_RMS.zip`: Complete Resource Manager stack to deploy MCP and frontend application container instances.
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

## Part 1: Deploy the Infrastructure Stack

**Note:** The following steps deploy the base OCI infrastructure, AI Agent resources, logging pipeline, and container registry repositories required for the solution.

1. Clone the repository from GitHub.
2. Use Oracle Resource Manager to create and apply the stack.
    * using the hamburger menu, go to Oracle Resource Manager
    * choose `Stacks`
    * click `Create stack`
    * select `My configuration`
    * in the configuration section select folder
    * upload the `infrastructure-stack` from the repository
    * provide a meaningful stack name
    * click `Next`
    * choose the target `compartment`
    * provide the required variables:
        * Display name prefix
        * Component description
        * Availability Domain
        * Instance Shape
        * Image ID
        * VCN Compartment
        * VCN and subnet information
        * SSH public key
    * click `Next`
    * select `Run apply`
    * click `Create`
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
    - `Public subnet`
  - Expose:
    - **TCP Port 8080**

### Deploy with OCI Resource Manager

1. Use Oracle Resource Manager to create and apply the stack.
    * using the hamburger menu, go to Oracle Resource Manager
    * choose `Stacks`
    * click `Create stack`
    * select `My configuration`
    * in the configuration section select folder
    * upload the `container-instance-stack` from the repository
    * provide a meaningful stack name
    * click `Next`
    * choose the target `compartment`
    * provide the required variables:
        * Display Name Prefix
        * Availability Domain
        * Container Configuration
          * Shape
          * OCPU
          * Memory
        * VCN information.
        * MCP Container Image URL from last section.
        * Subnet for MCP Container (**Private Subnet Preferred**)
        * Skip Assigning a Public IP
        * RAG Agent endpoint from first stack deployment.
        * Application Container image URL from last section.
        * Subnet for Application UI (**Public Subnet Preferred**)
        * Regional GenAI Endpoint (**Defaults to Ashburn, change if needed.**)
        * GenAI Model ID (**Defaults to xAI.Grok.4.3, change if needed.**)
        **`Next`** If you are deploying in a region other than Ashburn, please make sure that the AI Model defined here is available in the region. Use following URL to validate the endpoint and models by region. 

        [Generative AI Models by Region](https://docs.oracle.com/en-us/iaas/Content/generative-ai/model-endpoint-regions.htm)

    * click `Next`
    * select `Run apply`
    * click `Create`
1. Wait for the stack deployment to complete successfully.
2. After deployment, validate the container information
   1. View Application container instance IP address
   2. Open a new browser window to the following address
      1. http://**application server public IP**:8080

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