variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-southeast-2"
}

variable "project_name" {
  description = "Project name used in resource naming and tagging"
  type        = string
  default     = "lightrag"
}

variable "instance_type" {
  description = "EC2 instance type. Override to t3.small or t3.medium if t3.micro runs out of memory. t3.micro targets ~$7.50/month."
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "Ubuntu 24.04 LTS AMI ID for ap-southeast-2. Leave as default to auto-detect via data source."
  type        = string
  default     = "" # Set to "" to use the aws_ami data source below
}

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed for SSH access (port 22). Restrict to your IP in production. 0.0.0.0/0 is open to the world for development only."
  type        = string
  default     = "0.0.0.0/0"
}

# Data source: find the latest Ubuntu 24.04 LTS AMD64 AMI in the target region.
# Canonical owner ID: 099720109477
# This avoids hardcoding an AMI ID that may expire or change.
data "aws_ami" "ubuntu" {
  count = var.ami_id == "" ? 1 : 0

  owners      = ["099720109477"]
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu-*-24.04 LTS*-amd64"]
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
