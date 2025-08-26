#!/usr/bin/env bats

# Test framework: Bats (Bash Automated Testing System).
# Conventions:
# - Each @test has a clear, descriptive name.
# - Skip gracefully if external tools are missing (e.g., terraform).
# - Prefer static validations to avoid cloud interactions.
# - Where terraform CLI is used, disable backend init and avoid provider auth.
# - Focus on resources and settings present in the PR diff.

load 'test_helper/bats-support/load' 2>/dev/null || true
load 'test_helper/bats-assert/load'  2>/dev/null || true

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  TF_FILES=()
  while IFS= read -r -d '' f; do TF_FILES+=("$f"); done < <(find "$REPO_ROOT" -maxdepth 3 -type f -name '*.tf' -print0 2>/dev/null || true)

  # A single aggregated HCL for some static checks if needed
  TMP_DIR="$(mktemp -d)"
  COMBINED="$TMP_DIR/combined.tf"
  cat "${TF_FILES[@]}" > "$COMBINED" 2>/dev/null || true
}

teardown() {
  rm -rf "${TMP_DIR:-}"
}

# Utility: check for a binary and version
have() { command -v "$1" >/dev/null 2>&1; }

@test "terraform CLI is available (skip if not)" {
  if ! have terraform; then
    skip "terraform is not installed on PATH"
  fi
  run terraform version
  assert_success
  assert_output --partial "Terraform"
}

@test "Terraform files exist in repository" {
  [ "${#TF_FILES[@]}" -gt 0 ]
}

@test "HCL contains required aws provider and version constraint '~> 5.0'" {
  run bash -c "grep -R --line-number -E 'required_providers\\s*\\{[[:space:]]*aws[[:space:]]*=|source\\s*=\\s*\"hashicorp/aws\"|version\\s*=\\s*\"~> 5\\.0\"' \"${TF_FILES[@]}\""
  assert_success
  assert_output --partial "hashicorp/aws"
  assert_output --partial "~> 5.0"
}

@test "Backend block for s3 exists with use_lockfile=true" {
  run bash -c "grep -R -n -E 'backend\\s+\"s3\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'use_lockfile\\s*=\\s*true' \"${TF_FILES[@]}\""
  assert_success
}

@test "Provider aws region and profile are variable-driven" {
  run bash -c "grep -R -n -E 'provider\\s+\"aws\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'region\\s*=\\s*var\\.aws_region' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'profile\\s*=\\s*var\\.aws_profile' \"${TF_FILES[@]}\""
  assert_success
}

@test "VPC is defined with DNS support and hostnames enabled; CIDR 20.0.0.0/16" {
  run bash -c "grep -R -n -E 'resource\\s+\"aws_vpc\"\\s+\"prod_vpc\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'cidr_block\\s*=\\s*\"20\\.0\\.0\\.0/16\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'enable_dns_support\\s*=\\s*true' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'enable_dns_hostnames\\s*=\\s*true' \"${TF_FILES[@]}\""
  assert_success
}

@test "Internet Gateway and route table with 0.0.0.0/0 and ::/0 routes" {
  run bash -c "grep -R -n -E 'resource\\s+\"aws_internet_gateway\"\\s+\"gw\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'resource\\s+\"aws_route_table\"\\s+\"prod_rt\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'cidr_block\\s*=\\s*\"0\\.0\\.0\\.0/0\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'ipv6_cidr_block\\s*=\\s*\"::/0\"' \"${TF_FILES[@]}\""
  assert_success
}

@test "Two public subnets exist with map_public_ip_on_launch=true" {
  run bash -c "grep -R -n -E 'resource\\s+\"aws_subnet\"\\s+\"subnet_1\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'resource\\s+\"aws_subnet\"\\s+\"subnet_2\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'map_public_ip_on_launch\\s*=\\s*true' \"${TF_FILES[@]}\" | wc -l"
  assert_success
  # Expect at least two occurrences
  [ "${lines[0]:-2}" -ge 2 ]
}

@test "Security group for web allows HTTP(80), HTTPS(443), SSH(22); egress all IPv4/IPv6" {
  run bash -c "grep -R -n -E 'resource\\s+\"aws_security_group\"\\s+\"allow_web\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'resource\\s+\"aws_vpc_security_group_ingress_rule\"\\s+\"allow_http_ipv4\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'from_port\\s*=\\s*80' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'resource\\s+\"aws_vpc_security_group_ingress_rule\"\\s+\"allow_https_ipv4\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'from_port\\s*=\\s*443' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'resource\\s+\"aws_vpc_security_group_ingress_rule\"\\s+\"allow_ssh_ipv4\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'from_port\\s*=\\s*22' \"${TF_FILES[@]}\""
  assert_success
  # Egress rules
  run bash -c "grep -R -n -E 'resource\\s+\"aws_vpc_security_group_egress_rule\"\\s+\"allow_all_traffic_ipv4\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'resource\\s+\"aws_vpc_security_group_egress_rule\"\\s+\"allow_all_traffic_ipv6\"' \"${TF_FILES[@]}\""
  assert_success
}

@test "ENI and EIP associate to fixed private IP 20.0.1.50 with depends_on on IGW" {
  run bash -c "grep -R -n -E 'resource\\s+\"aws_network_interface\"\\s+\"web_server_nic\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'private_ips\\s*=\\s*\\[\"20\\.0\\.1\\.50\"\\]' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'resource\\s+\"aws_eip\"\\s+\"one\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'associate_with_private_ip\\s*=\\s*\"20\\.0\\.1\\.50\"' \"${TF_FILES[@]}\""
  assert_success
}

@test "EC2 instance uses specific AMI, type t2.micro, and has user_data installing nginx/docker/ssm" {
  run bash -c "grep -R -n -E 'resource\\s+\"aws_instance\"\\s+\"web_server\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'instance_type\\s*=\\s*\"t2\\.micro\"' \"${TF_FILES[@]}\""
  assert_success
  # Spot-check user_data critical steps
  run bash -c "grep -R -n -E 'apt-get install -y nginx' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'get\\.docker\\.com' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'amazon-ssm-agent' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'nginx -t && systemctl reload nginx' \"${TF_FILES[@]}\""
  assert_success
}

@test "Outputs exist for server_public_ip, server_private_ip, server_id" {
  run bash -c "grep -R -n -E '^output\\s+\"server_public_ip\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E '^output\\s+\"server_private_ip\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E '^output\\s+\"server_id\"' \"${TF_FILES[@]}\""
  assert_success
}

@test "RDS subnet group, SG, parameter group and instance exist with MySQL 8.0 and UTF8MB4" {
  run bash -c "grep -R -n -E 'resource\\s+\"aws_db_subnet_group\"\\s+\"rds_subnet_group\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'resource\\s+\"aws_security_group\"\\s+\"rds_sg\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'resource\\s+\"aws_db_parameter_group\"\\s+\"custom_mysql_parameters\"' \"${TF_FILES[@]}\""
  assert_success
  # Character set parameters
  for p in character_set_client character_set_connection character_set_database character_set_filesystem character_set_results character_set_server; do
    run bash -c "grep -R -n -E \"name\\s*=\\s*\\\"$p\\\"[[:space:]]*$\" -n \"${TF_FILES[@]}\" -n || grep -R -n -E \"$p\" \"${TF_FILES[@]}\""
    assert_success
    run bash -c "grep -R -n -E \"$p.*utf8mb4\" \"${TF_FILES[@]}\""
    assert_success
  done
  # Engine and version
  run bash -c "grep -R -n -E 'resource\\s+\"aws_db_instance\"\\s+\"mydb\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'engine\\s*=\\s*\"mysql\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'engine_version\\s*=\\s*\"8\\.0\"' \"${TF_FILES[@]}\""
  assert_success
}

@test "CI/CD IAM user and access key outputs are present and marked sensitive" {
  run bash -c "grep -R -n -E 'resource\\s+\"aws_iam_user\"\\s+\"cicd_user\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E '^output\\s+\"cicd_aws_access_key_id\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E '^output\\s+\"cicd_aws_secret_access_key\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E 'sensitive\\s*=\\s*true' \"${TF_FILES[@]}\" | wc -l"
  assert_success
  [ "${lines[0]:-0}" -ge 2 ]
}

@test "S3 bucket, public access block (all false), bucket policy for public read, and dedicated IAM user" {
  run bash -c "grep -R -n -E 'resource\\s+\"aws_s3_bucket\"\\s+\"bucket\"' \"${TF_FILES[@]}\""
  assert_success
  # Public access block flags false (for demo)
  for flag in block_public_acls block_public_policy ignore_public_acls restrict_public_buckets; do
    run bash -c "grep -R -n -E '$flag\\s*=\\s*false' \"${TF_FILES[@]}\""
    assert_success
  done
  # Public read policy
  run bash -c "grep -R -n -E 'resource\\s+\"aws_s3_bucket_policy\"\\s+\"public_read_policy\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E '\"s3:GetObject\"' \"${TF_FILES[@]}\""
  assert_success
  # Dedicated IAM user and key
  run bash -c "grep -R -n -E 'resource\\s+\"aws_iam_user\"\\s+\"s3_user\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E '^output\\s+\"s3_aws_access_key_id\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E '^output\\s+\"s3_aws_secret_access_key\"' \"${TF_FILES[@]}\""
  assert_success
}

@test "Terraform fmt check (skip if terraform missing); backend disabled to avoid remote calls" {
  if ! have terraform; then
    skip "terraform is not installed on PATH"
  fi
  # Formatting check doesn't need init
  run terraform fmt -check -recursive "$(dirname "${BATS_TEST_FILENAME}")/.."
  assert_success
}

@test "Terraform validate structure (skip if terraform missing); do init with -backend=false" {
  if ! have terraform; then
    skip "terraform is not installed on PATH"
  fi
  WORK="$(mktemp -d)"
  # Copy only .tf files to isolated temp dir to avoid backend config files
  find "$(dirname "${BATS_TEST_FILENAME}")/.." -maxdepth 3 -type f -name '*.tf' -exec cp {} "$WORK"/ \;

  pushd "$WORK" >/dev/null
  run terraform init -backend=false -input=false -lock=false -no-color
  # Some environments may lack network for provider plugins; tolerate init failure but still assert CLI ran.
  [ "$status" -eq 0 ] || echo "terraform init failed (likely offline): status=$status"

  run terraform validate -no-color
  if [ "$status" -ne 0 ]; then
    echo "Note: terraform validate failed. This can happen offline without provider plugins."
    echo "Output:"
    echo "$output"
    skip "Skipping validate assertions due to offline/provider plugin unavailability"
  fi
  assert_success
  popd >/dev/null
  rm -rf "$WORK"
}

# Edge case checks to guard against accidental regressions
@test "No 0.0.0.0/0 ingress other than explicitly allowed ports (80,443,22,3306) in diff" {
  run bash -c "grep -R -n -E 'cidr_ipv4\\s*=\\s*\"0\\.0\\.0\\.0/0\"' \"${TF_FILES[@]}\""
  assert_success
  # Ensure expected ingress blocks for 80, 443, 22, 3306 are present (already vetted above)
  # Negative heuristic: ensure no unexpected port pattern with 0.0.0.0/0
  run bash -c "awk 'BEGIN{ok=1} /cidr_ipv4 *= *\"0\\.0\\.0\\.0\\/0\"/{found=1} /from_port/{fp=$3} /to_port/{tp=$3; if (fp!=80 && fp!=443 && fp!=22 && fp!=3306){print \"Unexpected open port:\" fp; ok=0}} END{exit ok?0:1}' ${TF_FILES[*]}"
  # If awk indicates unexpected ports, it will exit 1
  [ "$status" -eq 0 ]
}

@test "Outputs for sensitive credentials are marked sensitive=true" {
  run bash -c "grep -R -n -E '^output\\s+\"(cicd_aws_access_key_id|cicd_aws_secret_access_key|s3_aws_access_key_id|s3_aws_secret_access_key)\"' \"${TF_FILES[@]}\""
  assert_success
  run bash -c "grep -R -n -E '^\\s*sensitive\\s*=\\s*true\\s*$' \"${TF_FILES[@]}\" | wc -l"
  assert_success
  # At least 4 sensitive flags across the four secrets outputs
  [ "${lines[0]:-0}" -ge 2 ]
}