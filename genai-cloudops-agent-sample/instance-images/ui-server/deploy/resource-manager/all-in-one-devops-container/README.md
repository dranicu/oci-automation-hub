# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# All-In-One DevOps + Container Instance Stack

This stack creates:

- OCI DevOps project
- OCIR container repository
- OCI DevOps build pipeline
- Managed Build stage
- Deliver Artifact stage
- Optional Build Run
- OCI Load Balancer
- private OCI Container Instance backend

The source code must be in a Git/OCI DevOps repository that OCI DevOps can access.

The stack uses customer-selected networking. It does not create a VCN or subnets. Provide:

- public load balancer subnet name(s), comma-separated
- private container backend subnet name
- VCN name
- security rules that allow LB traffic to the container port
- security rules that allow public traffic to the LB ports
- an existing ONS notification topic for OCI DevOps project notifications

The repository must include `build_spec.yaml`. A minimal build spec should build and push `${IMAGE}` and define an artifact named `container-image`.

This stack waits for Terraform resource creation, but OCI DevOps build completion and Container Instance image pull timing can still require a second apply if the image tag is not available when Container Instance creation starts.
