# tflint configuration — referenced by the terraform_tflint pre-commit hook.
# Previously the hook pointed at devsecops/.tflint.hcl, a path that never
# existed in this repository, so the hook failed to start.

config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "azurerm" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

plugin "google" {
  enabled = true
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}

# ── Naming / hygiene ─────────────────────────────────────────────────────────
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

# Modules are pinned by the required_providers block and remote module sources.
rule "terraform_module_pinned_source" {
  enabled = true
  style   = "semver"
}
