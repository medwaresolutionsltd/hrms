############################################################################################
# Medware HR on AWS: one EC2 host running Docker Compose (Caddy + app + MariaDB + Redis),
# an encrypted data disk with daily snapshots, a private S3 bucket for backups, and no SSH
# (administration is through AWS Systems Manager Session Manager).
############################################################################################

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Pin everything to one subnet so the instance and its data disk share an availability zone.
data "aws_subnet" "selected" {
  id = sort(data.aws_subnets.default.ids)[0]
}

# Latest Ubuntu 24.04 LTS image, resolved through Canonical's public SSM parameter.
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  backup_bucket = "${var.project_name}-backups-${data.aws_caller_identity.current.account_id}"
  ssm_prefix    = "/${var.project_name}"
}

############################################################################################
# Secrets (generated here, stored encrypted in SSM Parameter Store, read by the server at boot)
############################################################################################

resource "random_password" "db_root" {
  length  = 32
  special = false
}

resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "db_root_password" {
  name  = "${local.ssm_prefix}/db_root_password"
  type  = "SecureString"
  value = random_password.db_root.result
}

resource "aws_ssm_parameter" "admin_password" {
  name  = "${local.ssm_prefix}/admin_password"
  type  = "SecureString"
  value = random_password.admin.result
}

resource "aws_ssm_parameter" "git_token" {
  name  = "${local.ssm_prefix}/git_token"
  type  = "SecureString"
  value = var.git_token != "" ? var.git_token : "none" # SSM does not allow empty values
}

############################################################################################
# Network: HTTP/HTTPS only. There is deliberately no SSH rule.
############################################################################################

resource "aws_security_group" "app" {
  name        = "${var.project_name}-app"
  description = "Medware HR web traffic (HTTP for certificate issuance, HTTPS for users)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description      = "HTTP (redirects to HTTPS, used for certificate issuance)"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description      = "HTTPS"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    description = "Outbound (package installs, GitHub, S3, SMTP)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################################################################################
# Backups bucket: private, encrypted, versioned, TLS-only, with a retention rule.
############################################################################################

resource "aws_s3_bucket" "backups" {
  bucket = local.backup_bucket
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}

    expiration {
      days = var.backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "backups_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket     = aws_s3_bucket.backups.id
  policy     = data.aws_iam_policy_document.backups_tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

############################################################################################
# Instance role: Session Manager access, read its own secrets, write backups. Nothing else.
############################################################################################

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.project_name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ReadOwnSecrets"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"]
  }

  statement {
    sid       = "ListBackupBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    sid       = "WriteBackups"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "${var.project_name}-app"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-instance"
  role = aws_iam_role.app.name
}

############################################################################################
# The server and its data disk
############################################################################################

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name   = "${var.project_name}-data"
    Backup = "daily" # picked up by the snapshot policy below
  }

  # Payroll data lives here. Terraform refuses to destroy it; see docs/AWS_DEPLOYMENT.md to remove it deliberately.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.selected.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true
  disable_api_termination     = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    region           = var.region
    project          = var.project_name
    domain           = var.domain_name
    repo_url         = var.repo_url
    repo_branch      = var.repo_branch
    bucket           = aws_s3_bucket.backups.bucket
    volume_id_nodash = replace(aws_ebs_volume.data.id, "-", "")
  })

  # Changing bootstrap settings must never silently replace the production server.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = {
    Name = var.project_name
  }

  depends_on = [
    aws_ssm_parameter.db_root_password,
    aws_ssm_parameter.admin_password,
    aws_ssm_parameter.git_token,
    aws_iam_role_policy.app,
    aws_iam_role_policy_attachment.ssm_core,
  ]
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
}

resource "aws_eip" "app" {
  domain = "vpc"

  tags = {
    Name = var.project_name
  }
}

resource "aws_eip_association" "app" {
  allocation_id = aws_eip.app.id
  instance_id   = aws_instance.app.id
}

############################################################################################
# Resilience: daily snapshots of the data disk, and automatic recovery from host failure.
############################################################################################

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.project_name}-snapshots"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  description        = "Daily snapshots of the ${var.project_name} data disk"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags = {
      Backup = "daily"
    }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["01:00"]
      }

      retain_rule {
        count = var.snapshot_retention_count
      }

      copy_tags = true
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "auto_recover" {
  alarm_name          = "${var.project_name}-auto-recover"
  alarm_description   = "Recover the instance onto healthy hardware if the underlying host fails"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  period              = 60
  evaluation_periods  = 2
  dimensions = {
    InstanceId = aws_instance.app.id
  }
  alarm_actions = ["arn:aws:automate:${var.region}:ec2:recover"]
}
