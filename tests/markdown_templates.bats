#!/usr/bin/env bats

# Helper to resolve renderer command under test.
# You can override with TEMPLATE_RENDER_CMD env var in CI if the binary/script name differs.
resolve_renderer() {
  if [[ -n "${TEMPLATE_RENDER_CMD:-}" ]]; then
    echo "$TEMPLATE_RENDER_CMD"; return 0;
  fi;
  # Common candidates; adjust as needed to match project script names.
  for c in "scripts/render_markdown.sh" "bin/render-markdown" "render-markdown" "scripts/template_render.sh"; do
    if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi;
    if [[ -x "$c" ]]; then echo "./$c"; return 0; fi;
  done;
  # Fallback to envsubst (covers simple ${VAR} substitution); acceptable baseline.
  if command -v envsubst >/dev/null 2>&1; then echo "envsubst"; return 0; fi;
  echo "envsubst";
}


# Optionally load helpers if the repo has them; kept optional to avoid failing if absent.
# load 'test_helper'
# load 'helpers'

setup() {
  TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "Markdown template rendering - basic happy path" {
  renderer="$(resolve_renderer)"
  export NAME="Alice"
  export PRODUCT="Nebula"
  export PLAN="Pro"
  export REGION="us-west-2"

  if [[ "$renderer" == "envsubst" ]]; then
    run bash -c 'envsubst < tests/fixtures/markdown_templates/basic.md'
  else
    run bash -c '"$renderer"' tests/fixtures/markdown_templates/basic.md'
  fi

  [ "$status" -eq 0 ]
  [[ "$output" == *"# Hello, Alice!"* ]]
  [[ "$output" == *"Welcome to Nebula."* ]]
  [[ "$output" == *"- Plan: Pro"* ]]
  [[ "$output" == *"- Region: us-west-2"* ]]
}

@test "Handles missing placeholders: fails or leaves tokens depending on implementation" {
  renderer="$(resolve_renderer)"
  unset OWNER EMAIL SUBSCRIPTION || true

  if [[ "$renderer" == "envsubst" ]]; then
    # envsubst leaves blanks for unset vars by default
    run bash -c 'envsubst < tests/fixtures/markdown_templates/missing_placeholders.md'
    [ "$status" -eq 0 ]
    # Expect empty values for missing vars
    [[ "$output" == *"Owner: "* ]]
    [[ "$output" == *"Email: "* ]]
    [[ "$output" == *"Subscription: "* ]]
  else
    run bash -c '"$renderer"' tests/fixtures/markdown_templates/missing_placeholders.md'
    # We accept either a non-zero status (strict renderer) or zero with tokens preserved; assert at least non-empty output.
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
    [ -n "$output" ]
  fi
}

@test "Escaped dollar signs are preserved; variable after escaped dollar still expands" {
  renderer="$(resolve_renderer)"
  export PRICE="19.99"
  export NOT_A_VAR="SHOULD_NOT_APPEAR"

  if [[ "$renderer" == "envsubst" ]]; then
    run bash -c 'envsubst < tests/fixtures/markdown_templates/escaped_dollars.md'
  else
    run bash -c '"$renderer"' tests/fixtures/markdown_templates/escaped_dollars.md'
  fi

  [ "$status" -eq 0 ]
  # The first \$ should render as a literal $, followed by expanded PRICE
  [[ "$output" == *"The cost is $19.99 per month."* ]]
  # Literal \$${NOT_A_VAR} should keep the token or render as $ (no expansion to its value)
  [[ "$output" == *"Literal $"* ]]
  [[ "$output" != *"SHOULD_NOT_APPEAR"* ]]
}

@test "Curly-brace style of other template engines is not treated as variables" {
  renderer="$(resolve_renderer)"
  export REAL_VAR="42"

  if [[ "$renderer" == "envsubst" ]]; then
    run bash -c 'envsubst < tests/fixtures/markdown_templates/nested_curly_like.md'
  else
    run bash -c '"$renderer"' tests/fixtures/markdown_templates/nested_curly_like.md'
  fi

  [ "$status" -eq 0 ]
  # Must not interpolate {{NOT_VAR}}
  [[ "$output" == *"{{NOT_VAR}}"* ]]
  # But should interpolate REAL_VAR in ${REAL_VAR} line
  [[ "$output" == *$'42'* ]]
}

@test "Repeated placeholders expand consistently across the document" {
  renderer="$(resolve_renderer)"
  export APP="api-gateway"
  export OWNER="platform-team"

  if [[ "$renderer" == "envsubst" ]]; then
    run bash -c 'envsubst < tests/fixtures/markdown_templates/repeated_placeholders.md'
  else
    run bash -c '"$renderer"' tests/fixtures/markdown_templates/repeated_placeholders.md'
  fi

  [ "$status" -eq 0 ]
  # APP appears three times
  occurrences="$(printf "%s" "$output" | rg -n "api-gateway" | wc -l | tr -d ' ')"
  [ "$occurrences" -ge 3 ]
  [[ "$output" == *"Owner: platform-team"* ]]
}

@test "Defaults for unset variables are applied when using ${VAR:-default} syntax" {
  renderer="$(resolve_renderer)"
  unset USER ENVIRONMENT PORT || true

  if [[ "$renderer" == "envsubst" ]]; then
    run bash -c 'envsubst < tests/fixtures/markdown_templates/unset_with_default.md'
  else
    run bash -c '"$renderer"' tests/fixtures/markdown_templates/unset_with_default.md'
  fi

  [ "$status" -eq 0 ]
  [[ "$output" == *"User: guest"* ]]
  [[ "$output" == *"Env: dev"* ]]
  [[ "$output" == *"Port: 8080"* ]]
}

@test "Renderer returns non-zero or informative output on nonexistent file" {
  renderer="$(resolve_renderer)"

  if [[ "$renderer" == "envsubst" ]]; then
    # envsubst will fail when input file is missing if we attempt to redirect from it
    run bash -c 'envsubst < tests/fixtures/markdown_templates/does_not_exist.md'
    [ "$status" -ne 0 ]
  else
    run bash -c '"$renderer"' tests/fixtures/markdown_templates/does_not_exist.md'
    [ "$status" -ne 0 ]
  fi
}

@test "Whitespace and newline preservation" {
  renderer="$(resolve_renderer)"
  tmp="$TMPDIR/ws.md"
  cat > "$tmp" <<'MD'
Title

Paragraph with trailing spaces.   
Next line should remain separate.

${VAR}
MD

  export VAR="value"
  if [[ "$renderer" == "envsubst" ]]; then
    run bash -c 'envsubst < "'"$tmp"'"'
  else
    run bash -c '"$renderer"' "'"$tmp"'"'
  fi

  [ "$status" -eq 0 ]
  # Ensure the blank lines and trailing spaces do not collapse entirely
  lines="$(printf "%s" "$output" | wc -l | tr -d ' ')"
  [ "$lines" -ge 6 ]
  [[ "$output" == *$'value'* ]]
}