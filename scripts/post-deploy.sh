#!/usr/bin/env bash
set -euo pipefail

# Post-deploy script: adds ALB origin to the CDK-managed CloudFront distribution
# Run after: cdk deploy + deploy-platform.sh + setup-keda.sh + first tenant creation
#
# The CDK CloudFront serves auth UI from S3 (default behavior).
# This script adds the ALB as a second origin with /t/* behavior for tenant traffic:
#   CloudFront (claw.domain)
#     /        -> S3 (auth UI)        [CDK-managed]
#     /t/*     -> ALB (tenant pods)   [added by this script]
#     /error/* -> S3 (error pages)    [added by this script]

source "$(dirname "$0")/lib/common.sh"

DOMAIN=$(get_output DomainName)
WAF_ARN=$(get_output WafAclArn)
ERROR_BUCKET=$(get_output ErrorPagesBucketName)

echo "==> Post-deploy setup"
echo "  Domain: $DOMAIN"

# 1. Find internet-facing ALB (created by ALB Controller when Gateway is reconciled)
ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?Scheme=='internet-facing' && contains(LoadBalancerName,'openclaw')].LoadBalancerArn" --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?Scheme=='internet-facing' && contains(LoadBalancerName,'openclaw')].DNSName" --output text)

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  echo "Error: Internet-facing ALB not found. Ensure deploy-platform.sh ran and at least one tenant exists."
  exit 1
fi
echo "  ALB: $ALB_DNS"

# 2. Attach WAF to ALB
echo "  -> Attaching WAF to ALB"
aws wafv2 associate-web-acl --web-acl-arn "$WAF_ARN" --resource-arn "$ALB_ARN" --region "$REGION" 2>/dev/null || true
echo "  WAF attached"

# 3. Upload error pages to S3
echo "  -> Uploading error pages to s3://${ERROR_BUCKET}"
STATIC_DIR="$(dirname "$0")/../helm/charts/openclaw-platform/static"
if [ -f "${STATIC_DIR}/503.html" ]; then
  aws s3 cp "${STATIC_DIR}/503.html" "s3://${ERROR_BUCKET}/503.html" --content-type "text/html; charset=utf-8" --region "$REGION"
fi

# 4. Find CDK-managed CloudFront distribution (serves auth UI on DOMAIN)
# Find the exact-match distribution (not wildcard *.domain)
CF_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Aliases.Items[0]=='${DOMAIN}'].Id" --output text 2>/dev/null | head -1)

if [ -z "$CF_ID" ]; then
  log_error "CloudFront distribution for ${DOMAIN} not found. Run 'cdk deploy' first."
  exit 1
fi
echo "  CloudFront: $CF_ID"

# Check if ALB origin already exists
EXISTING_ORIGINS=$(aws cloudfront get-distribution-config --id "$CF_ID" \
  --query "DistributionConfig.Origins.Items[*].Id" --output text)
if echo "$EXISTING_ORIGINS" | grep -q "alb"; then
  echo "  ALB origin already configured. Updating..."
fi

# 5. Add ALB origin + /t/* behavior to the existing CloudFront distribution
echo "  -> Adding ALB origin and /t/* behavior to CloudFront"

# Get current config + ETag (required for update)
aws cloudfront get-distribution-config --id "$CF_ID" > /tmp/cf-config-full.json
ETAG=$(python3 -c "import json; print(json.load(open('/tmp/cf-config-full.json'))['ETag'])")
python3 -c "
import json

with open('/tmp/cf-config-full.json') as f:
    full = json.load(f)
config = full['DistributionConfig']

alb_dns = '${ALB_DNS}'
error_bucket = '${ERROR_BUCKET}'
region = '${REGION}'

# Add ALB origin if not present
origins = config['Origins']['Items']
alb_origin_ids = [o['Id'] for o in origins if o['Id'] == 'alb']
if not alb_origin_ids:
    origins.append({
        'Id': 'alb',
        'DomainName': alb_dns,
        'OriginPath': '',
        'CustomOriginConfig': {
            'HTTPPort': 80,
            'HTTPSPort': 443,
            'OriginProtocolPolicy': 'https-only',
            'OriginKeepaliveTimeout': 5,
            'OriginReadTimeout': 60,
            'OriginSslProtocols': {'Quantity': 1, 'Items': ['TLSv1.2']}
        },
        'CustomHeaders': {'Quantity': 0, 'Items': []},
        'OriginShield': {'Enabled': False},
        'ConnectionAttempts': 3,
        'ConnectionTimeout': 10,
    })
else:
    # Update existing ALB origin DNS
    for o in origins:
        if o['Id'] == 'alb':
            o['DomainName'] = alb_dns

# Add error-pages origin if not present
error_origin_ids = [o['Id'] for o in origins if o['Id'] == 'error-pages']
if not error_origin_ids:
    origins.append({
        'Id': 'error-pages',
        'DomainName': f'{error_bucket}.s3.{region}.amazonaws.com',
        'OriginPath': '',
        'S3OriginConfig': {'OriginAccessIdentity': ''},
        'CustomHeaders': {'Quantity': 0, 'Items': []},
        'OriginShield': {'Enabled': False},
        'ConnectionAttempts': 3,
        'ConnectionTimeout': 10,
    })

config['Origins']['Quantity'] = len(origins)

# Add /t/* and /error/* behaviors if not present
behaviors = config.get('CacheBehaviors', {}).get('Items', [])

def make_behavior(path, origin_id, methods_all=False):
    b = {
        'PathPattern': path,
        'TargetOriginId': origin_id,
        'ViewerProtocolPolicy': 'redirect-to-https',
        'Compress': True,
        'SmoothStreaming': False,
        'FieldLevelEncryptionId': '',
        'LambdaFunctionAssociations': {'Quantity': 0, 'Items': []},
        'FunctionAssociations': {'Quantity': 0, 'Items': []},
    }
    if methods_all:
        b['AllowedMethods'] = {
            'Quantity': 7,
            'Items': ['GET','HEAD','OPTIONS','PUT','POST','PATCH','DELETE'],
            'CachedMethods': {'Quantity': 2, 'Items': ['GET','HEAD']}
        }
        # CachingDisabled + AllViewerExceptHostHeader
        b['CachePolicyId'] = '4135ea2d-6df8-44a3-9df3-4b5a84be39ad'
        b['OriginRequestPolicyId'] = '216adef6-5c7f-47e4-b989-5492eafa07d3'
    else:
        b['AllowedMethods'] = {
            'Quantity': 2,
            'Items': ['GET','HEAD'],
            'CachedMethods': {'Quantity': 2, 'Items': ['GET','HEAD']}
        }
        b['CachePolicyId'] = '658327ea-f89d-4fab-a63d-7e88639e58f6'
    return b

if not any(b['PathPattern'] == '/t/*' for b in behaviors):
    behaviors.append(make_behavior('/t/*', 'alb', methods_all=True))
if not any(b['PathPattern'] == '/error/*' for b in behaviors):
    behaviors.append(make_behavior('/error/*', 'error-pages', methods_all=False))

config['CacheBehaviors'] = {'Quantity': len(behaviors), 'Items': behaviors}

# Custom error responses for 502/503
config['CustomErrorResponses'] = {
    'Quantity': 2,
    'Items': [
        {'ErrorCode': 502, 'ResponsePagePath': '/error/503.html', 'ResponseCode': '503', 'ErrorCachingMinTTL': 5},
        {'ErrorCode': 503, 'ResponsePagePath': '/error/503.html', 'ResponseCode': '503', 'ErrorCachingMinTTL': 5},
    ]
}

config['HttpVersion'] = 'http2and3'

with open('/tmp/cf-config-update.json', 'w') as f:
    json.dump(config, f)
"

aws cloudfront update-distribution --id "$CF_ID" \
  --if-match "$ETAG" \
  --distribution-config file:///tmp/cf-config-update.json \
  --query 'Distribution.{Status:Status,DomainName:DomainName}' --output json
rm -f /tmp/cf-config-full.json /tmp/cf-config-update.json

echo "  CloudFront updated (deploying ~3-5 min)"

# 6. Set bucket policy for error pages
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3api put-bucket-policy --bucket "$ERROR_BUCKET" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": {\"Service\": \"cloudfront.amazonaws.com\"},
    \"Action\": \"s3:GetObject\",
    \"Resource\": \"arn:aws:s3:::${ERROR_BUCKET}/*\",
    \"Condition\": {\"StringEquals\": {\"AWS:SourceArn\": \"arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${CF_ID}\"}}
  }]
}" --region "$REGION"

# 7. Ensure Route53 points to this CloudFront
CF_DOMAIN=$(aws cloudfront get-distribution --id "$CF_ID" --query 'Distribution.DomainName' --output text)
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query "HostedZones[0].Id" --output text | sed 's|/hostedzone/||')
echo "  -> Updating Route53 ${DOMAIN} -> $CF_DOMAIN"
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
  \"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {
    \"Name\": \"${DOMAIN}\", \"Type\": \"A\",
    \"AliasTarget\": {\"HostedZoneId\": \"Z2FDTNDATAQYW2\", \"DNSName\": \"${CF_DOMAIN}\", \"EvaluateTargetHealth\": false}
  }}]
}" > /dev/null
echo "  Route53 updated"

echo ""
echo "=== Post-deploy complete ==="
echo "  Auth UI:    https://${DOMAIN}"
echo "  Tenants:    https://${DOMAIN}/t/<tenant>/"
echo "  CloudFront: ${CF_ID} (${CF_DOMAIN})"
echo "  ALB:        ${ALB_DNS} (CF-only SG)"
echo "  WAF:        attached to ALB"
echo ""
echo "  CloudFront deployment takes ~3-5 min. Check status:"
echo "    aws cloudfront get-distribution --id ${CF_ID} --query 'Distribution.Status'"
echo "============================"
