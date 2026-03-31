#==============================================================================
# RERC MANAGEMENT MODULE OUTPUTS
#==============================================================================

output "local_rerc_created" {
  description = "Whether the local RERC was created"
  value       = var.create_local_rerc
}

output "remote_rerc_created" {
  description = "Whether the remote RERC was created"
  value       = var.create_remote_rerc
}

output "rercs_ready" {
  description = "Dependency output to ensure RERCs are ready"
  value       = var.create_local_rerc || var.create_remote_rerc ? time_sleep.wait_for_rercs[0].id : null
}

