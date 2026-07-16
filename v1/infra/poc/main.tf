terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  default = "us-east-1"
}

variable "replica_ami_id" {
  description = "Replica AMI (Amazon Linux 2023 recommended; deploy.sh defaults to ec2-user)"
  type        = string
  default     = "ami-098e39bafa7e7303d"
}

variable "worker_ami_id" {
  description = "Worker AMI (Hivemind hivemind-standalone; ubuntu-eks-nydus fork for standalone hivemind workers)"
  type        = string
  default     = "ami-0714f823ff4e72d73"
}

variable "ssh_public_key" {
  description = "OpenSSH public key for aws_key_pair (ed25519 recommended)"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILralVpTQ0tgwve6HyxwiZ0bzY1wymH/lCm91uL5NjcP"
}

variable "encryption_key" {
  description = "64-char hex PSK for frame encryption"
  type        = string
  sensitive   = true
  default     = ""
}

variable "s3_backup_uri" {
  description = "S3 URI for journal backup (e.g. s3://bucket/hivemind/journal.bin)"
  type        = string
  default     = ""
}

variable "ecr_repository_name" {
  description = "POC ECR repository for workload images. Terraform force-deletes it during teardown."
  type        = string
  default     = "hivemind-poc"
}

variable "ssh_cidr" {
  description = "CIDR block allowed for SSH and API/dashboard access. The runbook sets this to the deployer /32."
  type        = string
  default     = "127.0.0.1/32"
}

variable "vpc_id" {
  description = "VPC ID (uses default VPC if empty)"
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet ID (uses first default subnet if empty)"
  type        = string
  default     = ""
}

locals {
  name = "hivemind-poc"
}

resource "aws_ecr_repository" "workloads" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = { Name = "hivemind-poc-workloads" }
}

resource "aws_key_pair" "poc" {
  key_name   = "${local.name}-deployer"
  public_key = var.ssh_public_key
}

# ----- Security Group -----

resource "aws_security_group" "hivemind" {
  name_prefix = "hivemind-poc-"
  vpc_id      = var.vpc_id != "" ? var.vpc_id : null

  # SSH (restrict via ssh_cidr variable)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  # Hivemind ports (internal)
  ingress {
    from_port = 8080
    to_port   = 9300
    protocol  = "tcp"
    self      = true
  }

  ingress {
    from_port = 9300
    to_port   = 9300
    protocol  = "udp"
    self      = true
  }

  # HTTP API + Dashboard (restricted to deployer CIDR to avoid
  # GuardDuty PortProbeUnprotectedPort findings from internet scanners)
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "hivemind-poc" }
}

# ----- Replicas (c5.xlarge) -----

resource "aws_instance" "replica" {
  count         = 5
  ami           = var.replica_ami_id
  instance_type = "c5.xlarge"
  key_name      = aws_key_pair.poc.key_name

  vpc_security_group_ids = [aws_security_group.hivemind.id]
  subnet_id              = var.subnet_id != "" ? var.subnet_id : null

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/replica-init.sh", {
    node_id        = count.index
    replica_count  = 5
    peer_port      = 9102
    encryption_key = var.encryption_key
    s3_backup_uri  = var.s3_backup_uri
    region         = var.region
    peers          = "" # filled by deploy.sh after IPs are known
  }))

  tags = {
    Name = "hivemind-replica-${count.index}"
    Role = "replica"
  }
}

# ----- Worker instances -----

resource "aws_instance" "worker_cpu" {
  ami           = var.worker_ami_id
  instance_type = "c5.xlarge"
  key_name      = aws_key_pair.poc.key_name

  vpc_security_group_ids = [aws_security_group.hivemind.id]
  subnet_id              = var.subnet_id != "" ? var.subnet_id : null

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/worker-init.sh", {
    replica_addr   = ""
    encryption_key = var.encryption_key
  }))

  tags = {
    Name = "hivemind-worker-cpu"
    Role = "worker"
  }
}

resource "aws_instance" "worker_gpu" {
  ami           = var.worker_ami_id
  instance_type = "g4dn.xlarge"
  key_name      = aws_key_pair.poc.key_name

  vpc_security_group_ids = [aws_security_group.hivemind.id]
  subnet_id              = var.subnet_id != "" ? var.subnet_id : null

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/worker-init.sh", {
    replica_addr   = ""
    encryption_key = var.encryption_key
  }))

  tags = {
    Name = "hivemind-worker-gpu"
    Role = "worker"
  }
}

# ----- Outputs -----

output "replica_ami" {
  value = var.replica_ami_id
}

output "worker_ami" {
  value = var.worker_ami_id
}

output "replica_ips" {
  value = aws_instance.replica[*].private_ip
}

output "replica_public_ips" {
  value = aws_instance.replica[*].public_ip
}

output "worker_cpu_ip" {
  value = aws_instance.worker_cpu.private_ip
}

output "worker_cpu_public_ip" {
  value = aws_instance.worker_cpu.public_ip
}

output "worker_gpu_ip" {
  value = aws_instance.worker_gpu.private_ip
}

output "worker_gpu_public_ip" {
  value = aws_instance.worker_gpu.public_ip
}

output "api_url" {
  value = "http://${aws_instance.replica[0].public_ip}:8080"
}

output "dashboard_url" {
  value = "http://${aws_instance.replica[0].public_ip}:8080/dashboard"
}

output "ecr_repository_name" {
  value = aws_ecr_repository.workloads.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.workloads.repository_url
}
