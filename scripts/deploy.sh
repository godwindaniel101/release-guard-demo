#!/usr/bin/env bash
# Stand-in for a real deployment. The demo is about the guards, not the deploy.
set -euo pipefail
VERSION="${1:?usage: deploy.sh <version>}"
echo "  deploying $VERSION ($(git rev-parse --short HEAD))"
echo "  → in a real pipeline this would push the image and roll the deployment"
