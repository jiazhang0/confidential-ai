#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

while getopts ":t:s:" options; do
    case $options in
        t)kty=$OPTARG;;
        s)salt=$OPTARG;;           
    esac
done

TOOLS_HOME=${PWD}/../external/confidential-sidecar-containers/tools

# Generate container security policy to be bound to the key
export MODEL_SIGNING_KEY=`cat signing_public.pem | base64 -w0`

if [ ! -s /tmp/cce-policy.b64 ]; then
    envsubst < ../policy/policy-in-template.json > /tmp/policy-in.json
    az confcom acipolicygen -i /tmp/policy-in.json > /tmp/cce-policy.b64
fi
export CCE_POLICY=$(cat /tmp/cce-policy.b64)

echo "Generating container security policy..."
pushd .
cd $TOOLS_HOME/securitypolicydigest
export CCE_POLICY_HASH=$(go run main.go -p $CCE_POLICY | tail --bytes=65)
popd
echo "Server container policy hash $CCE_POLICY_HASH"

# Set the key type environment variable
if [ "$kty" = *"RSA" ]; then
    export AZURE_AKV_KEY_TYPE="RSA-HSM"
elif [ "$kty" = *"oct" ]; then
    export AZURE_AKV_KEY_TYPE="oct-HSM"
fi

# Obtain the token based on the AKV resource endpoint subdomain
if [[ "$AZURE_AKV_RESOURCE_ENDPOINT" == *".vault.azure.net" ]]; then
    export BEARER_TOKEN=$(az account get-access-token --resource https://vault.azure.net | jq -r .accessToken)
    echo "Importing keys to AKV key vaults can be only of type RSA-HSM"
    export AZURE_AKV_KEY_TYPE="RSA-HSM"
    vaultType="vault"
elif [[ "$AZURE_AKV_RESOURCE_ENDPOINT" == *".managedhsm.azure.net" ]]; then
    export BEARER_TOKEN=$(az account get-access-token --resource https://managedhsm.azure.net | jq -r .accessToken)    
    vaultType="mhsm"
fi

# For RSA-HSM keys, we need to set a salt and label which will be used in the symmetric key derivation
if [ "$AZURE_AKV_KEY_TYPE" = "RSA-HSM" ]; then    
    if [[ -z "$salt" && ! -s "salt_modelkey.bin" ]]; then
        dd if=/dev/random of="salt_modelkey.bin" count=1 bs=32
        export AZURE_AKV_KEY_DERIVATION_SALT=$(python hexstring.py salt_modelkey.bin | sed "s/'//g" | sed "1s/^.//") 
    elif [[ -n "$salt" ]]; then
        export AZURE_AKV_KEY_DERIVATION_SALT=$salt
    else
	export AZURE_AKV_KEY_DERIVATION_SALT=$(python hexstring.py salt_modelkey.bin | sed "s/'//g" | sed "1s/^.//")
    fi

    export AZURE_AKV_KEY_DERIVATION_LABEL="Model Encryption Key"
fi

if [[ "$AZURE_MAA_ENDPOINT" == "" ]]; then
  export AZURE_MAA_ENDPOINT=`az attestation show --name $AZURE_MAA_CUSTOM_RESOURCE_NAME --resource-group $AZURE_RESOURCE_GROUP --query attestUri --output tsv | awk '{split($0,a,"//"); print a[2]}'`  
fi

# Generate key import configuration.
CONFIG=$(jq '.claims[0][0].equals = env.CCE_POLICY_HASH' importkey-config-template.json)
CONFIG=$(echo $CONFIG | jq '.key.kid = "ModelFilesystemEncryptionKey"')
CONFIG=$(echo $CONFIG | jq '.key.kty = env.AZURE_AKV_KEY_TYPE')
CONFIG=$(echo $CONFIG | jq '.key.authority.endpoint = env.AZURE_MAA_ENDPOINT')
CONFIG=$(echo $CONFIG | jq '.key_derivation.salt = env.AZURE_AKV_KEY_DERIVATION_SALT')
CONFIG=$(echo $CONFIG | jq '.key_derivation.label = env.AZURE_AKV_KEY_DERIVATION_LABEL')
CONFIG=$(echo $CONFIG | jq '.key.akv.endpoint = env.AZURE_AKV_RESOURCE_ENDPOINT')
CONFIG=$(echo $CONFIG | jq '.key.akv.bearer_token = env.BEARER_TOKEN')
echo $CONFIG > /tmp/importkey-config.json

# Import key into key vault
echo "Importing model key..."
model_key="$PWD/rsa_material_modelkey.pem"
pushd .
cd $TOOLS_HOME/importkey
if [[ -s "$model_key" ]]; then
  go run main.go -c /tmp/importkey-config.json -kp $model_key -out
else
  go run main.go -c /tmp/importkey-config.json -out
fi
popd
mv $TOOLS_HOME/importkey/keyfile.bin modelkey.bin
if [[ "$vaultType" = "vault" ]]; then
    mv $TOOLS_HOME/importkey/private_key.pem rsa_material_modelkey.pem    
fi

