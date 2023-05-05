#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Generate signing keys
[[ ! -s signing_private.pem ]] && \
  openssl ecparam -genkey -name secp384r1 -noout -out signing_private.pem
[[ ! -s signing_public.pem ]] && \
  openssl ec -in signing_private.pem -pubout -out signing_public.pem

# Sign models
python3 sign.py signing_private.pem model_repository
