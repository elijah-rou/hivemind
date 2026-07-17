terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  name          = "hivemind-bench"
  instance_type = "c5.xlarge"
  node_count    = 5
  vpc_id        = "vpc-01135a9ae5f8a9a64"
  subnet_id     = "subnet-01191c12d89b15cba" # us-east-1a private
  ami           = data.aws_ami.al2023.id

  # Hivemind ports
  agent_base_port   = 9000
  client_base_port  = 9100
  replica_base_port = 9200
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Security group: allow all traffic between bench nodes + SSH from VPC
resource "aws_security_group" "bench" {
  name_prefix = "${local.name}-"
  vpc_id      = local.vpc_id

  # All traffic between nodes in this SG
  ingress {
    from_port = 0
    to_port   = 65535
    protocol  = "tcp"
    self      = true
  }

  # Allow client port from anywhere in VPC (for bench tool)
  ingress {
    from_port   = local.client_base_port
    to_port     = local.client_base_port + local.node_count
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = local.name
  }
}

# IAM role with SSM access
resource "aws_iam_role" "bench" {
  name_prefix = "${local.name}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bench.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "s3_read" {
  role       = aws_iam_role.bench.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_instance_profile" "bench" {
  name_prefix = "${local.name}-"
  role        = aws_iam_role.bench.name
}

resource "aws_instance" "node" {
  count = local.node_count

  ami                    = local.ami
  instance_type          = local.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.bench.id]
  iam_instance_profile   = aws_iam_instance_profile.bench.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name = "${local.name}-node-${count.index}"
  }
}

# Outputs for the start script
output "instance_ids" {
  value = aws_instance.node[*].id
}

output "private_ips" {
  value = aws_instance.node[*].private_ip
}

output "peers_flag" {
  description = "Peer connection string for each node"
  value = [
    for i in range(local.node_count) :
    join(",", [
      for j in range(local.node_count) :
      "${j}@${aws_instance.node[j].private_ip}:${local.replica_base_port + j}"
      if j != i
    ])
  ]
}

output "start_args" {
  description = "Arguments passed directly to each managed Hivemind service"
  value = [
    for i in range(local.node_count) :
    "--node-id ${i} --replica-count ${local.node_count} --worker-port ${local.agent_base_port + i} --client-port ${local.client_base_port + i} --replica-port ${local.replica_base_port + i} --peers ${join(",", [for j in range(local.node_count) : "${j}@${aws_instance.node[j].private_ip}:${local.replica_base_port + j}" if j != i])} --data-dir /var/lib/hivemind/node-${i}"
  ]
}

output "bench_addrs" {
  description = "Comma-separated client addresses for the bench tool"
  value = join(",", [
    for i in range(local.node_count) :
    "${aws_instance.node[i].private_ip}:${local.client_base_port + i}"
  ])
}
