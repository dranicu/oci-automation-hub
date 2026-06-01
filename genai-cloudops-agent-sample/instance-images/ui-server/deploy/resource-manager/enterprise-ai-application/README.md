# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
# OCI Agent Enterprise AI Application Stack

This package captures the values needed to deploy the OCI Agent image as an OCI Generative AI hosted application.

It can optionally create the IAM Identity Domain confidential app used by Enterprise AI authentication.

OCI documentation currently describes hosted Applications and Deployments through the Console/API flow. If Terraform provider resources for hosted applications become available in your provider version, replace the output-only `main.tf` with those native resources.

Use the stack outputs when creating:

- OCI Generative AI Application
- Hosted Deployment
- Deployment artifact image
- Identity domain authentication settings
- IAM confidential app client id, audience, and scope
