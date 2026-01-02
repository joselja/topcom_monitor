variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "name" {
  type    = string
  default = "monitoring-test"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ssh_cidr" {
  type        = string
  default     = null
  description = "Optional: your public IP /32 to allow SSH. If null, no SSH ingress."
}

variable "grafana_authentication_providers" {
  type        = list(string)
  description = "AMG auth providers. Common: [\"AWS_SSO\"] or [\"SAML\"]."
  default     = ["AWS_SSO"]
}

variable "grafana_admins_group_id" {
  description = "IAM Identity Center group ID for Grafana admins"
  type        = string
}