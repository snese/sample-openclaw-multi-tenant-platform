#!/usr/bin/env bash
# Interactive cdk.json generator
# Usage: source scripts/lib/generate-config.sh && generate_config
#    or: bash scripts/lib/generate-config.sh (standalone)
set -euo pipefail

TEMPLATE="cdk/cdk.json.example"
TARGET="cdk/cdk.json"

prompt_value() {
  local key="$1" current="$2" label="$3" pattern="${4:-}"
  if [[ -n "$current" && "$current" != "<"* && "$current" != "your-"* && "$current" != "YOUR_"* && "$current" != "arn:aws:"*":123456789012:"* && "$current" != "us-west-2_XXXXXXXXX" && "$current" != "xxxxxxxxxxxxxxxxxx" ]]; then
    printf "  %s [%s]: " "$label" "$current"
  else
    printf "  %s: " "$label"
    current=""
  fi
  local input
  read -r input
  input="${input:-$current}"
  if [[ -n "$pattern" && -n "$input" ]]; then
    if ! [[ "$input" =~ $pattern ]]; then
      echo "    ⚠ Invalid format, expected: $pattern"
      prompt_value "$key" "" "$label" "$pattern"
      return
    fi
  fi
  echo "$input"
}

generate_config() {
  if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: $TEMPLATE not found. Are you in the repo root?"
    return 1
  fi

  if [[ -f "$TARGET" ]]; then
    printf "%s already exists. Overwrite? (y/N) " "$TARGET"
    local answer
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      echo "Keeping existing $TARGET"
      return 0
    fi
  fi

  echo ""
  echo "Configuration"
  echo "============="
  echo "Only required values are prompted. Optional values use defaults."
  echo ""

  cp "$TEMPLATE" "$TARGET"

  # Required values
  local domain hosted_zone cert_arn cf_cert_arn cognito_pool cognito_client cognito_domain allowed_domains sso_role

  read -rp "  Domain name (e.g., platform.company.com): " domain
  read -rp "  Hosted Zone ID: " hosted_zone
  read -rp "  ACM Certificate ARN (deployment region): " cert_arn
  read -rp "  ACM Certificate ARN (us-east-1, for CloudFront): " cf_cert_arn
  read -rp "  Cognito User Pool ID: " cognito_pool
  read -rp "  Cognito App Client ID: " cognito_client
  read -rp "  Cognito domain prefix: " cognito_domain
  read -rp "  Allowed email domains (comma-separated): " allowed_domains
  read -rp "  SSO Role ARN for kubectl access: " sso_role

  echo ""
  echo "Optional (press Enter for defaults):"
  local github_owner github_repo openclaw_image
  read -rp "  GitHub owner [your-org]: " github_owner
  github_owner="${github_owner:-your-org}"
  read -rp "  GitHub repo [openclaw-platform]: " github_repo
  github_repo="${github_repo:-openclaw-platform}"
  read -rp "  OpenClaw image [ghcr.io/openclaw/openclaw:latest]: " openclaw_image
  openclaw_image="${openclaw_image:-ghcr.io/openclaw/openclaw:latest}"

  # Write values using node (handles JSON safely)
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('$TARGET', 'utf8'));
    const c = cfg.context;
    c.zoneName = '$domain';
    c.hostedZoneId = '$hosted_zone';
    c.certificateArn = '$cert_arn';
    c.cloudfrontCertificateArn = '$cf_cert_arn';
    c.cognitoPoolId = '$cognito_pool';
    c.cognitoClientId = '$cognito_client';
    c.cognitoDomain = '$cognito_domain';
    c.allowedEmailDomains = '$allowed_domains';
    c.ssoRoleArn = '$sso_role';
    c.githubOwner = '$github_owner';
    c.githubRepo = '$github_repo';
    c.openclawImage = '$openclaw_image';
    fs.writeFileSync('$TARGET', JSON.stringify(cfg, null, 2) + '\n');
  "

  echo ""
  echo "Writing $TARGET... done"
}

# Run standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  generate_config
fi
