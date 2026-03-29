#!/usr/bin/env bash
set -euo pipefail

STEP=""
trap 'if [ -n "$STEP" ]; then echo "❌ Failed at: $STEP" >&2; fi' ERR

STEP="CDK Deploy"
echo "==> Step 1: $STEP"
cd cdk && npm ci && npx cdk deploy OpenClawEksStack --require-approval broadening && cd ..

STEP="Setup Cognito"
echo "==> Step 2: $STEP"
bash scripts/setup-cognito.sh

STEP="Deploy Auth UI"
echo "==> Step 3: $STEP"
bash scripts/deploy-auth-ui.sh

STEP="Upload Helm Chart"
echo "==> Step 4: $STEP"
bash scripts/upload-helm-chart.sh

STEP="Deploy Gateway API"
echo "==> Step 5: $STEP"
kubectl apply -f helm/gateway.yaml

STEP="Install CRD + Operator"
echo "==> Step 6: $STEP"
kubectl apply -f operator/yaml/crd.yaml
kubectl apply -f operator/yaml/deployment.yaml

STEP=""
echo "==> Done! Visit https://$(cd cdk && node -e "console.log(require('./cdk.json').context.zoneName)")"
