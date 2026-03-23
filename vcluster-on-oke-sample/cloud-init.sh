#!/bin/sh

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

export OCI_CLI_AUTH=instance_principal
cluster_id=$(curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v1/instance/metadata/cluster_id)

#install OCI CLI
/usr/bin/dnf -y install oraclelinux-developer-release-el9
/usr/bin/dnf -y install python39-oci-cli

echo "export OCI_CLI_AUTH=instance_principal" >> ~/.bash_profile
echo "export OCI_CLI_AUTH=instance_principal" >> ~/.bashrc
echo "export OCI_CLI_AUTH=instance_principal" >> /home/opc/.bash_profile
echo "export OCI_CLI_AUTH=instance_principal" >> /home/opc/.bashrc

#install KUBECTL
mkdir -p /root/.kube
#/usr/bin/curl -LO https://dl.k8s.io/release/v1.33.0/bin/linux/amd64/kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

/usr/bin/install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

#install GO
/usr/bin/wget https://go.dev/dl/go1.24.5.linux-amd64.tar.gz
/usr/bin/rm -rf /usr/local/go && tar -C /usr/local -xzf go1.24.5.linux-amd64.tar.gz
/usr/bin/echo "export PATH=$PATH:/usr/local/go/bin" >> /root/.bashrc

#copy kubeconfig
oci ce cluster create-kubeconfig --cluster-id "${cluster_id}" --file /root/.kube/config --token-version 2.0.0  --kube-endpoint PUBLIC_ENDPOINT --auth instance_principal

#change context names
K=$(KUBECONFIG=/root/.kube/config kubectl config current-context)
KUBECONFIG=/root/.kube/config kubectl config rename-context $K host-vcluster

#copy kube config for opc user
mkdir /home/opc/.kube
cp /root/.kube/config /home/opc/.kube
chown -R opc:opc /home/opc/.kube

#install HELM
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
/usr/bin/bash get_helm.sh

#install VCLUSTER
#curl -L -o vcluster "https://github.com/loft-sh/vcluster/releases/download/v0.30.0/vcluster-linux-amd64" && sudo install -c -m 0755 vcluster /usr/local/bin && rm -f vcluster
curl -L -o vcluster "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64" && sudo install -c -m 0755 vcluster /usr/local/bin && rm -f vcluster

