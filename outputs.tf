output "k3s_server_public_ip" {
  description = "Public IP of K3s server"
  value       = aws_instance.k3s_server.public_ip
}

output "k3s_server_private_ip" {
  description = "Private IP of K3s server"
  value       = aws_instance.k3s_server.private_ip
}

output "argocd_url" {
  description = "ArgoCD URL"
  value       = "http://${aws_instance.k3s_server.public_ip}"
}

output "ssh_command" {
  description = "SSH command to connect to K3s server"
  value       = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_instance.k3s_server.public_ip}"
}

output "kubeconfig_command" {
  description = "Command to get kubeconfig"
  value       = "scp -i ~/.ssh/id_rsa ubuntu@${aws_instance.k3s_server.public_ip}:/etc/rancher/k3s/k3s.yaml ~/.kube/config"
}
