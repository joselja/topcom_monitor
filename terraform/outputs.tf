output "amp_workspace_id" {
  value = aws_prometheus_workspace.this.id
}

output "amp_remote_write_url" {
  value = local.amp_remote_write_url
}

output "amg_workspace_id" {
  value = aws_grafana_workspace.this.id
}

output "amg_endpoint" {
  value = aws_grafana_workspace.this.endpoint
}

output "cloudwatch_log_group" {
  value = aws_cloudwatch_log_group.system.name
}

output "ec2_instance_id" {
  value = aws_instance.host.id
}

output "cloudwatch_logs_dashboard" {
  value = aws_cloudwatch_dashboard.monitoring_logs.dashboard_name
}