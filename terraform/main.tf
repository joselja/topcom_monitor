terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# ----------------------------
# Managed Prometheus (AMP)
# ----------------------------
resource "aws_prometheus_workspace" "this" {
  alias = "${var.name}-amp"
}

# AMP remote_write endpoint format:
# https://aps-workspaces.<region>.amazonaws.com/workspaces/<workspace_id>/api/v1/remote_write
locals {
  amp_remote_write_url = "https://aps-workspaces.${var.aws_region}.amazonaws.com/workspaces/${aws_prometheus_workspace.this.id}/api/v1/remote_write"
}

# ----------------------------
# CloudWatch Logs group for host logs
# ----------------------------
resource "aws_cloudwatch_log_group" "system" {
  name              = "/${var.name}/system"
  retention_in_days = 14
}

# ----------------------------
# Managed Grafana (AMG)
# ----------------------------
resource "aws_iam_role" "grafana" {
  name = "${var.name}-amg-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}


# Permissions for AMG to query AMP + CloudWatch (metrics/logs)
data "aws_iam_policy_document" "grafana_access" {
  statement {
    actions = [
      "aps:QueryMetrics",
      "aps:GetSeries",
      "aps:GetLabels",
      "aps:GetMetricMetadata"
    ]
    resources = [aws_prometheus_workspace.this.arn]
  }

  statement {
    actions = [
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:DescribeAlarms"
    ]
    resources = ["*"]
  }

  statement {
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "logs:GetQueryResults"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "grafana_access" {
  name   = "${var.name}-amg-access"
  policy = data.aws_iam_policy_document.grafana_access.json
}

resource "aws_iam_role_policy_attachment" "grafana_access" {
  role       = aws_iam_role.grafana.name
  policy_arn = aws_iam_policy.grafana_access.arn
}

resource "aws_grafana_workspace" "this" {
  name                     = "${var.name}-amg"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  account_access_type      = "CURRENT_ACCOUNT"

  role_arn = aws_iam_role.grafana.arn

  data_sources = [
    "PROMETHEUS",
    "CLOUDWATCH",
  ]
}

resource "aws_grafana_role_association" "admins" {
  workspace_id = aws_grafana_workspace.this.id
  role         = "ADMIN"
  group_ids    = [var.grafana_admins_group_id]
}

# ----------------------------
# EC2 host running node_exporter + ADOT + CloudWatch Agent
# ----------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "ec2" {
  name   = "${var.name}-ec2-sg"
  vpc_id = data.aws_vpc.default.id

  # Optional SSH
  dynamic "ingress" {
    for_each = var.ssh_cidr == null ? [] : [1]
    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.ssh_cidr]
    }
  }

  # node_exporter (optional open only within VPC; keeping closed by default)
  # If you need to scrape from outside the instance, open 9100 carefully.
  # ingress { from_port=9100 to_port=9100 protocol="tcp" cidr_blocks=["10.0.0.0/8"] }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 role permissions:
# - remote_write to AMP (aps:RemoteWrite)
# - put logs to CloudWatch Logs
resource "aws_iam_role" "ec2" {
  name = "${var.name}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

data "aws_iam_policy_document" "ec2_policy" {
  statement {
    actions   = ["aps:RemoteWrite"]
    resources = [aws_prometheus_workspace.this.arn]
  }

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = ["${aws_cloudwatch_log_group.system.arn}:*"]
  }

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:DescribeLogGroups"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ec2_policy" {
  name   = "${var.name}-ec2-policy"
  policy = data.aws_iam_policy_document.ec2_policy.json
}

resource "aws_iam_role_policy_attachment" "ec2_attach" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.ec2_policy.arn
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

locals {
  adot_cfg_rendered = replace(
    replace(file("${path.module}/adot-config.yaml"), "__AMP_REMOTE_WRITE_URL__", local.amp_remote_write_url),
    "__AWS_REGION__",
    var.aws_region
  )


  cwagent_cfg_rendered = replace(
    file("${path.module}/cloudwatch-agent.json"),
    "/monitoring-test/system",
    "/${var.name}/system"
  )
}
  

resource "aws_instance" "host" {
  ami                         = "ami-09c54d172e7aa3d9a" # Amazon Linux 2023 in eu-west-1
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    amp_remote_write_url = local.amp_remote_write_url
    AWS_REGION           = var.aws_region
  })

  user_data_replace_on_change = true

  tags = {
    Name = "${var.name}-host"
  }
}

resource "aws_cloudwatch_dashboard" "monitoring_logs" {
  dashboard_name = "${var.name}-monitoring-logs"

  dashboard_body = replace(
    file("${path.module}/dashboard-logs.json"),
    "__LOG_GROUP__",
    aws_cloudwatch_log_group.system.name
  )
}

resource "aws_iam_role" "ec2_ssm" {
  name = "${var.name}-ec2-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
