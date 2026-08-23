###############################################################################
# Consumer workspace: app_b   --   reads shared_vpc's outputs via the IaCM API
#
#   GET {base}/iacm/api/orgs/{org}/projects/{project}/workspaces/{id}/resources
#
# Reads the MAP outputs the producer already exposes -- `vpc_ids` and
# `vpc_cidrs` -- and pulls this app's entry out of each. No changes needed on
# the producer side.
#
# The wrinkle: every output `value` in that API response is a STRING, so a map
# output arrives serialised and the encoding is undocumented. The locals below
# try three decodings in order and surface the raw text if all three miss.
#
# Prerequisites on the workspace:
#   - AWS connector attached
#   - shared_vpc has completed at least one successful apply
#   - the four harness_* variables set (harness_api_key as a secret)
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
  description = "Key to look up inside the vpc_ids / vpc_cidrs maps."
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
  description = "Org identifier holding the shared workspace."
  type        = string
}

variable "harness_project_id" {
  description = "Project identifier holding the shared workspace."
  type        = string
}

variable "shared_workspace_id" {
  description = "Identifier of the producing workspace."
  type        = string
  default     = "shared_vpc"
}

variable "vpc_ids_output_name" {
  description = "Name of the producer's map-of-ids output."
  type        = string
  default     = "vpc_ids"
}

variable "vpc_cidrs_output_name" {
  description = "Name of the producer's map-of-cidrs output."
  type        = string
  default     = "vpc_cidrs"
}

variable "harness_api_key" {
  description = "Harness PAT or service account token. Sent as x-api-key."
  type        = string
  sensitive   = true
}

variable "api_page_limit" {
  description = "Page size. Outputs ride along with the resource inventory, so keep this generous."
  type        = number
  default     = 200
}

###############################################################################
# The read
#
# The postcondition is not optional. `data "http"` does not fail on a non-2xx --
# it returns the error body and lets jsondecode fail later with a character
# offset, pointing you at the wrong layer entirely.
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

###############################################################################
# Decode
###############################################################################

locals {
  api = jsondecode(data.http.shared_workspace.response_body)

  # name -> value (still a string at this point). Sensitive outputs dropped.
  shared_outputs = {
    for o in try(local.api.outputs, []) : o.name => o.value
    if try(o.sensitive, false) == false
  }

  raw_ids   = try(local.shared_outputs[var.vpc_ids_output_name], null)
  raw_cidrs = try(local.shared_outputs[var.vpc_cidrs_output_name], null)

  # Attempt 1 -- the value is already a real map (in case the API stops
  # stringifying complex values in some future version).
  ids_as_map   = try(tomap({ for k, v in local.raw_ids : k => tostring(v) }), null)
  cidrs_as_map = try(tomap({ for k, v in local.raw_cidrs : k => tostring(v) }), null)

  # Attempt 2 -- the value is a JSON object encoded as a string, i.e.
  # {"app_a":"vpc-aaa","app_b":"vpc-bbb"}
  ids_from_json   = try(tomap({ for k, v in jsondecode(local.raw_ids) : k => tostring(v) }), null)
  cidrs_from_json = try(tomap({ for k, v in jsondecode(local.raw_cidrs) : k => tostring(v) }), null)

  # Attempt 3 -- anything else key/value shaped: HCL rendering with `=`,
  # Go's map[k:v k:v], quoted or bare. Matches key <sep> value pairs.
  kv_pattern = "\"?([A-Za-z0-9_.-]+)\"?[[:space:]]*[:=][[:space:]]*\"?([^\",}\\][:space:]]+)\"?"

  # try() wraps these because locals are evaluated eagerly -- without it,
  # tostring() on an already-decoded object aborts the plan even when attempt 1
  # already succeeded.
  ids_from_regex = try(tomap({
    for m in regexall(local.kv_pattern, tostring(local.raw_ids)) : m[0] => m[1]
  }), null)
  cidrs_from_regex = try(tomap({
    for m in regexall(local.kv_pattern, tostring(local.raw_cidrs)) : m[0] => m[1]
  }), null)

  vpc_ids   = coalesce(local.ids_as_map, local.ids_from_json, local.ids_from_regex, tomap({}))
  vpc_cidrs = coalesce(local.cidrs_as_map, local.cidrs_from_json, local.cidrs_from_regex, tomap({}))

  vpc_id   = try(local.vpc_ids[var.app_key], null)
  vpc_cidr = try(local.vpc_cidrs[var.app_key], null)
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
        "Could not resolve key '${var.app_key}' from '${var.vpc_ids_output_name}' / '${var.vpc_cidrs_output_name}' ",
        "in workspace '${var.shared_workspace_id}'. ",
        length(local.shared_outputs) == 0
        ? "The API returned no outputs at all -- has the producer applied yet?"
        : "Outputs present: ${join(", ", sort(keys(local.shared_outputs)))}. ",
        local.raw_ids == null
        ? ""
        : "Parsed keys from ${var.vpc_ids_output_name}: [${join(", ", sort(keys(local.vpc_ids)))}]. Raw value was: ${jsonencode(local.raw_ids)}",
      ])
    }
  }
}

###############################################################################
# Assertions and diagnostics
###############################################################################

output "resolved_vpc_id" {
  description = "Proof the API read and the decode both worked. Renders at plan time."
  value       = local.vpc_id
}

output "resolved_vpc_cidr" {
  description = "CIDR pulled out of the producer's vpc_cidrs map."
  value       = local.vpc_cidr
}

output "parsed_vpc_ids" {
  description = "The whole decoded map. Check this first if a key lookup fails."
  value       = local.vpc_ids
}

output "raw_vpc_ids_value" {
  description = "Exactly what the API returned for vpc_ids, before decoding. Paste this if the parsers miss."
  value       = jsonencode(local.raw_ids)
}

output "available_output_names" {
  description = "Non-sensitive output names the API exposed."
  value       = sort(keys(local.shared_outputs))
}

output "subnet_id" {
  description = "Subnet built inside the shared VPC."
  value       = aws_subnet.app.id
}
