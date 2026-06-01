# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# Image Publisher Terraform

This Terraform module is for the publisher machine, not the customer Resource Manager deployment.

It uses the `kreuzwerker/docker` provider:

- `docker_image` builds the local Docker image.
- `docker_registry_image` pushes it to OCIR.

Requirements on the machine running Terraform:

- Docker
- Access to this source folder
- OCIR username and OCI auth token
- OCI Terraform provider credentials if `create_repository=true`

Set `create_repository=true` and `repository_compartment_id` when Terraform should create the OCIR repository before pushing.

Example:

```bash
cd deploy/image-publisher
terraform init
terraform apply \
  -var='ocir_region_key=iad' \
  -var='oci_region=us-ashburn-1' \
  -var='ocir_namespace=namespace' \
  -var='image_repository=oci-agent' \
  -var='image_tag=1.0.0' \
  -var='registry_username=namespace/user@example.com' \
  -var='registry_auth_token=...' \
  -var='platform=linux/amd64' \
  -var='create_repository=true' \
  -var='repository_compartment_id=ocid1.compartment...'
```

Then use the output values in one of the Resource Manager deployment stacks.
