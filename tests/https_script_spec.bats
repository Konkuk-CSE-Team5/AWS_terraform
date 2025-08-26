#!/usr/bin/env bats

# Testing library/framework: Bats-Core (Bash Automated Testing System).
# These tests statically validate the contents of tests/https_script.bats,
# focusing on the Nginx config here-doc and command sequence, without running
# any system-modifying commands or requiring root privileges.

setup() {
  SCRIPT="tests/https_script.bats"
}

extract_nginx_conf() {
  awk '
    $0 ~ /<<'\''NGINX'\''/ {in=1; next}
    in && $0=="NGINX" {in=0; exit}
    in {print}
  ' "$SCRIPT"
}

@test "shebang and strict mode present" {
  run head -n 2 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "#!/usr/bin/env bash" ]
  [ "${lines[1]}" = "set -euo pipefail" ]
}

@test "heredoc delimiter is single-quoted to prevent variable expansion" {
  run grep -nF "<<'NGINX'" "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "nginx server block contains expected directives" {
  conf="$(extract_nginx_conf)"
  [ -n "$conf" ]

  printf %s "$conf" | grep -Fq 'server {'
  printf %s "$conf" | grep -Fq 'listen 80;'
  printf %s "$conf" | grep -Fq 'listen [::]:80;'
  printf %s "$conf" | grep -Fq 'server_name onit-api.store www.onit-api.store;'
  printf %s "$conf" | grep -Fq 'location / {'
  printf %s "$conf" | grep -Fq 'proxy_pass http://localhost:8080;'
}

@test "nginx proxy headers include standard and websocket-related headers" {
  conf="$(extract_nginx_conf)"
  [ -n "$conf" ]

  printf %s "$conf" | grep -Fq 'proxy_set_header Host $host;'
  printf %s "$conf" | grep -Fq 'proxy_set_header X-Real-IP $remote_addr;'
  printf %s "$conf" | grep -Fq 'proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
  printf %s "$conf" | grep -Fq 'proxy_set_header X-Forwarded-Proto $scheme;'
  printf %s "$conf" | grep -Fq 'proxy_set_header Upgrade $http_upgrade;'
  printf %s "$conf" | grep -Fq 'proxy_set_header Connection "upgrade";'
}

@test "commands appear in a logical and safe order" {
  end_heredoc="$(grep -nE '^NGINX$' "$SCRIPT" | head -n1 | cut -d: -f1)"
  [ -n "$end_heredoc" ]

  first_reload="$(grep -nF 'sudo nginx -t && sudo systemctl reload nginx' "$SCRIPT" | head -n1 | cut -d: -f1)"
  snap_install="$(grep -nF 'sudo snap install core; sudo snap refresh core' "$SCRIPT" | head -n1 | cut -d: -f1)"
  certbot_install="$(grep -nF 'sudo snap install --classic certbot' "$SCRIPT" | head -n1 | cut -d: -f1)"
  symlink_line="$(grep -nF 'sudo ln -sf /snap/bin/certbot /usr/bin/certbot' "$SCRIPT" | head -n1 | cut -d: -f1)"
  issue_cert="$(grep -nF 'sudo certbot --nginx -d onit-api.store -d www.onit-api.store' "$SCRIPT" | head -n1 | cut -d: -f1)"
  second_reload="$(grep -nF 'sudo nginx -t && sudo systemctl reload nginx' "$SCRIPT" | tail -n1 | cut -d: -f1)"
  list_timers="$(grep -nF 'systemctl list-timers | grep certbot' "$SCRIPT" | head -n1 | cut -d: -f1)"
  dry_run="$(grep -nF 'sudo certbot renew --dry-run' "$SCRIPT" | head -n1 | cut -d: -f1)"

  [ "$first_reload" -gt "$end_heredoc" ]
  [ "$snap_install" -gt "$first_reload" ]
  [ "$certbot_install" -gt "$snap_install" ]
  [ "$symlink_line" -gt "$certbot_install" ]
  [ "$issue_cert" -gt "$symlink_line" ]
  [ "$second_reload" -gt "$issue_cert" ]
  [ "$list_timers" -gt "$second_reload" ]
  [ "$dry_run" -gt "$list_timers" ]
}

@test "script includes a commented ERR trap with line number reference" {
  run grep -nE '^\s*#\s*trap .*ERR' "$SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq '$LINENO'
}

@test "no trailing whitespace on non-empty lines within the server block" {
  conf="$(extract_nginx_conf)"
  [ -n "$conf" ]

  in_server=0
  while IFS= read -r line; do
    if [[ "$line" == *"server {"* ]]; then
      in_server=1
      continue
    fi
    # This simplistic check stops at the first closing brace after 'server {'
    if [[ $in_server -eq 1 && "$line" == "}" ]]; then
      break
    fi
    if [[ $in_server -eq 1 && -n "$line" ]]; then
      [[ ! "$line" =~ [[:space:]]$ ]]
    fi
  done <<< "$conf"
}

@test "certbot uses nginx plugin with both apex and www domains" {
  run grep -nF 'sudo certbot --nginx -d onit-api.store -d www.onit-api.store' "$SCRIPT"
  [ "$status" -eq 0 ]
}