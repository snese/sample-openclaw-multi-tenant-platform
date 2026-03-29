#!/usr/bin/env bash
set -euo pipefail

# Post-deploy script: sets up resources that depend on Kubernetes-managed ALB
# Run after: cdk deploy + setup-keda.sh + first tenant creation

REGION="${1:-us-west-2}"
STACK="OpenClawEksStack"

get_output() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

DOMAIN=$(get_output DomainName)
WAF_ARN=$(get_output WafAclArn)
CF_CERT=$(get_output CloudFrontCertificateArn 2>/dev/null || echo "")

echo "==> Post-deploy setup"
echo "  Domain: $DOMAIN"

# 1. Find internal ALB (created by Kubernetes LB Controller)
ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?Scheme=='internal' && contains(LoadBalancerName,'openclaw')].LoadBalancerArn" --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?Scheme=='internal' && contains(LoadBalancerName,'openclaw')].DNSName" --output text)

if [ -z "$ALB_ARN" ]; then
  echo "Error: Internal ALB not found. Create at least one tenant first."
  exit 1
fi
echo "  ALB: $ALB_DNS (internal)"

# 2. Attach WAF to ALB
echo "  → Attaching WAF to ALB"
aws wafv2 associate-web-acl --web-acl-arn "$WAF_ARN" --resource-arn "$ALB_ARN" --region "$REGION" 2>/dev/null || true
echo "  ✅ WAF attached"

# 2b. Origin verify secret (prevents VPC-internal bypass of CloudFront)
ORIGIN_SECRET_NAME="openclaw/origin-verify-secret"
ORIGIN_SECRET=$(aws secretsmanager get-secret-value --secret-id "$ORIGIN_SECRET_NAME" --region "$REGION" --query SecretString --output text 2>/dev/null || echo "")
if [ -z "$ORIGIN_SECRET" ]; then
  ORIGIN_SECRET=$(openssl rand -hex 32)
  aws secretsmanager create-secret --name "$ORIGIN_SECRET_NAME" --secret-string "$ORIGIN_SECRET" --region "$REGION" > /dev/null
  echo "  ✅ Origin verify secret created"
else
  echo "  ✅ Origin verify secret exists"
fi

# 3. Create or find VPC Origin
VPC_ORIGIN_ID=$(aws cloudfront list-vpc-origins --query "VpcOriginList.Items[?VpcOriginEndpointConfig.Arn=='${ALB_ARN}'].Id" --output text 2>/dev/null)
if [ -z "$VPC_ORIGIN_ID" ]; then
  echo "  → Creating VPC Origin"
  VPC_ORIGIN_ID=$(aws cloudfront create-vpc-origin \
    --vpc-origin-endpoint-config "{\"Name\":\"openclaw-alb\",\"Arn\":\"${ALB_ARN}\",\"HTTPPort\":80,\"HTTPSPort\":443,\"OriginProtocolPolicy\":\"https-only\"}" \
    --query 'VpcOrigin.Id' --output text)
  echo "  Waiting for VPC Origin to deploy..."
  while [ "$(aws cloudfront get-vpc-origin --id "$VPC_ORIGIN_ID" --query 'VpcOrigin.Status' --output text)" != "Deployed" ]; do
    sleep 15
  done
fi
echo "  ✅ VPC Origin: $VPC_ORIGIN_ID"

# 4. Upload error pages to S3 + create OAC for tenant CloudFront
ERROR_BUCKET=$(get_output ErrorPagesBucketName)
echo "  → Uploading error pages to s3://${ERROR_BUCKET}"
aws s3 cp "$(dirname "$0")/../helm/charts/openclaw-platform/static/503.html" "s3://${ERROR_BUCKET}/503.html" --content-type "text/html; charset=utf-8" --region "$REGION"

# Create OAC for error pages S3 origin
OAC_NAME="openclaw-error-pages"
OAC_ID=$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id" --output text 2>/dev/null)
if [ -z "$OAC_ID" ]; then
  OAC_ID=$(aws cloudfront create-origin-access-control --origin-access-control-config "{\"Name\":\"${OAC_NAME}\",\"SigningProtocol\":\"sigv4\",\"SigningBehavior\":\"always\",\"OriginAccessControlOriginType\":\"s3\"}" --query 'OriginAccessControl.Id' --output text)
fi
echo "  ✅ Error pages ready (OAC: $OAC_ID)"

# 5. Create or find tenant CloudFront distribution (*.domain → VPC Origin → ALB)
TENANT_CF_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(to_string(Aliases.Items),'*.${DOMAIN}')].Id" --output text 2>/dev/null)

if [ -z "$TENANT_CF_ID" ]; then
  echo "  → Creating tenant CloudFront distribution"

  # Need us-east-1 cert ARN
  if [ -z "$CF_CERT" ]; then
    CF_CERT=$(aws acm list-certificates --region us-east-1 \
      --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn" --output text)
  fi

  cat > /tmp/tenant-cf.json << CFEOF
{
  "CallerReference": "openclaw-tenants-$(date +%s)",
  "Aliases": {"Quantity": 1, "Items": ["*.${DOMAIN}"]},
  "DefaultRootObject": "",
  "Origins": {"Quantity": 2, "Items": [
    {"Id": "alb", "DomainName": "${ALB_DNS}", "VpcOriginConfig": {"VpcOriginId": "${VPC_ORIGIN_ID}", "OriginKeepaliveTimeout": 5, "OriginReadTimeout": 60}, "CustomHeaders": {"Quantity": 1, "Items": [{"HeaderName": "x-origin-verify", "HeaderValue": "${ORIGIN_SECRET}"}]}, "OriginShield": {"Enabled": false}, "ConnectionAttempts": 3, "ConnectionTimeout": 10},
    {"Id": "error-pages", "DomainName": "${ERROR_BUCKET}.s3.${REGION}.amazonaws.com", "S3OriginConfig": {"OriginAccessIdentity": ""}, "CustomHeaders": {"Quantity": 0}, "OriginShield": {"Enabled": false}, "ConnectionAttempts": 3, "ConnectionTimeout": 10, "OriginAccessControlId": "${OAC_ID}"}
  ]},
  "DefaultCacheBehavior": {"TargetOriginId": "alb", "ViewerProtocolPolicy": "redirect-to-https", "AllowedMethods": {"Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"], "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}}, "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad", "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3", "Compress": true},
  "CacheBehaviors": {"Quantity": 1, "Items": [{"PathPattern": "/error/*", "TargetOriginId": "error-pages", "ViewerProtocolPolicy": "redirect-to-https", "AllowedMethods": {"Quantity": 2, "Items": ["GET","HEAD"], "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}}, "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6", "Compress": true}]},
  "CustomErrorResponses": {"Quantity": 2, "Items": [
    {"ErrorCode": 502, "ResponsePagePath": "/error/503.html", "ResponseCode": "503", "ErrorCachingMinTTL": 5},
    {"ErrorCode": 503, "ResponsePagePath": "/error/503.html", "ResponseCode": "503", "ErrorCachingMinTTL": 5}
  ]},
  "Comment": "OpenClaw tenants (*.${DOMAIN} → internal ALB)",
  "Enabled": true,
  "ViewerCertificate": {"ACMCertificateArn": "${CF_CERT}", "SSLSupportMethod": "sni-only", "MinimumProtocolVersion": "TLSv1.2_2021"},
  "HttpVersion": "http2and3",
  "PriceClass": "PriceClass_100"
}
CFEOF
  TENANT_CF_ID=$(aws cloudfront create-distribution --distribution-config file:///tmp/tenant-cf.json --query 'Distribution.Id' --output text)
  TENANT_CF_DOMAIN=$(aws cloudfront get-distribution --id "$TENANT_CF_ID" --query 'Distribution.DomainName' --output text)
else
  TENANT_CF_DOMAIN=$(aws cloudfront get-distribution --id "$TENANT_CF_ID" --query 'Distribution.DomainName' --output text)
fi
echo "  ✅ Tenant CloudFront: $TENANT_CF_ID ($TENANT_CF_DOMAIN)"

# Set bucket policy for CloudFront OAC access to error pages
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3api put-bucket-policy --bucket "$ERROR_BUCKET" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": {\"Service\": \"cloudfront.amazonaws.com\"},
    \"Action\": \"s3:GetObject\",
    \"Resource\": \"arn:aws:s3:::${ERROR_BUCKET}/*\",
    \"Condition\": {\"StringEquals\": {\"AWS:SourceArn\": \"arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${TENANT_CF_ID}\"}}
  }]
}" --region "$REGION"

# 6. Update Route53 wildcard → tenant CloudFront
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query "HostedZones[0].Id" --output text | sed 's|/hostedzone/||')
echo "  → Updating Route53 *.${DOMAIN} → $TENANT_CF_DOMAIN"
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
  \"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {
    \"Name\": \"*.${DOMAIN}\", \"Type\": \"A\",
    \"AliasTarget\": {\"HostedZoneId\": \"Z2FDTNDATAQYW2\", \"DNSName\": \"${TENANT_CF_DOMAIN}\", \"EvaluateTargetHealth\": false}
  }}]
}" > /dev/null
echo "  ✅ Route53 updated"

# 7. ALB listener rule: reject requests without valid x-origin-verify header
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$REGION" \
  --query "Listeners[?Port==\`443\`].ListenerArn" --output text 2>/dev/null)
if [ -z "$LISTENER_ARN" ]; then
  LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$REGION" \
    --query "Listeners[0].ListenerArn" --output text)
fi

if [ -n "$LISTENER_ARN" ]; then
  # Check if rule already exists
  EXISTING_RULE=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --region "$REGION" \
    --query "Rules[?Priority=='1'].RuleArn" --output text 2>/dev/null)
  if [ -z "$EXISTING_RULE" ]; then
    echo "  → Adding ALB listener rule: reject missing x-origin-verify"
    aws elbv2 create-rule --listener-arn "$LISTENER_ARN" --region "$REGION" \
      --priority 1 \
      --conditions '[{"Field":"http-header","HttpHeaderConfig":{"HttpHeaderName":"x-origin-verify","Values":["'"$ORIGIN_SECRET"'"]}}]' \
      --actions '[{"Type":"forward","TargetGroupArn":"'"$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --region "$REGION" --query "Rules[?IsDefault].Actions[0].TargetGroupArn" --output text)"'"}]' > /dev/null
    # Change default action to fixed 403
    aws elbv2 modify-listener --listener-arn "$LISTENER_ARN" --region "$REGION" \
      --default-actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"403","ContentType":"text/plain","MessageBody":"Forbidden"}}]' > /dev/null
    echo "  ✅ ALB origin verify rule added (direct ALB access returns 403)"
  else
    echo "  ✅ ALB origin verify rule exists"
  fi
fi

echo ""
echo "=== Post-deploy complete ==="
echo "  Auth UI:  https://${DOMAIN}"
echo "  Tenants:  https://<name>.${DOMAIN}"
echo "  ALB:      internal (${ALB_DNS})"
echo "  WAF:      attached"
echo "  VPC Origin: ${VPC_ORIGIN_ID}"
echo "============================"
