variable "project_name" {
  description = "Prefix for resource names and the SSM parameter path."
  type        = string
  default     = "medware-hr"
}

variable "region" {
  description = "AWS region. af-south-1 (Cape Town) is closest to Kenya but must be enabled in your AWS account first (Account settings > AWS Regions). eu-west-1 (Ireland) is a good alternative that needs no opt-in."
  type        = string
  default     = "af-south-1"
}

variable "domain_name" {
  description = "Full host name users will visit, e.g. hr.yourdomain.co.ke. It becomes the Frappe site name, so choose it carefully."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a lowercase host name such as hr.example.co.ke."
  }
}

variable "repo_url" {
  description = "HTTPS clone URL of the repository that contains hrms-develop/."
  type        = string
  default     = "https://github.com/medwaresolutionsltd/hrms.git"
}

variable "repo_branch" {
  description = "Branch to deploy."
  type        = string
  default     = "main"
}

variable "git_token" {
  description = "GitHub fine-grained token with read-only Contents access. Only needed if the repository is private. Stored encrypted in SSM, never on the server's disk."
  type        = string
  default     = ""
  sensitive   = true
}

variable "instance_type" {
  description = "EC2 size. t3.large (2 vCPU, 8 GB) suits a few hundred employees. Do not go below 4 GB of memory."
  type        = string
  default     = "t3.large"
}

variable "root_volume_gb" {
  description = "Size of the operating-system disk."
  type        = number
  default     = 30
}

variable "data_volume_gb" {
  description = "Size of the encrypted data disk holding the database, uploads and backups."
  type        = number
  default     = 50
}

variable "backup_retention_days" {
  description = "How long daily backups are kept in S3 before they expire."
  type        = number
  default     = 365
}

variable "snapshot_retention_count" {
  description = "How many daily EBS snapshots of the data disk to keep."
  type        = number
  default     = 14
}
