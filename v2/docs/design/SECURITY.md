> **DESIGN STAGE**: Comprehensive security framework. Current implementation lacks TLS/mTLS and API auth (see [`FINDINGS_AND_ISSUES.md`](../FINDINGS_AND_ISSUES.md) C1-C2). Frame-level PSK encryption (XChaCha20-Poly1305) is implemented.

# Hivemind Security Model

> Comprehensive security architecture covering authentication, authorization, isolation, data protection, and compliance across all Hivemind components.

---

## Table of Contents

1. [Security Principles](#security-principles)
2. [Compliance Framework](#compliance-framework)
3. [Component Security](#component-security)
4. [Multi-Tenant Isolation](#multi-tenant-isolation)
5. [Authentication & Authorization](#authentication--authorization)
6. [Network Security](#network-security)
7. [Data Protection](#data-protection)
8. [Secret Management](#secret-management)
9. [Audit Logging](#audit-logging)
10. [Incident Response](#incident-response)

---

## Security Principles

### Defense in Depth

Every layer of Hivemind implements independent security controls:

```
┌─────────────────────────────────────────────────────────────┐
│                    Network Perimeter                         │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                  API Gateway / WAF                     │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │              Application Layer                   │  │  │
│  │  │  ┌───────────────────────────────────────────┐  │  │  │
│  │  │  │            Container Isolation             │  │  │  │
│  │  │  │  ┌─────────────────────────────────────┐  │  │  │  │
│  │  │  │  │         GPU/Resource Isolation       │  │  │  │  │
│  │  │  │  └─────────────────────────────────────┘  │  │  │  │
│  │  │  └───────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Zero Trust Architecture

- No implicit trust between components
- All service-to-service communication authenticated
- Minimal privilege by default
- Continuous verification

### Principle of Least Privilege

- Components only have access to resources they need
- Time-limited credentials where possible
- Regular access reviews and rotation

---

## Compliance Framework

### Overview

Hivemind must support customers with various compliance requirements. The architecture is designed to be compliant with multiple frameworks simultaneously.

### Supported Compliance Standards

| Standard | Scope | Key Requirements |
|----------|-------|------------------|
| **SOC 2 Type II** | All customers | Access controls, encryption, monitoring, incident response |
| **GDPR** | EU customers/data | Data residency, right to deletion, consent, DPA |
| **HIPAA** | Healthcare customers | PHI protection, BAA, audit trails, encryption |
| **PCI DSS** | Payment processing | Network segmentation, encryption, access control |
| **ISO 27001** | Enterprise customers | ISMS, risk management, continuous improvement |

### Compliance-Aware Architecture

#### Data Residency

```
┌─────────────────────────────────────────────────────────────┐
│                     Hivemind Control Plane                   │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │  US Region  │  │  EU Region  │  │ APAC Region │         │
│  │             │  │             │  │             │         │
│  │ US Customer │  │ EU Customer │  │APAC Customer│         │
│  │    Data     │  │    Data     │  │    Data     │         │
│  │             │  │  (GDPR)     │  │             │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

**Implementation**:
- Workload placement respects data residency constraints
- Cross-region scheduling disabled for compliance-restricted workloads
- Metadata stored in region-local databases
- Logs and metrics kept within region boundaries

#### Compliance Flags per Workload

```rust
struct ComplianceConfig {
    // Data residency
    allowed_regions: Vec<Region>,

    // Regulatory frameworks
    hipaa_enabled: bool,
    gdpr_subject: bool,
    pci_scope: bool,

    // Data handling
    data_retention_days: u32,
    encryption_required: bool,
    audit_level: AuditLevel,  // Standard, Enhanced, Full
}
```

### Per-Standard Requirements

#### SOC 2 Type II

| Control | Hivemind Implementation |
|---------|------------------------|
| CC6.1 - Logical Access | RBAC, MFA, SSO integration |
| CC6.2 - Authentication | mTLS between services, JWT for users |
| CC6.3 - Authorization | Policy-based access control |
| CC7.1 - System Monitoring | Comprehensive audit logging |
| CC7.2 - Anomaly Detection | Automated alerting on suspicious activity |
| CC8.1 - Change Management | GitOps, approval workflows |

#### GDPR

| Requirement | Hivemind Implementation |
|-------------|------------------------|
| Article 17 - Right to Erasure | Data deletion API, cascade deletion |
| Article 20 - Data Portability | Export API for customer data |
| Article 25 - Privacy by Design | Encryption default, minimal data collection |
| Article 32 - Security | Encryption at rest/transit, access controls |
| Article 33 - Breach Notification | Incident detection, automated alerts |

**GDPR-Specific Controls**:
```rust
impl GdprCompliance {
    // Customer data export
    async fn export_customer_data(&self, customer_id: &str) -> DataExport;

    // Right to erasure
    async fn delete_customer_data(&self, customer_id: &str) -> DeletionReceipt;

    // Consent tracking
    async fn record_consent(&self, customer_id: &str, consent: ConsentRecord);

    // Data processing records
    async fn get_processing_activities(&self, customer_id: &str) -> Vec<ProcessingActivity>;
}
```

#### HIPAA

| Safeguard | Hivemind Implementation |
|-----------|------------------------|
| Access Control (§164.312(a)) | Role-based access, unique user IDs |
| Audit Controls (§164.312(b)) | Immutable audit logs, 6-year retention |
| Integrity Controls (§164.312(c)) | Checksums, tamper detection |
| Transmission Security (§164.312(e)) | TLS 1.3, mTLS |
| Encryption (§164.312(a)(2)(iv)) | AES-256 at rest, TLS in transit |

**HIPAA-Specific Controls**:
```rust
struct HipaaWorkload {
    // BAA reference
    baa_id: String,

    // PHI handling
    phi_categories: Vec<PhiCategory>,

    // Enhanced logging
    access_log_retention: Duration,  // 6 years minimum

    // Isolation
    dedicated_compute: bool,  // No shared tenancy for PHI
}
```

#### PCI DSS

| Requirement | Hivemind Implementation |
|-------------|------------------------|
| Req 1 - Firewalls | Network policies, security groups |
| Req 3 - Protect Data | Encryption, tokenization support |
| Req 7 - Restrict Access | Need-to-know access model |
| Req 10 - Track Access | Comprehensive audit logging |
| Req 11 - Test Security | Vulnerability scanning, pen testing |

---

## Component Security

### Router Security

```
┌─────────────────────────────────────────────────────────────┐
│                         Router                               │
├─────────────────────────────────────────────────────────────┤
│  Security Controls:                                          │
│  • TLS termination with certificate validation               │
│  • Request authentication (API keys, JWT)                    │
│  • Rate limiting per customer/endpoint                       │
│  • Request validation and sanitization                       │
│  • DDoS protection integration                               │
│  • IP allowlisting (optional per customer)                   │
└─────────────────────────────────────────────────────────────┘
```

**Authentication Flow**:
```
Client → TLS → Router → Validate API Key → Check Rate Limit → Route Request
                  │
                  ├── Invalid Key → 401 Unauthorized
                  ├── Rate Exceeded → 429 Too Many Requests
                  └── Valid → Forward to Workload
```

**Security Configuration**:
```rust
struct RouterSecurityConfig {
    // TLS
    tls_min_version: TlsVersion::V1_3,
    certificate_validation: CertValidation::Strict,

    // Authentication
    api_key_validation: bool,
    jwt_validation: Option<JwtConfig>,

    // Rate limiting
    rate_limit_per_customer: RateLimit,
    rate_limit_per_endpoint: RateLimit,

    // Protection
    max_request_size: usize,
    request_timeout: Duration,
    ip_allowlist: Option<Vec<IpNetwork>>,
}
```

**Compliance Considerations**:
- **SOC 2**: All access logged with customer ID, timestamp, endpoint
- **GDPR**: IP addresses treated as PII, configurable retention
- **HIPAA**: Enhanced logging for PHI-handling endpoints
- **PCI**: Cardholder data never logged, even in errors

---

### Honeycomb Security

```
┌─────────────────────────────────────────────────────────────┐
│                        Honeycomb                             │
├─────────────────────────────────────────────────────────────┤
│  Security Controls:                                          │
│  • Registry authentication (per-customer credentials)        │
│  • Image signing and verification                            │
│  • Vulnerability scanning integration                        │
│  • Content trust / Notary support                            │
│  • Layer encryption for sensitive images                     │
│  • Access control per repository                             │
└─────────────────────────────────────────────────────────────┘
```

**Registry Authentication**:
```rust
struct RegistryAuth {
    // Per-customer credentials
    customer_id: String,
    credential_type: CredentialType,  // Token, mTLS, OIDC

    // Scope
    allowed_repositories: Vec<String>,
    permissions: RegistryPermissions,  // Pull, Push, Admin

    // Expiration
    expires_at: Option<DateTime<Utc>>,

    // Audit
    last_used: DateTime<Utc>,
    usage_count: u64,
}

enum CredentialType {
    BearerToken { token_hash: String },
    MutualTls { client_cert_fingerprint: String },
    Oidc { provider: String, subject: String },
}
```

**Image Security Pipeline**:
```
Push Request
     │
     ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Authenticate   │    │ Scan for    │    │   Sign      │
│   Request   │───▶│ Vulnerabilities│───▶│   Image     │
└─────────────┘    └─────────────┘    └─────────────┘
                          │
                          ▼
                   ┌─────────────┐
                   │  Block if   │
                   │  Critical   │
                   │  CVEs Found │
                   └─────────────┘
```

**Compliance Considerations**:
- **SOC 2**: All image pulls/pushes logged with customer attribution
- **GDPR**: Customer images stored in designated region only
- **HIPAA**: PHI-containing images require additional encryption layer
- **PCI**: Images for payment processing isolated in separate namespace

---

### Beekeeper Security

```
┌─────────────────────────────────────────────────────────────┐
│                        Beekeeper                             │
├─────────────────────────────────────────────────────────────┤
│  Security Controls:                                          │
│  • Build isolation (dedicated containers per build)          │
│  • Secret injection (not baked into images)                  │
│  • Source code access controls                               │
│  • Build artifact signing                                    │
│  • Cache isolation per customer                              │
│  • Network isolation during builds                           │
└─────────────────────────────────────────────────────────────┘
```

**Build Isolation Model**:
```
┌─────────────────────────────────────────────────────────────┐
│                      Build Node                              │
│                                                              │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │  Customer A     │  │  Customer B     │                   │
│  │  Build Container│  │  Build Container│                   │
│  │                 │  │                 │                   │
│  │  • Isolated     │  │  • Isolated     │                   │
│  │    network      │  │    network      │                   │
│  │  • No shared    │  │  • No shared    │                   │
│  │    filesystem   │  │    filesystem   │                   │
│  │  • Separate     │  │  • Separate     │                   │
│  │    cache        │  │    cache        │                   │
│  └─────────────────┘  └─────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

**Secret Handling**:
```rust
struct BuildSecrets {
    // Secrets are injected at runtime, never stored in image
    injection_method: SecretInjection,

    // Secret sources
    sources: Vec<SecretSource>,

    // Cleanup
    cleanup_after_build: bool,  // Always true
}

enum SecretInjection {
    // Mount as tmpfs, cleared after build
    TmpfsMount,
    // Environment variables, cleared after build
    Environment,
    // BuildKit secrets (recommended)
    BuildKitSecret,
}

enum SecretSource {
    // External secret managers
    AwsSecretsManager { secret_arn: String },
    Vault { path: String },
    // Customer-provided (encrypted)
    CustomerProvided { encrypted_value: Vec<u8> },
}
```

**Compliance Considerations**:
- **SOC 2**: Build logs retained for audit, secrets redacted
- **GDPR**: Customer source code not retained after build unless requested
- **HIPAA**: Builds for PHI workloads on dedicated nodes
- **PCI**: Build environment scanned, no persistent secrets

---

### Hivemind Security

```
┌─────────────────────────────────────────────────────────────┐
│                        Hivemind                              │
├─────────────────────────────────────────────────────────────┤
│  Security Controls:                                          │
│  • Control plane authentication (mTLS)                       │
│  • RBAC for workload management                              │
│  • Tenant isolation in scheduling                            │
│  • Compliance-aware placement                                │
│  • Audit logging for all operations                          │
│  • Encryption of control plane data                          │
└─────────────────────────────────────────────────────────────┘
```

**Control Plane Authentication**:
```
┌──────────┐     mTLS      ┌──────────┐
│  Router  │──────────────▶│ Hivemind │
└──────────┘               └──────────┘
                                │
                                │ mTLS
                                ▼
┌──────────┐     mTLS      ┌──────────┐
│  Agent   │◀──────────────│ Hivemind │
└──────────┘               └──────────┘
```

**RBAC Model**:
```rust
struct HivemindRbac {
    roles: Vec<Role>,
    bindings: Vec<RoleBinding>,
}

enum Role {
    // Customer roles
    WorkloadAdmin,      // Full control over own workloads
    WorkloadViewer,     // Read-only access to own workloads

    // Platform roles (internal)
    PlatformAdmin,      // Full platform access
    PlatformOperator,   // Operational access
    PlatformViewer,     // Read-only platform access
}

struct RoleBinding {
    subject: Subject,       // User, ServiceAccount, Group
    role: Role,
    scope: Scope,           // Customer, Cluster, Global
}
```

**Tenant-Aware Scheduling**:
```rust
impl Scheduler {
    fn schedule_workload(&self, workload: &Workload) -> Result<Placement> {
        // Compliance checks first
        let allowed_clusters = self.filter_by_compliance(
            workload.compliance_config(),
            &self.clusters
        );

        // Tenant isolation
        let placement = self.find_placement(workload, allowed_clusters)?;

        // Verify no cross-tenant resource sharing for isolated workloads
        if workload.requires_dedicated_compute() {
            self.verify_isolation(&placement)?;
        }

        Ok(placement)
    }
}
```

**Compliance Considerations**:
- **SOC 2**: All scheduling decisions logged with rationale
- **GDPR**: Data residency enforced in scheduling
- **HIPAA**: PHI workloads scheduled to HIPAA-compliant nodes only
- **PCI**: PCI workloads in isolated network segment

---

### Agent Security

```
┌─────────────────────────────────────────────────────────────┐
│                          Agent                               │
├─────────────────────────────────────────────────────────────┤
│  Security Controls:                                          │
│  • Minimal privilege (only needed capabilities)              │
│  • Secure communication with control plane                   │
│  • Workload isolation enforcement                            │
│  • GPU isolation between tenants                             │
│  • Secure metrics collection                                 │
│  • Tamper detection                                          │
└─────────────────────────────────────────────────────────────┘
```

**Agent Capabilities**:
```rust
// Agent runs with minimal Linux capabilities
const AGENT_CAPABILITIES: &[Capability] = &[
    // Required for container management
    Capability::SYS_ADMIN,      // Mount namespaces
    Capability::NET_ADMIN,      // Network configuration

    // Required for GPU management
    Capability::SYS_RAWIO,      // GPU device access

    // Explicitly dropped
    // - CAP_SYS_PTRACE (no process tracing)
    // - CAP_SYS_MODULE (no kernel modules)
    // - CAP_SETUID/SETGID (no privilege escalation)
];
```

**GPU Isolation**:
```rust
struct GpuIsolation {
    // MIG (Multi-Instance GPU) for shared GPUs
    mig_enabled: bool,

    // MPS (Multi-Process Service) for time-slicing
    mps_enabled: bool,

    // Memory isolation
    memory_isolation: MemoryIsolation,

    // Process isolation
    compute_isolation: ComputeIsolation,
}

enum MemoryIsolation {
    // Separate GPU memory spaces
    Dedicated,
    // Shared with limits (less secure)
    SharedWithLimits { max_memory_mb: u64 },
}
```

**Compliance Considerations**:
- **SOC 2**: Agent health and security status reported to control plane
- **GDPR**: No customer data cached on agent beyond container lifecycle
- **HIPAA**: Full GPU memory wipe between PHI workloads
- **PCI**: Agent integrity verification on boot

---

## Multi-Tenant Isolation

### Isolation Levels

```
┌─────────────────────────────────────────────────────────────┐
│                    Isolation Spectrum                        │
│                                                              │
│  Shared          Namespace        Node            Cluster   │
│  Resources       Isolated         Isolated        Isolated  │
│     │               │                │               │      │
│     ▼               ▼                ▼               ▼      │
│  ┌─────┐        ┌─────┐          ┌─────┐        ┌─────┐    │
│  │ Low │        │ Med │          │High │        │ Max │    │
│  │Cost │        │Cost │          │Cost │        │Cost │    │
│  └─────┘        └─────┘          └─────┘        └─────┘    │
│                                                              │
│  Standard       Enterprise        HIPAA          Dedicated  │
│  Tier           Tier              Tier           Tier       │
└─────────────────────────────────────────────────────────────┘
```

### Isolation by Component

| Component | Standard | Enterprise | HIPAA/PCI | Dedicated |
|-----------|----------|------------|-----------|-----------|
| **Router** | Shared | Shared | Dedicated endpoints | Dedicated instance |
| **Honeycomb** | Shared registry | Namespace isolation | Encrypted repos | Private registry |
| **Beekeeper** | Shared builders | Cache isolation | Dedicated builders | Dedicated pool |
| **Hivemind** | Shared control plane | Tenant filtering | Audit enhancement | Dedicated control plane |
| **Agent** | Shared nodes | Resource limits | Dedicated nodes | Dedicated cluster |

### Network Isolation

```
┌─────────────────────────────────────────────────────────────┐
│                    Network Segmentation                      │
│                                                              │
│  ┌───────────────────┐    ┌───────────────────┐             │
│  │   Customer A      │    │   Customer B      │             │
│  │   Network         │    │   Network         │             │
│  │   10.1.0.0/16     │    │   10.2.0.0/16     │             │
│  │                   │    │                   │             │
│  │  ┌─────┐ ┌─────┐  │    │  ┌─────┐ ┌─────┐  │             │
│  │  │Pod 1│ │Pod 2│  │    │  │Pod 1│ │Pod 2│  │             │
│  │  └─────┘ └─────┘  │    │  └─────┘ └─────┘  │             │
│  └───────────────────┘    └───────────────────┘             │
│            │                        │                        │
│            └────────┐    ┌──────────┘                        │
│                     ▼    ▼                                   │
│              ┌──────────────┐                                │
│              │   Firewall   │  No direct cross-tenant       │
│              │   (Deny All) │  communication                │
│              └──────────────┘                                │
└─────────────────────────────────────────────────────────────┘
```

**Network Policies**:
```yaml
# Default deny all cross-tenant traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: tenant-isolation
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              tenant: ${TENANT_ID}
  egress:
    - to:
        - podSelector:
            matchLabels:
              tenant: ${TENANT_ID}
    # Allow egress to platform services
    - to:
        - namespaceSelector:
            matchLabels:
              platform: hivemind
```

---

## Authentication & Authorization

### Authentication Methods

| Method | Use Case | Components |
|--------|----------|------------|
| **API Keys** | Customer API access | Router |
| **JWT/OIDC** | User authentication | Dashboard, API |
| **mTLS** | Service-to-service | All internal |
| **Service Accounts** | Workload identity | Pods |

### Service-to-Service Authentication

```
┌─────────────────────────────────────────────────────────────┐
│                    Certificate Authority                     │
│                          (Vault)                             │
└─────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              ▼               ▼               ▼
        ┌──────────┐   ┌──────────┐   ┌──────────┐
        │  Router  │   │ Hivemind │   │  Agent   │
        │          │   │          │   │          │
        │ Cert:    │   │ Cert:    │   │ Cert:    │
        │ router.  │   │ hivemind.│   │ agent.   │
        │ hivemind │   │ hivemind │   │ hivemind │
        │ .svc     │   │ .svc     │   │ .node    │
        └──────────┘   └──────────┘   └──────────┘
```

**Certificate Rotation**:
```rust
struct CertificateManager {
    // Short-lived certificates
    certificate_ttl: Duration,  // 24 hours

    // Automatic rotation
    rotation_threshold: f64,    // Rotate at 70% of TTL

    // Revocation
    crl_endpoint: String,
    ocsp_endpoint: String,
}
```

### Authorization Model

```rust
// Policy-based authorization
struct AuthorizationPolicy {
    // Subject
    subject: Subject,

    // Action
    action: Action,

    // Resource
    resource: Resource,

    // Conditions
    conditions: Vec<Condition>,
}

enum Action {
    // Workload actions
    CreateWorkload,
    ReadWorkload,
    UpdateWorkload,
    DeleteWorkload,
    ScaleWorkload,

    // Registry actions
    PullImage,
    PushImage,

    // Build actions
    TriggerBuild,
    CancelBuild,
}

enum Condition {
    // Ownership
    OwnsResource,

    // Time-based
    WithinTimeWindow { start: Time, end: Time },

    // Location-based
    FromAllowedIp { networks: Vec<IpNetwork> },

    // Compliance
    HasComplianceCertification { cert: String },
}
```

---

## Network Security

### Encryption in Transit

| Connection | Protocol | Minimum Version |
|------------|----------|-----------------|
| External → Router | TLS | 1.3 |
| Router → Workload | mTLS | 1.3 |
| Hivemind → Agent | mTLS | 1.3 |
| Agent → Honeycomb | mTLS | 1.3 |
| Cross-cluster | mTLS over VPN | 1.3 |

### Firewall Rules

```
┌─────────────────────────────────────────────────────────────┐
│                    External Firewall                         │
├─────────────────────────────────────────────────────────────┤
│  ALLOW: 443/tcp from 0.0.0.0/0      (HTTPS to Router)       │
│  ALLOW: 443/tcp from VPN peers      (Cross-cluster)         │
│  DENY:  ALL other inbound                                   │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    Internal Firewall                         │
├─────────────────────────────────────────────────────────────┤
│  ALLOW: Router → Workloads (8080/tcp)                       │
│  ALLOW: Hivemind → Agents (9090/tcp)                        │
│  ALLOW: Agents → Honeycomb (5000/tcp)                       │
│  ALLOW: Agents → Hivemind (9091/tcp)                        │
│  DENY:  Cross-tenant traffic                                │
│  DENY:  Workload → Control plane (except health)            │
└─────────────────────────────────────────────────────────────┘
```

### DDoS Protection

```rust
struct DdosProtection {
    // Layer 3/4 protection (AWS Shield, Cloudflare)
    l3_l4_provider: DdosProvider,

    // Layer 7 protection
    rate_limiting: RateLimitConfig,

    // Anomaly detection
    anomaly_detection: AnomalyConfig,

    // Auto-scaling response
    auto_scale_on_attack: bool,
}

struct RateLimitConfig {
    // Per-customer limits
    requests_per_second: u32,
    burst_size: u32,

    // Per-IP limits (unauthenticated)
    anonymous_rps: u32,

    // Penalty box
    block_duration: Duration,
}
```

---

## Data Protection

### Encryption at Rest

| Data Type | Encryption | Key Management |
|-----------|------------|----------------|
| Container images | AES-256-GCM | AWS KMS |
| Build cache | AES-256-GCM | AWS KMS |
| Metadata (Turso) | AES-256-GCM | AWS KMS |
| Logs | AES-256-GCM | AWS KMS |
| Customer secrets | AES-256-GCM | Customer KMS or Vault |

**Customer-Managed Keys (CMK)**:
```rust
struct EncryptionConfig {
    // Platform-managed (default)
    platform_key: Option<KmsKeyArn>,

    // Customer-managed (enterprise)
    customer_key: Option<CustomerKeyConfig>,
}

struct CustomerKeyConfig {
    // AWS KMS
    kms_key_arn: Option<String>,

    // HashiCorp Vault
    vault_transit_key: Option<String>,

    // Azure Key Vault
    azure_key_id: Option<String>,

    // GCP KMS
    gcp_key_name: Option<String>,
}
```

### Data Classification

```
┌─────────────────────────────────────────────────────────────┐
│                   Data Classification                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐  Customer code, models, data               │
│  │ RESTRICTED  │  PHI, PII, payment data                    │
│  │             │  Encryption: CMK, audit: full               │
│  └─────────────┘                                             │
│         │                                                    │
│         ▼                                                    │
│  ┌─────────────┐  API keys, configuration                   │
│  │CONFIDENTIAL │  Usage metrics, logs                       │
│  │             │  Encryption: Platform KMS, audit: standard │
│  └─────────────┘                                             │
│         │                                                    │
│         ▼                                                    │
│  ┌─────────────┐  Public documentation                      │
│  │   PUBLIC    │  Marketing materials                       │
│  │             │  No encryption required                     │
│  └─────────────┘                                             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Data Retention

| Data Type | Standard | GDPR | HIPAA | PCI |
|-----------|----------|------|-------|-----|
| Access logs | 90 days | 30 days* | 6 years | 1 year |
| Build logs | 30 days | 30 days* | 6 years | 90 days |
| Metrics | 30 days | 30 days* | 6 years | 1 year |
| Container images | Until deleted | Until deleted | Until deleted | Until deleted |
| Customer data | Until deleted | Until deleted | Until deleted | Until deleted |

*GDPR: Customer can request shorter retention

---

## Secret Management

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Secret Management                         │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                   HashiCorp Vault                    │    │
│  │                   (Primary Store)                    │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│           ┌───────────────┼───────────────┐                 │
│           │               │               │                 │
│           ▼               ▼               ▼                 │
│     ┌──────────┐   ┌──────────┐   ┌──────────┐             │
│     │ Beekeeper│   │ Hivemind │   │  Agent   │             │
│     │          │   │          │   │          │             │
│     │ Build    │   │ Workload │   │ Runtime  │             │
│     │ Secrets  │   │ Secrets  │   │ Secrets  │             │
│     └──────────┘   └──────────┘   └──────────┘             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Secret Types

```rust
enum SecretType {
    // Platform secrets (managed by us)
    Platform {
        // Database credentials
        database_credentials: bool,
        // Service-to-service tokens
        service_tokens: bool,
        // Encryption keys
        encryption_keys: bool,
    },

    // Customer secrets (managed by customer)
    Customer {
        // API keys for external services
        external_api_keys: bool,
        // Model weights encryption keys
        model_keys: bool,
        // Environment variables
        environment_secrets: bool,
    },
}
```

### Secret Injection

```rust
impl SecretInjector {
    async fn inject_secrets(&self, workload: &Workload) -> Result<()> {
        // Fetch secrets from Vault
        let secrets = self.vault.get_secrets(
            workload.customer_id(),
            workload.secret_refs()
        ).await?;

        // Inject as environment variables (encrypted in transit)
        for (key, value) in secrets {
            // Never log secret values
            self.inject_env_var(workload, &key, &value)?;
        }

        // Secrets are mounted as tmpfs, not persisted
        Ok(())
    }
}
```

### Rotation Policy

| Secret Type | Rotation Period | Auto-Rotate |
|-------------|-----------------|-------------|
| Service certificates | 24 hours | Yes |
| API keys | 90 days | Optional |
| Database credentials | 30 days | Yes |
| Encryption keys | 1 year | Yes (with re-encryption) |
| Customer secrets | Customer-defined | Customer-managed |

---

## Audit Logging

### Log Categories

| Category | Contents | Retention | Compliance |
|----------|----------|-----------|------------|
| Authentication | Login attempts, API key usage | 1 year | All |
| Authorization | Access decisions, policy evaluations | 1 year | All |
| Data Access | Read/write operations on customer data | 6 years | HIPAA |
| Administrative | Configuration changes, deployments | 1 year | All |
| Security Events | Alerts, anomalies, incidents | 2 years | All |

### Audit Log Format

```rust
struct AuditLog {
    // Timing
    timestamp: DateTime<Utc>,

    // Identity
    actor: Actor,

    // Action
    action: String,
    resource: Resource,
    result: ActionResult,

    // Context
    source_ip: IpAddr,
    user_agent: String,
    request_id: Uuid,

    // Compliance
    compliance_tags: Vec<String>,  // ["hipaa", "gdpr", "pci"]
    data_classification: DataClassification,
}

struct Actor {
    actor_type: ActorType,  // User, Service, System
    id: String,
    customer_id: Option<String>,
    roles: Vec<String>,
}
```

### Log Pipeline

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│Components│───▶│  Agent   │───▶│  Kinesis │───▶│    S3    │
│          │    │  (Logs)  │    │          │    │ (Archive)│
└──────────┘    └──────────┘    └──────────┘    └──────────┘
                                      │
                                      ▼
                               ┌──────────┐
                               │OpenSearch│
                               │ (Query)  │
                               └──────────┘
```

### Tamper Protection

```rust
struct AuditLogIntegrity {
    // Hash chain for tamper detection
    previous_hash: String,
    current_hash: String,

    // Signature
    signature: String,
    signing_key_id: String,

    // External witness (blockchain or external timestamping)
    external_witness: Option<ExternalWitness>,
}
```

---

## Incident Response

### Security Incident Classification

| Severity | Examples | Response Time | Escalation |
|----------|----------|---------------|------------|
| **P1 - Critical** | Data breach, system compromise | 15 minutes | Immediate exec notification |
| **P2 - High** | Authentication bypass, privilege escalation | 1 hour | Security team lead |
| **P3 - Medium** | Suspicious activity, policy violations | 4 hours | Security team |
| **P4 - Low** | Failed login attempts, minor anomalies | 24 hours | Automated handling |

### Incident Response Process

```
┌─────────────────────────────────────────────────────────────┐
│                  Incident Response Flow                      │
│                                                              │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐ │
│  │ Detect   │──▶│ Analyze  │──▶│ Contain  │──▶│Eradicate │ │
│  └──────────┘   └──────────┘   └──────────┘   └──────────┘ │
│       │                                             │       │
│       │         ┌──────────┐   ┌──────────┐        │       │
│       └────────▶│  Report  │◀──│ Recover  │◀───────┘       │
│                 └──────────┘   └──────────┘                 │
│                       │                                     │
│                       ▼                                     │
│                 ┌──────────┐                                │
│                 │  Review  │                                │
│                 └──────────┘                                │
└─────────────────────────────────────────────────────────────┘
```

### Automated Response Actions

```rust
struct AutomatedResponse {
    // Detection triggers
    triggers: Vec<SecurityTrigger>,

    // Automatic actions
    actions: Vec<AutomatedAction>,
}

enum SecurityTrigger {
    // Authentication
    FailedLoginThreshold { count: u32, window: Duration },

    // Anomaly
    UnusualApiPattern { deviation: f64 },

    // Data
    LargeDataExfiltration { threshold_mb: u64 },

    // Network
    PortScanDetected,
}

enum AutomatedAction {
    // Isolation
    IsolateWorkload { workload_id: String },

    // Access
    RevokeApiKey { key_id: String },
    BlockIpAddress { ip: IpAddr, duration: Duration },

    // Notification
    AlertSecurityTeam { severity: Severity },
    NotifyCustomer { customer_id: String },

    // Forensics
    CaptureForensicSnapshot { workload_id: String },
}
```

### Breach Notification

| Regulation | Notification Timeline | Recipients |
|------------|----------------------|------------|
| GDPR | 72 hours | Supervisory authority, affected individuals |
| HIPAA | 60 days | HHS, affected individuals, media (if >500) |
| PCI DSS | Immediately | Card brands, acquiring bank |
| SOC 2 | Per contract | Affected customers |

---

## Security Checklist by Component

### Router

- [ ] TLS 1.3 enforced
- [ ] API key validation implemented
- [ ] Rate limiting configured
- [ ] DDoS protection enabled
- [ ] Request logging enabled
- [ ] IP allowlisting available

### Honeycomb

- [ ] Registry authentication enforced
- [ ] Image signing implemented
- [ ] Vulnerability scanning integrated
- [ ] Per-customer isolation verified
- [ ] Pull/push audit logging enabled
- [ ] Storage encryption enabled

### Beekeeper

- [ ] Build isolation verified
- [ ] Secret injection secure
- [ ] Cache isolation per customer
- [ ] Network isolation during builds
- [ ] Build artifact signing
- [ ] Source code not persisted

### Hivemind

- [ ] mTLS for all connections
- [ ] RBAC implemented
- [ ] Tenant isolation in scheduler
- [ ] Compliance-aware placement
- [ ] Control plane encryption
- [ ] Full audit logging

### Agent

- [ ] Minimal capabilities
- [ ] Secure control plane communication
- [ ] GPU isolation enforced
- [ ] Workload isolation verified
- [ ] Metrics collection secure
- [ ] Tamper detection enabled

---

## Appendix: Compliance Mapping

### SOC 2 Control Mapping

| Trust Service Criteria | Hivemind Control | Document Reference |
|----------------------|------------------|-------------------|
| CC6.1 | RBAC, mTLS, API keys | Authentication & Authorization |
| CC6.2 | Certificate-based auth | Service-to-Service Authentication |
| CC6.3 | Policy-based authorization | Authorization Model |
| CC6.6 | Network segmentation | Network Security |
| CC6.7 | Encryption at rest/transit | Data Protection |
| CC7.1 | Audit logging | Audit Logging |
| CC7.2 | Anomaly detection | Incident Response |

### GDPR Article Mapping

| Article | Requirement | Hivemind Implementation |
|---------|-------------|------------------------|
| 5 | Data minimization | Minimal data collection, retention policies |
| 17 | Right to erasure | Delete API, cascade deletion |
| 20 | Data portability | Export API |
| 25 | Privacy by design | Encryption default, access controls |
| 32 | Security measures | This entire document |
| 33 | Breach notification | Incident response, automated alerts |

### HIPAA Safeguard Mapping

| Safeguard | Specification | Hivemind Implementation |
|-----------|--------------|------------------------|
| Administrative | Security management | Policies, training, risk assessment |
| Administrative | Workforce security | RBAC, background checks |
| Physical | Facility access | Cloud provider controls |
| Physical | Workstation security | N/A (cloud-based) |
| Technical | Access control | Authentication, authorization |
| Technical | Audit controls | Comprehensive logging |
| Technical | Integrity | Checksums, signing |
| Technical | Transmission | TLS 1.3, mTLS |
