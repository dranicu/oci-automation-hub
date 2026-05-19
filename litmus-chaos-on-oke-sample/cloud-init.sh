#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

mkdir -p /etc/crio/crio.conf.d
echo "[crio]" > /etc/crio/crio.conf.d/11-default.conf
echo "  [crio.image]" >> /etc/crio/crio.conf.d/11-default.conf
echo "    short_name_mode=\"disabled\"" >> /etc/crio/crio.conf.d/11-default.conf
curl --fail -H "Authorization: Bearer Oracle" -L0 http://169.254.169.254/opc/v2/instance/metadata/oke_init_script | base64 --decode >/var/run/oke-init.sh
sudo bash /var/run/oke-init.sh
