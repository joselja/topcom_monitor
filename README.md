# AWS Monitoring Stack – AMP, AMG, ADOT, EC2

## Objective

Deploy a complete **metrics and logs monitoring solution** for an EC2 host in AWS using:

- **Amazon Managed Service for Prometheus (AMP)** – metrics backend
- **Amazon Managed Grafana (AMG)** – visualization layer
- **AWS Distro for OpenTelemetry (ADOT)** – metrics collection and export
- **CloudWatch Logs + CloudWatch Agent** – system logs
- **Terraform** – infrastructure as code

Final outcome:

- Visualize **CPU, RAM, disk, IO, network** (via node\_exporter)
- Query **system logs** from Grafana


---

## Architecture

```
EC2 (Amazon Linux 2023)
 ├─ node_exporter (9100)
 ├─ ADOT Collector
 │    └─ remote_write → AMP
 ├─ CloudWatch Agent
 │    └─ logs → CloudWatch Logs
 │
AMP  ←── Grafana (Prometheus datasource)
CloudWatch Logs ←── Grafana (CloudWatch datasource)
```

---

## Components

### 1. Amazon Managed Prometheus (AMP)

- Workspace created via Terraform
- Endpoint used **only** for `remote_write`

Correct format:

```
https://aps-workspaces.<region>.amazonaws.com/workspaces/<ws-id>/api/v1/remote_write
```

---

### 2. Amazon Managed Grafana (AMG)

Key configuration:

- `authentication_providers = ["AWS_SSO"]`
- `permission_type = SERVICE_MANAGED`
- Access assigned via **IAM Identity Center groups** (`aws_grafana_role_association`)

#### Identity Center groups (mandatory for first‑time access)

To be able to **access Grafana successfully on the first login**, you must **create and assign groups in AWS IAM Identity Center** *before* users attempt to log in.

**Why this is required:**
- Amazon Managed Grafana does **not** grant implicit access to users
- Users must belong to a group explicitly associated with a Grafana role
- Otherwise, login fails with `sso.auth.access-denied`

**Recommended setup:**
- Create at least one group in IAM Identity Center, for example:
  - `grafana-admins`
  - `grafana-viewers`
- Assign users to these groups
- Map groups to Grafana roles using Terraform:

```hcl
resource "aws_grafana_role_association" "admins" {
  workspace_id = aws_grafana_workspace.this.id
  role         = "ADMIN"
  group_ids    = [var.grafana_admins_group_id]
}
```

With this in place, users can access Grafana **immediately after the workspace is created**, without any manual steps in the console.

---

#### Grafana Datasources

**Prometheus (AMP)**

- Type: Prometheus
- URL:

```
https://aps-workspaces.<region>.amazonaws.com/workspaces/<ws-id>
```

- SigV4: enabled
- Auth provider: Workspace IAM role

**CloudWatch**

- Type: CloudWatch
- Region: same region as log group (`eu-west-1`)

---

### 3. EC2 Host

- Amazon Linux 2023
- Instance profile includes:
  - `AmazonSSMManagedInstanceCore`
  - `aps:RemoteWrite` on the **AMP workspace ARN**
  - CloudWatch Logs permissions

SSM is used for:

- Remote access
- Debugging

---

## node\_exporter

Installed via `user_data`:

- Port: `9100`
- Verification:

```
curl localhost:9100/metrics
```

---

## AWS Distro for OpenTelemetry (ADOT)

### What is ADOT and why it is required

**AWS Distro for OpenTelemetry (ADOT)** is AWS’s supported distribution of the OpenTelemetry project. It is responsible for **collecting, processing, and exporting telemetry data**.

In this architecture, ADOT plays a **critical role**:

### What ADOT does here

- Scrapes Prometheus metrics from `node_exporter` (`localhost:9100`)
- Signs requests using **SigV4** with the EC2 IAM role
- Sends metrics to **Amazon Managed Prometheus (AMP)** using `remote_write`

Without ADOT:

- Grafana cannot directly scrape EC2 instances
- AMP cannot ingest metrics from hosts

### Why ADOT instead of a classic Prometheus server

| ADOT                | Self‑managed Prometheus |
| ------------------- | ----------------------- |
| No local TSDB       | Requires local storage  |
| Native IAM + SigV4  | Complex auth to AMP     |
| AWS‑supported       | Manual ops & upgrades   |
| Ideal for EC2 / EKS | Better for on‑prem      |


---

## ADOT Configuration (critical)

### Correct config path

⚠️ **ADOT ONLY reads:**

```
/opt/aws/aws-otel-collector/etc/config.yaml
```

Any other path (e.g. `/etc/otelcol/...`) is ignored.

### Minimal working config

```yaml
receivers:
  prometheus:
    config:
      global:
        scrape_interval: 15s
      scrape_configs:
        - job_name: node_exporter
          static_configs:
            - targets: ["127.0.0.1:9100"]

exporters:
  prometheusremotewrite:
    endpoint: https://aps-workspaces.<region>.amazonaws.com/workspaces/<ws-id>/api/v1/remote_write
    auth:
      authenticator: sigv4auth

extensions:
  sigv4auth:
    region: <region>
    service: aps

service:
  extensions: [sigv4auth]
  pipelines:
    metrics:
      receivers: [prometheus]
      exporters: [prometheusremotewrite]
```

---

## CloudWatch Logs

### CloudWatch Agent

Used to send system logs to CloudWatch Logs.

Log group:

```
/monitoring-test/system
```

Typical files:

- `/var/log/cloud-init-output.log`
- `/var/log/messages`

---

## Dashboards

### 1. Host metrics (CPU / RAM / IO)

- Dashboard: **Node Exporter Full (ID 1860)**
- Imported manually into Grafana
- Datasource parameterized (`${ds_prometheus}`)


---

### 2. Logs dashboard in Grafana

Panel type: **Logs** Datasource: **CloudWatch** Log group: `/monitoring-test/system`

Query (all logs):

```sql
fields @timestamp, @logStream, @message
| sort @timestamp desc
| limit 10000
```

---

## Terraform – Key Points

### user\_data and instance recreation

- `user_data` only runs on instance creation
- Any change ⇒ instance must be recreated

```bash
terraform taint aws_instance.host
terraform apply
```

### IAM and AMP coupling

- AMP workspace ARN is part of the IAM authorization
- Recreating AMP requires recreating the IAM policy

```bash
terraform destroy -target aws_iam_policy.ec2_policy
terraform apply
```

---

## Troubleshooting

### 1. `node_cpu_seconds_total` returns no data

**Cause**: AMP is not receiving metrics.

Checks:

```bash
curl localhost:9100/metrics
sudo journalctl -u aws-otel-collector -n 50 --no-pager
```

---

### 2. ADOT scrapes nothing

**Cause**: Config written to the wrong path.

Correct path:

```
/opt/aws/aws-otel-collector/etc/config.yaml
```

---

### 3. `remote write request failed`

**Cause**: IAM policy points to a different AMP workspace.

Fix:

```bash
terraform destroy -target aws_iam_policy.ec2_policy
terraform apply
```

---

### 4. SSM Offline after instance recreation

**Cause**: Instance profile mismatch or failed cloud-init.

Fix:

```bash
terraform taint aws_instance.host
terraform apply
```

---

### 5. Logs visible in CloudWatch but not in Grafana

**Cause**: Wrong region, log group, or time range in the panel.

Base query:

```sql
fields @timestamp, @logStream, @message
| sort @timestamp desc
| limit 10000
```

---

## Alerts & Next Evolutions

This stack is ready to be extended with **alerting and advanced observability capabilities**. Below are the recommended next steps, aligned with AWS‑native services and best practices.

---

### 1. Alerting with Amazon Managed Prometheus (AMP)

AMP supports **Prometheus alert rules** evaluated server‑side.

**What you can do:**

- Define PromQL‑based alert rules (CPU, memory, disk, node down, etc.)
- Offload alert evaluation to AMP (no local Prometheus required)

**Typical alerts:**

- `node_cpu_seconds_total` high CPU usage
- `node_memory_MemAvailable_bytes` low available memory
- `node_filesystem_avail_bytes` low disk space
- `up == 0` (node\_exporter down)

**How it works:**

- Alert rules are stored in AMP
- AMP evaluates them continuously
- Alerts are sent to an Alertmanager endpoint

> AMP does **not** send notifications by itself. It requires Alertmanager.

---

### 2. Alertmanager (Managed or Self‑Managed)

You have two main options:

#### Option A — Amazon Managed Alertmanager (Recommended)

- Fully managed by AWS
- Integrated with AMP
- Supports routing to:
  - Amazon SNS
  - Slack
  - PagerDuty
  - Email

This is the **cleanest option** in AWS‑native environments.

#### Option B — Self‑managed Alertmanager

- Run Alertmanager on EC2 or EKS
- More control, more operations
- Rarely needed unless you have advanced routing requirements

---

### 3. Grafana Alerts

Amazon Managed Grafana supports **Grafana‑managed alerts**.

**When to use them:**

- Simple alerts tied to dashboards
- UI‑driven alert creation
- Faster iteration during early phases

**Limitations:**

- Alerts live inside Grafana
- Less portable than Prometheus rules
- Not ideal for large‑scale or multi‑environment setups

**Recommendation:**

- Use **Grafana alerts for quick wins**
- Migrate to **AMP + Alertmanager** for production‑grade alerting

---

### 4. Logs‑based Alerts (CloudWatch)

For logs, use **CloudWatch Logs Metric Filters**:

- Convert log patterns into metrics
- Trigger CloudWatch Alarms

Examples:

- Repeated `error` or `panic` messages
- ADOT or node\_exporter crashes
- Failed system services

These alarms can notify via SNS and complement Prometheus alerts.

---

### 5. Multi‑Host and Scale‑Out Evolution

Next natural extensions:

- Monitor **multiple EC2 instances** (same ADOT pattern)
- Introduce **instance labels** (`env`, `role`, `team`)
- Reuse dashboards with dynamic variables

At scale, the same architecture applies unchanged.






