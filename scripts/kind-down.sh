#!/usr/bin/env bash
# Delete the local kind cluster and everything in it.
set -euo pipefail
kind delete cluster --name clickhouse-obs
