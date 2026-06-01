# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# All-In-One Resource Manager Docker + Container Instance Stack

This stack creates:

- OCIR container repository
- Docker image built from bundled source on the Resource Manager Terraform host
- Docker image pushed to OCIR
- OCI Load Balancer
- private OCI Container Instance backend

This stack includes source code in the Resource Manager zip under `source/`.

The stack uses customer-selected networking. It does not create a VCN or subnets. Provide:

- public load balancer subnet name(s), comma-separated
- private container backend subnet name
- VCN name
- security rules that allow LB traffic to the container port
- security rules that allow public traffic to the LB ports

Resource Manager Terraform host includes Docker according to OCI documentation. The stack uses the `kreuzwerker/docker` provider to build and push the image.

The Docker provider is configured to use a Docker-compatible socket. By default this stack points at the common rootless Podman socket:

```text
unix:///run/user/1000/podman/podman.sock
```

Override `docker_host` in the Resource Manager form if the Terraform host exposes a different Docker or Podman socket. OCIR registry auth is still required for both image push and Container Instance image pull.

TLS certificate inputs accept either base64-encoded PEM or raw PEM. Terraform auto-detects base64 values with `base64decode`; otherwise it normalizes raw PEM text before sending it to the load balancer certificate resource.
