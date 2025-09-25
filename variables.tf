variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "instance_type" {
  description = "EC2 instance type for K3s server"
  type        = string
  default     = "t3.medium"
}

variable "public_key_path" {
  description = "Path to public SSH key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "cluster_name" {
  description = "K3s cluster name"
  type        = string
  default     = "k3s-cluster"
}
