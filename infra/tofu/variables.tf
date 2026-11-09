variable "state_passphrase" {
  description = "Encrypts OpenTofu's state and plans. tofu/TOFU_STATE_PASSPHRASE in Bitwarden."
  type        = string
  sensitive   = true
}
