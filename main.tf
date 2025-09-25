terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC
resource "aws_vpc" "k3s_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name = "k3s-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "k3s_igw" {
  vpc_id = aws_vpc.k3s_vpc.id
  
  tags = {
    Name = "k3s-igw"
  }
}

# Public Subnet
resource "aws_subnet" "k3s_public_subnet" {
  vpc_id                  = aws_vpc.k3s_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  
  tags = {
    Name = "k3s-public-subnet"
  }
}

# Route Table
resource "aws_route_table" "k3s_public_rt" {
  vpc_id = aws_vpc.k3s_vpc.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.k3s_igw.id
  }
  
  tags = {
    Name = "k3s-public-rt"
  }
}

resource "aws_route_table_association" "k3s_public_rta" {
  subnet_id      = aws_subnet.k3s_public_subnet.id
  route_table_id = aws_route_table.k3s_public_rt.id
}

# Security Group
resource "aws_security_group" "k3s_sg" {
  name_prefix = "k3s-sg"
  vpc_id      = aws_vpc.k3s_vpc.id
  
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "k3s-sg"
  }
}

# Key Pair
resource "aws_key_pair" "k3s_key" {
  key_name   = "k3s-key"
  public_key = file(var.public_key_path)
}

# EC2 Instance for K3s
resource "aws_instance" "k3s_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.k3s_key.key_name
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]
  subnet_id              = aws_subnet.k3s_public_subnet.id
  
  user_data = templatefile("${path.module}/k3s-install.sh", {
    argocd_manifest = base64encode(file("${path.module}/argocd-manifest.yaml"))
  })
  
  tags = {
    Name = "k3s-server"
  }
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-22.04-amd64-server-*"]
  }
}
