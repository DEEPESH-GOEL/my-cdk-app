terraform {
  required_version = ">= 1.5"
 
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    harness = {
      source  = "harness/harness"
      version = "~> 0.45"
    }
  }
}
 
provider "aws" {
  region = var.aws_region
}

removed {
  from = data.http.shared_workspace
  lifecycle {
    destroy = false
  }
}
# Intentionally empty. See the header.
provider "harness" {}
 
###############################################################################
# Variables
#
# Note what is absent: no token, no account id, no endpoint. Only the coordinates
# of the workspace being read, which are not secret.
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
 
###############################################################################
# The read
#
# Confirmed against the provider docs: `harness_platform_workspace_output`
# takes identifier / org_id / project_id and returns `outputs`, a list of
# {name, sensitive, value} objects where `value` is ALWAYS a string, even when
# the producer's Terraform output was a map. That confirms the decode section
# below is targeting real behavior, not a hypothetical.
#
# org_id and project_id are required arguments today. If Harness later defaults
# them to the executing workspace's own scope, both lines can be dropped for the
# same-project case.
###############################################################################
 
data "harness_platform_workspace_output" "shared" {
  identifier = var.shared_workspace_id
  org_id     = var.harness_org_id
  project_id = var.harness_project_id
}
 
# CAVEAT that Path B does not remove.
#
# The provider records this data source's full result in THIS workspace's state,
# including the entire `outputs` list. The `sensitive` filter below therefore
# controls what gets USED, not what gets STORED, since locals are evaluated
# after the provider has already written its result.
#
# Keep the producer's outputs limited to non-secret coordinates: ids, ARNs,
# CIDRs. Note also that the data source projects outputs client-side out of the
# workspace resources response, so the narrowing is in the interface rather than
# on the wire.
 
###############################################################################
# Decode
#
# `outputs` is a LIST of {name, sensitive, value}, folded here into a
# name -> value map. `value` is confirmed typed as string even when the
# producer's output was a map, so map outputs need decoding.
#
# Since `value` can never actually arrive as a native map (confirmed from the
# provider docs), the old "attempt 1: already a real map" branch was dead code
# and has been dropped. Two attempts remain, in order of how the producer is
# likely to have emitted the value:
###############################################################################
 
locals {
  shared_outputs = {
    for o in data.harness_platform_workspace_output.shared.outputs : o.name => o.value
    if try(o.sensitive, false) == false
  }
 
  raw_ids   = try(local.shared_outputs[var.vpc_ids_output_name], null)
  raw_cidrs = try(local.shared_outputs[var.vpc_cidrs_output_name], null)
 
  # 1. A JSON object encoded as a string. This is the expected shape if the
  #    producer wrote `output "vpc_ids" { value = jsonencode(local.vpc_ids) }`,
  #    or if Harness itself serializes map outputs to JSON (recommended: check
  #    the producer's raw_vpc_ids_value output to confirm the exact shape once,
  #    then this is normally the only branch you need).
  ids_from_json   = try(tomap({ for k, v in jsondecode(local.raw_ids) : k => tostring(v) }), null)
  cidrs_from_json = try(tomap({ for k, v in jsondecode(local.raw_cidrs) : k => tostring(v) }), null)
 
  # 2. Fallback for any other key/value rendering: HCL `=`, Go map[k:v],
  #    quoted or bare. Kept defensively; try() is required because locals
  #    evaluate eagerly and a failed parse must not abort the plan.
  kv_pattern = "\"?([A-Za-z0-9_.-]+)\"?[[:space:]]*[:=][[:space:]]*\"?([^\",}\\][:space:]]+)\"?"
 
  ids_from_regex = try(tomap({
    for m in regexall(local.kv_pattern, tostring(local.raw_ids)) : m[0] => m[1]
  }), null)
  cidrs_from_regex = try(tomap({
    for m in regexall(local.kv_pattern, tostring(local.raw_cidrs)) : m[0] => m[1]
  }), null)
 
  # 3. Give up to an empty map, which the precondition below reports on.
  vpc_ids   = coalesce(local.ids_from_json, local.ids_from_regex, tomap({}))
  vpc_cidrs = coalesce(local.cidrs_from_json, local.cidrs_from_regex, tomap({}))
 
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
    ReadVia   = "harness-provider"
  }
 
  lifecycle {
    precondition {
      condition = local.vpc_id != null && local.vpc_cidr != null
      error_message = join("", [
        "Could not resolve key '${var.app_key}' from '${var.vpc_ids_output_name}' / '${var.vpc_cidrs_output_name}' ",
        "in workspace '${var.shared_workspace_id}'. ",
        length(local.shared_outputs) == 0
        ? "The data source returned no outputs. Either the producer has not applied yet, or HARNESS_PLATFORM_API_KEY is missing or lacks access."
        : "Outputs present: ${join(", ", sort(keys(local.shared_outputs)))}. ",
        local.raw_ids == null
        ? ""
        : "Parsed keys: [${join(", ", sort(keys(local.vpc_ids)))}]. Raw value: ${jsonencode(local.raw_ids)}",
      ])
    }
  }
}
 
###############################################################################
# Assertions and diagnostics
###############################################################################
 
output "resolved_vpc_id" {
  description = "Proof the read and the decode both worked. Renders at plan time."
  value       = local.vpc_id
}
 
output "resolved_vpc_cidr" {
  description = "CIDR pulled from the producer's vpc_cidrs map."
  value       = local.vpc_cidr
}
 
output "parsed_vpc_ids" {
  description = "The whole decoded map. Check this first when a key lookup fails."
  value       = local.vpc_ids
}
 
output "raw_vpc_ids_value" {
  description = "What the data source returned for vpc_ids, before decoding."
  value       = jsonencode(local.raw_ids)
}
 
output "available_output_names" {
  description = "Non-sensitive output names the data source exposed."
  value       = sort(keys(local.shared_outputs))
}
 
output "subnet_id" {
  description = "Subnet built inside the shared VPC."
  value       = aws_subnet.app.id
}
