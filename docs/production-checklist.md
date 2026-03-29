# Production Hardening Checklist

> This platform ships as a **sample deployment**. Before running in production, review and address each item below.

| # | Item | Why | Reference |
|---|------|-----|-----------|
| 1 | Add CloudFront origin verify header | Without it, any VPC-internal workload can bypass CloudFront and hit the ALB directly | `docs/security.md` Layer 4 |
| 2 | Enable WAF logging | Rate limiting is blind without visibility into blocked requests | `docs/security.md` Layer 1 |
| 3 | Enable Cognito MFA | Admin accounts without MFA are vulnerable to credential stuffing | Cognito User Pool settings |
| 4 | Enable VPC Flow Logs | No network forensics capability without flow logs | VPC console |
| 5 | Enable GuardDuty EKS Runtime Monitoring | No runtime threat detection for container workloads | GuardDuty console |
| 6 | Use customer-managed KMS keys | Default encryption doesn't provide key rotation control or audit trail | EBS, S3, Secrets Manager |
| 7 | Add SAST/DAST to CI pipeline | No static or dynamic security testing on code changes | CodeGuru, Snyk, or equivalent |
| 8 | Enforce Pod Security Standards | No admission controller prevents privileged containers | `PodSecurity` admission controller |
| 9 | Enable image signing (Cosign/Sigstore) | No verification that container images haven't been tampered with | ECR image signing |
| 10 | Enable Secrets Manager auto-rotation | Static secrets are vulnerable if leaked; rotation limits blast radius | Secrets Manager rotation config |

## How to Use

1. Fork this repo
2. Work through items top-to-bottom (ordered by security impact)
3. Check off each item as you implement it
4. Items 1-2 have existing issues with implementation details: #8, #9
