# ─── Data Sources ────────────────────────────────────────────────────────────────

# Current AWS account identity (used for S3 bucket naming)
data "aws_caller_identity" "current" {}

# Existing key pair — managed outside of Terraform
data "aws_key_pair" "app" {
  key_name = "ec2-static-site-key"
}

# Existing subnet — managed outside of Terraform
data "aws_subnet" "app" {
  id = "subnet-0169389af48015c56"
}

# ─── Security Group ─────────────────────────────────────────────────────────────

# IAC-05: New security group for LightRAG EC2 instance.
# Rules: SSH (22), HTTPS placeholder (443), LightRAG API/WebUI (9621)
resource "aws_security_group" "lightrag" {
  name        = "${var.project_name}-sg"
  description = "Allow SSH, HTTPS, and LightRAG port inbound; allow all outbound"

  # SSH — restrict to your IP in production (var.ssh_allowed_cidr)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  # HTTPS placeholder — open to the world for future TLS termination
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # LightRAG API and WebUI — accessible on Elastic IP port 9621
  ingress {
    description = "LightRAG API/WebUI"
    from_port   = 9621
    to_port     = 9621
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-sg"
    Project = var.project_name
  }
}

# ─── IAM Instance Profile ──────────────────────────────────────────────────────

# IAC-04 + IAC-08: IAM role for EC2 with scoped S3 and SSM permissions.
# Assumes EC2 service principal.
resource "aws_iam_role" "lightrag" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# IAM policy: S3 (graph storage bucket) + SSM (Parameter Store secrets).
# Scoped to specific bucket ARN and /lightrag/* SSM path only.
resource "aws_iam_policy" "lightrag" {
  name        = "${var.project_name}-ec2-policy"
  description = "S3 and SSM permissions for LightRAG EC2 instance"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3GraphStorage"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          "${aws_s3_bucket.graph_storage.arn}",
          "${aws_s3_bucket.graph_storage.arn}/*"
        ]
      },
      {
        Sid    = "SSMSecrets"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/lightrag/*"
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "lightrag" {
  role       = aws_iam_role.lightrag.name
  policy_arn = aws_iam_policy.lightrag.arn
}

# IAC-08: Instance profile required for attaching IAM role to EC2.
resource "aws_iam_instance_profile" "lightrag" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.lightrag.name
}

# ─── S3 Bucket for Graph Storage ───────────────────────────────────────────────

# IAC-03: S3 bucket for persisting rag_storage/ directory across instance lifecycle.
# Naming: project-name-graph-storage-<account_id> (globally unique).
# Lifecycle: abort incomplete multipart uploads (7 days), expire noncurrent versions (30 days).
resource "aws_s3_bucket" "graph_storage" {
  bucket = "${var.project_name}-graph-storage-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "${var.project_name}-graph-storage"
    Project = var.project_name
  }
}

# Lifecycle rule: abort incomplete multipart uploads after 7 days.
resource "aws_s3_bucket_lifecycle_configuration" "graph_storage" {
  bucket = aws_s3_bucket.graph_storage.id

  rule {
    id     = "graph-storage-lifecycle"
    status = "Enabled"

    filter {
      prefix = ""
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ─── EC2 Instance ─────────────────────────────────────────────────────────────

# IAC-01: EC2 instance with Ubuntu 24.04 LTS, IAM profile, and bootstrap script.
# IAC-02: Elastic IP attached for static public IP.
# IAC-07: instance_type exposed as variable for override.
resource "aws_instance" "lightrag" {
  ami           = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu[0].id
  instance_type = var.instance_type
  key_name      = data.aws_key_pair.app.key_name
  subnet_id     = data.aws_subnet.app.id

  vpc_security_group_ids = [aws_security_group.lightrag.id]
  iam_instance_profile   = aws_iam_instance_profile.lightrag.name

  # Bootstrap script: swap setup, Docker install, git clone, S3 restore, SSM secrets, compose up.
  # S3 bucket name read from /var/tmp/lightrag-s3-bucket.txt (written by local_file below).
  user_data = file("${path.module}/user_data.sh")

  # Root block device: 20GB (sufficient for Docker images + rag_storage data).
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-server"
    Project = var.project_name
  }
}

# ─── Elastic IP ────────────────────────────────────────────────────────────────

# IAC-02: Elastic IP for static public IP that survives instance stop/start.
# Free while instance is running; ~$3.60/month if instance is stopped.
resource "aws_eip" "lightrag" {
  instance = aws_instance.lightrag.id
  domain   = "vpc"

  tags = {
    Name    = "${var.project_name}-eip"
    Project = var.project_name
  }
}
