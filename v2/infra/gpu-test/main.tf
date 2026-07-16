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
  name      = "hivemind-gpu-test"
  vpc_id    = "vpc-01135a9ae5f8a9a64"
  subnet_id = "subnet-01191c12d89b15cba" # us-east-1a private
}

# Use the Deep Learning AMI which has NVIDIA drivers, containerd, and Docker pre-installed
data "aws_ami" "dlami" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Deep Learning Base AMI with Single CUDA (Ubuntu 22.04) *"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_security_group" "gpu_test" {
  name_prefix = "${local.name}-"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = local.name }
}

resource "aws_iam_role" "gpu_test" {
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
  role       = aws_iam_role.gpu_test.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "s3" {
  role       = aws_iam_role.gpu_test.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_instance_profile" "gpu_test" {
  name_prefix = "${local.name}-"
  role        = aws_iam_role.gpu_test.name
}

resource "aws_instance" "gpu" {
  ami                    = data.aws_ami.dlami.id
  instance_type          = "g4dn.xlarge" # 1x T4 GPU, 4 vCPU, 16GB
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.gpu_test.id]
  iam_instance_profile   = aws_iam_instance_profile.gpu_test.name

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  user_data = <<-USERDATA
    #!/bin/bash
    set -x

    export DEBIAN_FRONTEND=noninteractive

    # Base build tools + containerd
    apt-get update -qq
    apt-get install -y -qq build-essential pkg-config libssl-dev containerd fuse3

    # Rust
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

    # Protobuf compiler (needed if containerd-client is ever re-added)
    curl -sLO https://github.com/protocolbuffers/protobuf/releases/download/v28.3/protoc-28.3-linux-x86_64.zip
    unzip -o protoc-28.3-linux-x86_64.zip -d /usr/local bin/protoc
    rm protoc-28.3-linux-x86_64.zip

    # gVisor (runsc)
    curl -fsSL https://gvisor.dev/archive.key | gpg --batch --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" > /etc/apt/sources.list.d/gvisor.list
    apt-get update -qq && apt-get install -y -qq runsc

    # NVIDIA Container Toolkit
    rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq && apt-get install -y -qq nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=containerd

    # Nydus snapshotter (skip if download fails - not critical for core tests)
    NYDUS_VER=v0.14.0
    curl -sfL "https://github.com/containerd/nydus-snapshotter/releases/download/$NYDUS_VER/nydus-snapshotter-$NYDUS_VER-linux-amd64.tar.gz" -o /tmp/nydus-snap.tar.gz && \
      tar xzf /tmp/nydus-snap.tar.gz -C /usr/local/bin || echo "nydus snapshotter install skipped"
    NYDUSD_VER=v2.2.5
    curl -sfL "https://github.com/dragonflyoss/nydus/releases/download/$NYDUSD_VER/nydus-static-$NYDUSD_VER-linux-amd64.tgz" -o /tmp/nydusd.tar.gz && \
      tar xzf /tmp/nydusd.tar.gz -C /usr/local/bin --strip-components=1 || echo "nydusd install skipped"

    # JuiceFS (skip if download fails)
    curl -sSL https://d.juicefs.com/install | sh - || echo "juicefs install skipped"

    # Configure containerd: generate default config FIRST, then layer on runtimes
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml

    # Register nvidia runtime (must come AFTER config default)
    nvidia-ctk runtime configure --runtime=containerd --set-as-default

    # Restart containerd to pick up all runtime config
    systemctl restart containerd

    echo "USERDATA_COMPLETE" > /tmp/userdata-done
  USERDATA

  tags = { Name = local.name }
}

output "instance_id" {
  value = aws_instance.gpu.id
}

output "private_ip" {
  value = aws_instance.gpu.private_ip
}

output "ami" {
  value = data.aws_ami.dlami.id
}
