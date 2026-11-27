terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Terraform state contains the generated passwords. For anything beyond a first trial, store it
  # in a private, encrypted, versioned S3 bucket instead of on a laptop:
  #
  # backend "s3" {
  #   bucket  = "your-terraform-state-bucket"
  #   key     = "medware-hr/terraform.tfstate"
  #   region  = "af-south-1"
  #   encrypt = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}
