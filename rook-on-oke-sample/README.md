# Rook on OKE

This repository provides the necessary Terraform configuration to deploy Rook on a fresh Oracle Kubernetes Engine (OKE) cluster. Rook is a suite of advanced workload controllers that extends Kubernetes with powerful features for application management, deployment, and operations.

This project can be deployed in two ways:
1.  **Manual Deployment**: Using Terraform CLI on your local machine.
2.  **Automated Deployment**: Using OCI Resource Manager.

## How It Works

The repository is structured as a Terraform project that installs Rook using its Helm chart.

-   **`main.tf`**: Main Terraform file that sets up the Helm release for Rook.
-   **`variables.tf`**: Defines the input variables for the Terraform configuration, such as the OKE cluster ID and compartment ID.
-   **`provider.tf`**: Configures the OCI and Kubernetes providers for Terraform.
-   **`rook-files/`**: Contains several example YAML files for the top 3 most use cases.

## How to Use

### Prerequisites

*   OCI tenancy
*   Your OCI user OCID, tenancy OCID, fingerprint, and private key.
*   The region where your OKE cluster is located.

### Manual Deployment (Terraform CLI)

1.  **Clone the repository:**
    ```sh
    git clone https://github.com/dranicu/rook-on-oke.git
    cd rook-on-oke
    ```

2.  **Create a `terraform.auto.tfvars` file and add the following variables:**
    ```tfvars
    tenancy_ocid      = "ocid1.tenancy.oc1..your_tenancy_ocid"
    current_user_ocid = "ocid1.user.oc1..your_user_ocid"
    compartment_ocid  =
    # fingerprint      = "your_api_key_fingerprint"
    # private_key_path = "/path/to/your/oci_api_key.pem"
    region            = "your-oci-region"
    ```

3.  **Initialize Terraform:**
    ```sh
    terraform init
    ```

4.  **Plan and apply the configuration:**
    ```sh
    terraform plan
    terraform apply
    ```

### Automated Deployment (OCI Resource Manager)

To deploy using OCI Resource Manager, click the button below. This will take you to the OCI console to create a new stack.

[![Deploy to OCI](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/dranicu/rook-on-oke/archive/refs/heads/main.zip)

1.  Click the "Deploy to OCI" button.
2.  If you are not already logged in, log in to your OCI account.
3.  Choose the compartment for the stack.
4.  Accept the terms and conditions.
5.  Click "Next".
6.  Fill in the required variables, including your cluster\_id and compartment\_id.
7.  Click "Next".
8.  Click "Create" to create the stack.
9.  Once the stack is created, click "Apply" to deploy Rook to your OKE cluster.

## Post-Installation

Once Rook is deployed, you can verify the installation by checking the pods in the `rook-ceph` namespace:

```sh
kubectl get pods -n rook-ceph
```

You can now start using Rook's advanced workloads and features. For more information on how to use Rook, refer to the [official Rook documentation](https://rook.io/docs/).
