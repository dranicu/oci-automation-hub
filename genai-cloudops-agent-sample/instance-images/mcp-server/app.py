# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
#!/usr/bin/env python3


from __future__ import annotations
import contextlib
import logging
import os
from typing import Any, Optional
import oci
import oci.generative_ai_agent_runtime
from pydantic import BaseModel, Field
import time
from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

load_dotenv()
AGENT_ENDPOINT_ID = os.getenv("AGENT_ENDPOINT_ID")
TENANCY_ID = os.getenv("TENANCY_OCID")
SERVER_NAME = "oci-compute-mcp-server"
PORT = 8080
allowed_hosts = ["0.0.0.0:*", "localhost:*"]
allowed_origins = ["*"]

logging.basicConfig(level="DEBUG")
logger = logging.getLogger("mcp_server_logs")

mcp = FastMCP(
    SERVER_NAME,
    json_response=True,
    stateless_http=True,
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=False,  # Disable for testing in environments without proper DNS setup
        allowed_hosts=allowed_hosts,
        allowed_origins=allowed_origins,
    ),
)

# ---------------------------------------------------
# OCI Auth (Resource Principal ONLY)
# ---------------------------------------------------
try:
    signer = oci.auth.signers.get_resource_principals_signer()
    config = {}
    logger.info("Using OCI Resource Principal for authentication")
except Exception as e:
    logger.error("Failed to initialize Resource Principal auth")
    raise e

# ---------------------------------------------------
# OCI Clients
# ---------------------------------------------------

compute_client = oci.core.ComputeClient(config=config, signer=signer)
storage_client = oci.core.BlockstorageClient(config=config, signer=signer)
identity_client = oci.identity.IdentityClient(config=config, signer=signer)
network_client = oci.core.VirtualNetworkClient(config=config, signer=signer)
os_mgmt_client = oci.os_management_hub.ManagedInstanceClient(config=config, signer=signer)
monitoring_client = oci.monitoring.MonitoringClient(config=config, signer=signer)
compute_instance_agent_client = oci.compute_instance_agent.ComputeInstanceAgentClient(config=config, signer=signer)
agent_runtime_client = oci.generative_ai_agent_runtime.GenerativeAiAgentRuntimeClient(config=config, signer=signer)
vulnerability_scanning_client = oci.vulnerability_scanning.VulnerabilityScanningClient(config=config, signer=signer)
agent_runtime_client = oci.generative_ai_agent_runtime.GenerativeAiAgentRuntimeClient(config=config, signer=signer)

# ---------------------------------------------------
# ENV Variables
# ---------------------------------------------------

@mcp.tool()
def list_compartments(
    compartmentId: Optional[str] = None,
    include_subtree: bool = False,
) -> dict[str, Any]:
    """
    List compartments visible to the current OCI principal.

    Use this tool as a discovery step before other OCI operations that require a compartment OCID.

    Behavior:
    - If compartmentId is omitted, the tool lists compartments under the tenancy root.
    - If compartmentId is provided, the tool lists compartments under that parent compartment.
    - If include_subtree is True, the response includes child compartments recursively beneath the selected compartment.
    - If include_subtree is False, only the immediate child compartments are returned.

    This tool is useful in tool chains when the LLM needs to:
    - find a tenancy root compartment
    - traverse from a parent compartment to child compartments
    - resolve the correct compartment before listing resources like VCNs, subnets, images, or instances

    Args:
        compartmentId: Optional OCID of the parent compartment to query.
            If omitted, defaults to the tenancy OCID.
        include_subtree: Whether to include nested child compartments recursively.

    Returns:
        dict: JSON-safe result with:
            - status: "success" or "error"
            - compartmentid_used: the OCID actually queried
            - compartments: list of compartment objects on success
            - message: error details on failure
    """
    if not identity_client:
        return {
            "status": "error",
            "message": "OCI identity client is not initialized.",
        }

    parent_compartmentid = compartmentId or TENANCY_ID
    if not parent_compartmentid:
        return {
            "status": "error",
            "message": "No compartmentId was provided and TENANCY_ID is not configured.",
        }

    try:
        response = identity_client.list_compartments(
            compartment_id=parent_compartmentid,
            compartment_id_in_subtree=include_subtree,
            access_level="ACCESSIBLE",
        )

        compartments = [
            {
                "id": getattr(c, "id", None),
                "name": getattr(c, "name", None),
                "description": getattr(c, "description", None),
                "lifecycle_state": getattr(c, "lifecycle_state", None),
                "compartmentid": getattr(c, "compartment_id", None),
            }
            for c in response.data
        ]

        return {
            "status": "success",
            "compartmentid_used": parent_compartmentid,
            "include_subtree": include_subtree,
            "compartments": compartments,
        }

    except Exception as e:
        logger.exception("Error listing compartments")
        return {
            "status": "error",
            "message": f"Error listing compartments: {str(e)}",
            "compartmentid_used": parent_compartmentid,
        }

@mcp.tool()
def list_availability_domains() -> dict[str, Any]:
    """
    List availability domains in the region. Will always default to the current region in the config file.

    Use this tool to get the details of the avilability domains when you need to
    place resources in a valid availability domain. This is commonly used in tool
    chains before launching compute instances, creating block volumes, or selecting
    fault domains.

    Behavior:
    - Will always return the availability domains scoped to the tenancy.

    Args:
        None

    Returns:
        dict: JSON-safe result with:
            - status: "success" or "error"
            - availability_domains: list of availability domain objects on success
            - message: error details on failure
    """
    if not identity_client:
        return {
            "status": "error",
            "message": "OCI identity client is not initialized.",
        }

    scope_id = TENANCY_ID

    try:
        response = identity_client.list_availability_domains(
            compartment_id=scope_id
        )

        domains = [
            {
                "name": getattr(domain, "name", None),
                "id": getattr(domain, "id", None),
                "compartmentid": getattr(domain, "compartmentid", None),
            }
            for domain in response.data
        ]

        return {
            "status": "success",
            "availability_domains": domains
        }

    except Exception as e:
        logger.exception("Error listing availability domains")
        return {
            "status": "error",
            "message": f"Error listing availability domains: {str(e)}"
        }

@mcp.tool()
def list_subnets(compartmentId: str) -> dict[str, Any]:
    """
    List subnets visible to the current OCI principal in the selected compartment scope.

    Use this tool after resolving the correct compartment OCID when you need to:
    - choose a subnet for launching a compute instance or container instance
    - find a subnet for attaching a VNIC
    - inspect network placement before provisioning OCI resources
    - the compartmentid can be any compartment, including the root or tenancy compartment.

    Behavior:
    - The tool returns subnet metadata including the subnet OCID, display name,
      CIDR block, VCN OCID, availability domain, and lifecycle state.

    Args:
        compartmentId: OCID of the compartment to query.

    Returns:
        dict: JSON-safe result with:
            - status: "success" or "error"
            - compartmentid_used: the OCID actually queried
            - subnets: list of subnet objects on success
            - message: error details on failure
    """
    if not network_client:
        return {
            "status": "error",
            "message": "OCI network client is not initialized.",
        }

    scope_id = compartmentId or TENANCY_ID
    if not scope_id:
        return {
            "status": "error",
            "message": "No compartmentid was provided and TENANCY_ID is not configured.",
        }

    try:
        response = network_client.list_subnets(compartment_id=scope_id)

        subnets = [
            {
                "id": getattr(subnet, "id", None),
                "display_name": getattr(subnet, "display_name", None),
                "cidr_block": getattr(subnet, "cidr_block", None),
                "vcn_id": getattr(subnet, "vcn_id", None),
                "availability_domain": getattr(subnet, "availability_domain", None),
                "lifecycle_state": getattr(subnet, "lifecycle_state", None),
            }
            for subnet in response.data
        ]

        return {
            "status": "success",
            "compartmentid_used": scope_id,
            "subnets": subnets,
        }

    except Exception as e:
        logger.exception("Error listing subnets")
        return {
            "status": "error",
            "message": f"Error listing subnets: {str(e)}",
            "compartmentid_used": scope_id,
        }

@mcp.tool()
def list_instances(compartmentid: str):
    """
    List all instances in a compartment with Instance ID, display name, lifecycle state, availability domain, shape, and time created.

    Args:
        compartmentid (str): The OCID of the compartment.
    
    Returns:
        dict: A dictionary containing the status and a list of instances if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    
    try:
        response = compute_client.list_instances(
            compartment_id=compartmentid
        )
        
        instances = []
        for instance in response.data:
            instances.append({
                "id": instance.id,
                "display_name": instance.display_name,
                "lifecycle_state": instance.lifecycle_state,
                "availability_domain": instance.availability_domain,
                "shape": instance.shape,
                "time_created": instance.time_created.isoformat()
            })
        
        return {"status": "success", "instances": instances}
    except Exception as e:
        return f"Error listing instances: {str(e)}"


@mcp.tool()
def get_instance(instanceId: str):
    """Get details of a specific instance using its Instance ID"""
    if not compute_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    
    try:
        response = compute_client.get_instance(instance_id=instanceId)
        instance = response.data
        # Try to get OCPU and memory info from shape_config or instance
        ocpus = None
        memory_in_gbs = None
        if hasattr(instance, "shape_config") and instance.shape_config:
            ocpus = getattr(instance.shape_config, "ocpus", None)
            memory_in_gbs = getattr(instance.shape_config, "memory_in_gbs", None)
        elif hasattr(instance, "ocpus"):
            ocpus = getattr(instance, "ocpus", None)
        elif hasattr(instance, "memory_in_gbs"):
            memory_in_gbs = getattr(instance, "memory_in_gbs", None)
        # Try to get instance agent id
        agent_id = getattr(instance, "instance_agent_id", None)
        instance_info = {
            "id": instance.id,
            "display_name": instance.display_name,
            "lifecycle_state": instance.lifecycle_state,
            "availability_domain": instance.availability_domain,
            "compartmentid": instance.compartmentid,
            "shape": instance.shape,
            "region": instance.region,
            "time_created": instance.time_created.isoformat(),
            "image_id": instance.image_id if hasattr(instance, 'image_id') else None,
            "metadata": instance.metadata if hasattr(instance, 'metadata') else {},
            "ocpus": ocpus,
            "memory_in_gbs": memory_in_gbs,
            "instance_agent_id": agent_id
        }
        return {"status": "success", "instance": instance_info}
    except Exception as e:
        return f"Error getting instance: {str(e)}"

@mcp.tool()
def stop_instance(instanceId: str, force: bool = False):
    """
    Stop an OCI instance (soft or hard) using its Instance ID.

    Args:
        instanceId (str): The OCID of the instance.
        force (bool, optional): If True, perform a hard stop. If False, perform a soft stop.
    
    Returns:
        dict: A dictionary containing the status and stop details if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured."}
    try:
        response = compute_client.instance_action(instanceId, action="SOFTSTOP" if not force else "STOP")
        return {"status": "success", "message": f"Instance {instanceId} stop initiated."}
    except Exception as e:
        return f"Error stopping instance: {str(e)}"

@mcp.tool()
def get_compartmentid_by_name(name: str):
    """
    Get the OCID of a compartment by its name.

    Args:
        name (str): The name of the compartment.
    
    Returns:
        dict: A dictionary containing the status and compartment ID if successful.
        str: An error message if the operation fails.
    """
    if not identity_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    try:
        response = identity_client.list_compartments(
            compartment_id=config["tenancy"],
            compartmentid_in_subtree=False
        )
        for compartment in response.data:
            if compartment.name == name:
                return {"status": "success", "compartmentid": compartment.id}
        return {"status": "error", "message": f"Compartment with name '{name}' not found."}
    except Exception as e:
        return f"Error searching for compartment: {str(e)}"


@mcp.tool()
def get_instances_by_display_name(compartmentid: str, display_name: str):
    """
    Return all instances in a compartment whose display name matches the given substring (case-insensitive), with full details.

    Args:
        compartmentid (str): The OCID of the compartment.
        display_name (str): The display name substring to match.
    
    Returns:
        dict: A dictionary containing the status and a list of matching instances if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured. Please run configure_oci first."}
    try:
        response = compute_client.list_instances(compartment_id=compartmentid)
        normalized_input = display_name.strip().lower()
        matches = []
        for instance in response.data:
            if instance.display_name and normalized_input in instance.display_name.strip().lower():
                # Try to get OCPU and memory info from shape_config or instance
                ocpus = None
                memory_in_gbs = None
                if hasattr(instance, "shape_config") and instance.shape_config:
                    ocpus = getattr(instance.shape_config, "ocpus", None)
                    memory_in_gbs = getattr(instance.shape_config, "memory_in_gbs", None)
                elif hasattr(instance, "ocpus"):
                    ocpus = getattr(instance, "ocpus", None)
                elif hasattr(instance, "memory_in_gbs"):
                    memory_in_gbs = getattr(instance, "memory_in_gbs", None)
                agent_id = getattr(instance, "instance_agent_id", None)
                matches.append({
                    "id": instance.id,
                    "display_name": instance.display_name,
                    "lifecycle_state": instance.lifecycle_state,
                    "availability_domain": instance.availability_domain,
                    "compartmentid": instance.compartmentid,
                    "shape": instance.shape,
                    "region": instance.region,
                    "time_created": instance.time_created.isoformat(),
                    "image_id": instance.image_id if hasattr(instance, 'image_id') else None,
                    "metadata": instance.metadata if hasattr(instance, 'metadata') else {},
                    "ocpus": ocpus,
                    "memory_in_gbs": memory_in_gbs,
                    "instance_agent_id": agent_id
                })
        if matches:
            return {"status": "success", "instances": matches}
        else:
            available_names = [inst.display_name for inst in response.data if inst.display_name]
            return {
                "status": "error",
                "message": f"No instances found with display name containing '{display_name}'.",
                "available_instance_names": available_names
            }
    except Exception as e:
        return f"Error searching for instances: {str(e)}"

@mcp.tool()
def start_instance(instance_id: str):
    """
    Start an OCI instance using its Instance ID.

    Args:
        instance_id (str): The OCID of the instance.
    
    Returns:
        dict: A dictionary containing the status and start details if successful.
        str: An error message if the operation fails.
    """
    if not compute_client:
        return {"status": "error", "message": "OCI not configured."}
    try:
        response = compute_client.instance_action(instance_id, "START")
        return {"status": "success", "message": f"Instance {instance_id} start initiated."}
    except Exception as e:
        return f"Error starting instance: {str(e)}"

@mcp.tool()
def rag_instructions(user_message: str):
    """
    Query the RAG system for citations, Runbook and appropriate answers based on the knowledge base.

    Args:
        user_message (str): The query to send to the RAG agent.

    Returns:
        dict: Status and response from the agent.
    """
    try:
        # Create a new session for each query
        session_response = agent_runtime_client.create_session(
            agent_endpoint_id=AGENT_ENDPOINT_ID,
            create_session_details=oci.generative_ai_agent_runtime.models.CreateSessionDetails(
                display_name="MCP_RAG_Session"
            )
        )
        session_id = session_response.data.id
        # Send chat message
        chat_details = oci.generative_ai_agent_runtime.models.ChatDetails(
            user_message=user_message,
            session_id=session_id,
            should_stream=False
        )
        chat_response = agent_runtime_client.chat(
            agent_endpoint_id=AGENT_ENDPOINT_ID,
            chat_details=chat_details
        )
        
        # Extract the response message
        response_message = chat_response.data.message.content.text
        
        return {"status": "success", "response": response_message}
    except Exception as e:
        return f"Error querying RAG: {str(e)}"


@mcp.tool()
def reboot_instance(instanceId: str):
    """
    Reboot an OCI instance using SOFTRESET.

    Args:
        instanceId (str): The OCID of the instance

    Returns:
        dict: Reboot status
    """
    try:
        response = compute_client.instance_action(
            instance_id=instanceId,
            action="SOFTRESET"
        )

        lifecycle_state = response.data.lifecycle_state

        return {
            "status": "success",
            "instance_id": instanceId,
            "action": "SOFTRESET",
            "lifecycle_state": lifecycle_state,
            "message": "Reboot initiated successfully"
        }

    except Exception as e:
        return {
            "status": "error",
            "message": str(e)
        }

@mcp.tool()
def run_remote_command(
    compartmentId: str,
    instanceId: str,
    command: str,
    displayName: str = "RemoteCommandExecution",
    timeoutSeconds: int = 600,
    pollIntervalSeconds: int = 5,
) -> dict:
    """
    Submit a remote command to an OCI Compute instance using OCI Compute Instance Agent Run Command.
    The tool will execute the command and poll for its completion, returning the final status.
    Args:        compartmentId (str): The OCID of the compartment.
        instanceId (str): The OCID of the instance to run the command on.
        command (str): The command to execute on the instance.
        displayName (str, optional): A display name for the command execution. Defaults to "RemoteCommandExecution".
        timeoutSeconds (int, optional): Maximum time to wait for command completion in seconds. Defaults to 600 seconds (10 minutes).
        pollIntervalSeconds (int, optional): Time interval between status checks in seconds. Defaults to 5 seconds.
    Returns:        dict: A dictionary containing the final status of the command execution and the command ID if successful.
    """

    try:
        # Submit command
        details = oci.compute_instance_agent.models.CreateInstanceAgentCommandDetails(
            compartment_id=compartmentId,
            display_name=displayName,
            execution_time_out_in_seconds=timeoutSeconds,
            target=oci.compute_instance_agent.models.InstanceAgentCommandTarget(
                instance_id=instanceId
            ),
            content=oci.compute_instance_agent.models.InstanceAgentCommandContent(
                source=oci.compute_instance_agent.models.InstanceAgentCommandSourceViaTextDetails(
                    source_type="TEXT",
                    text=command,
                ),
                command_string=command,
            ),
        )

        response = compute_instance_agent_client.create_instance_agent_command(
            create_instance_agent_command_details=details
        )

        command_id = response.data.id

        # Poll for completion
        start_time = time.time()

        while True:
            execution = compute_instance_agent_client.get_instance_agent_command_execution(
                instance_agent_command_id=command_id,
                instance_id=instanceId,
            ).data

            status = execution.lifecycle_state

            if status in ["SUCCEEDED", "FAILED", "CANCELED"]:
                return {
                    "status": status,
                    "commandId": command_id,
                }

            if time.time() - start_time > timeoutSeconds:
                return {
                    "status": "timeout",
                    "commandId": command_id,
                }

            time.sleep(pollIntervalSeconds)

    except Exception as e:
        return {
            "status": "error",
            "message": str(e),
        }

# ----------------------------
# MCP input / output schemas
# ----------------------------

class GetAlarmRequest(BaseModel):
    compartmentId: str = Field(
        ...,
        description="OCI compartment OCID to search for alarms."
    )
# ----------------------------
# MCP tool definition
# ----------------------------

@mcp.tool(name="getAlarm")
def getAlarm(request: GetAlarmRequest) -> Any:
    """
    Retrieves the alarms details in the specified compartment and returns the unique resource display names that are currently in the FIRING state, along with counts.

    Input:
        compartmentId: OCI compartment OCID.

    Output:
        status: success or error
        firingInstances: unique resource display names currently FIRING
        count: number of unique firingInstances
        matchedAlarms: number of alarms found in FIRING state
        message: present only on error
    """
    try:

        alarms = monitoring_client.list_alarms_status(
            compartment_id=request.compartmentId
        ).data or []

        return alarms

    except Exception as e:
        return e


# ----------------------------
# Snake_case client wrapper
# ----------------------------

def get_alarm(client, compartment_id: str):
    """
    Client-side snake_case wrapper for calling the MCP tool.

    Server tool name:
        getAlarm
    """
    return client.call_tool(
        "getAlarm",
        {
            "compartmentId": compartment_id
        }
    )

async def healthz(_: Any) -> JSONResponse:
    return JSONResponse({"status": "ok", "server": SERVER_NAME})

@contextlib.asynccontextmanager
async def lifespan(app: Starlette):
    async with mcp.session_manager.run():
        yield

app = Starlette(
    routes=[
        Route("/healthz", healthz, methods=["GET"]),
        Mount("/", app=mcp.streamable_http_app()),
    ],
    lifespan=lifespan,
)

if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=PORT, log_level="debug")