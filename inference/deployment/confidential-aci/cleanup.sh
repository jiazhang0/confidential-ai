# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

az group delete --yes --name $AZURE_RESOURCE_GROUP

cd /tmp
rm -f \
  aci-parameters.json \
  cce-policy.b64 \
  importkey-config.json \
  maa-parameters.json \
  maa-policy.in \
  policy-in.json
cd -
