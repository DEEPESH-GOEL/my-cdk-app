###############################################################################
# Consumer workspace: app_b   --   reads shared_vpc's outputs via the IaCM API
#
#   GET {base}/iacm/api/orgs/{org}/projects/{project}/workspaces/{id}/resources
#
# `outputs` is a nested object in that response. Each item has name, value
# (always a string), sensitive, and expression. We reduce it to name -> value.
#
# Prerequisites on the workspace:
#   - AWS connector attached
#   - shared_vpc has completed at least one successful apply
#   - the five harness_* variables below are set (harness_api_key as a secret)
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# Variables
###############################################################################

variable "aws_region" {
  description = "Region for the subnet. Must match the shared VPC's region."
  type        = string
  default     = "us-east-1"
}

variable "app_key" {
  description = "Suffix used to select this app's outputs, e.g. vpc_id_app_b."
  type        = string
  default     = "app_b"
}

variable "harness_base_url" {
  description = "Harness gateway base URL. Change for EU or self-managed."
  type        = string
  default     = "https://app.harness.io/gateway"
}

variable "harness_account_id" {
  description = "Harness account identifier. Sent as the Harness-Account header."
  type        = string
}

variable "harness_org_id" {
  description = "Org identifier holding the shared_vpc workspace."
  type        = string
}

variable "harness_project_id" {
  description = "Project identifier holding the shared_vpc workspace."
  type        = string
}

variable "shared_workspace_id" {
  description = "Identifier of the producing workspace."
  type        = string
  default     = "shared_vpc"
}

variable "harness_api_key" {
  description = "Harness PAT or service account token. Sent as x-api-key."
  type        = string
  sensitive   = true
}

variable "api_page_limit" {
  description = "Page size. Raised from the default because outputs ride along with the resource inventory."
  type        = number
  default     = 200
}

###############################################################################
# The read
#
# The postcondition is not optional. `data "http"` does not fail on a non-2xx --
# it returns the error body and lets jsondecode fail later with a character
# offset, which points you at the wrong layer entirely. Asserting the status
# turns a 401 into a message that names the status and the body.
###############################################################################

data "http" "shared_workspace" {
  url = "${var.harness_base_url}/iacm/api/orgs/${var.harness_org_id}/projects/${var.harness_project_id}/workspaces/${var.shared_workspace_id}/resources?limit=${var.api_page_limit}"

  request_headers = {
    "x-api-key"       = var.harness_api_key
    "Harness-Account" = var.harness_account_id
    "Accept"          = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Harness IaCM API returned ${self.status_code}. Body: ${self.response_body}"
    }
  }
}

locals {
  api = jsondecode(data.http.shared_workspace.response_body)

  # name -> value, sensitive outputs dropped.
  shared_outputs = {
    for o in try(local.api.outputs, []) : o.name => o.value
    if try(o.sensitive, false) == false
  }

  vpc_id_key   = "vpc_id_${var.app_key}"
  vpc_cidr_key = "vpc_cidr_${var.app_key}"

  # try() rather than a bare index so a missing key reaches the precondition
  # below instead of blowing up with "key not found" and no context.
  vpc_id   = try(local.shared_outputs[local.vpc_id_key], null)
  vpc_cidr = try(local.shared_outputs[local.vpc_cidr_key], null)
}

###############################################################################
# Consume
###############################################################################

resource "aws_subnet" "app" {
  vpc_id     = local.vpc_id
  cidr_block = local.vpc_cidr == null ? null : cidrsubnet(local.vpc_cidr, 8, 2)

  tags = {
    Name      = "${var.app_key}-subnet"
    ManagedBy = "harness-iacm"
    ReadFrom  = var.shared_workspace_id
    ReadVia   = "iacm-api"
  }

  lifecycle {
    precondition {
      condition = local.vpc_id != null && local.vpc_cidr != null
      error_message = join("", [
        "Could not find '${local.vpc_id_key}' and '${local.vpc_cidr_key}' in ",
        "workspace '${var.shared_workspace_id}'. Outputs the API returned: ",
        length(local.shared_outputs) == 0 ? "(none -- has shared_vpc applied yet?)" : join(", ", sort(keys(local.shared_outputs))),
      ])
    }
  }
}

###############################################################################
# Assertions and diagnostics
###############################################################################

output "resolved_vpc_id" {
  description = "Proof the API read resolved. Renders at plan time."
  value       = local.vpc_id
}

output "available_output_names" {
  description = "Non-sensitive output names the API exposed. Check here first when a lookup fails."
  value       = sort(keys(local.shared_outputs))
}

output "subnet_id" {
  description = "Subnet built inside the shared VPC."
  value       = aws_subnet.app.id
}
