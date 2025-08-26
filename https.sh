# 1) Nginx 서버블록(HTTP) 작성
# 발급한 도메인으로 변경 필요
sudo bash -c 'cat >/etc/nginx/sites-available/default' <<'NGINX'
server {
  listen 80;
  listen [::]:80;
  server_name onit-api.store www.onit-api.store;

  location / {
    proxy_pass http://localhost:8080;

    # 기본 프록시 헤더
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # WebSocket 대비(있어도 무해)
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
  }
}
NGINX

sudo nginx -t && sudo systemctl reload nginx

# 2) certbot 설치
sudo snap install core; sudo snap refresh core
sudo snap install --classic certbot
sudo ln -sf /snap/bin/certbot /usr/bin/certbot

# 3) 인증서 발급 + Nginx 자동 HTTPS 설정/리다이렉트 
# 발급한 도메인으로 변경 필요
sudo certbot --nginx -d onit-api.store -d www.onit-api.store

# 4) Nginx 설정 검증/리로드(발급 과정에서 이미 처리되지만 한 번 더 확인)
sudo nginx -t && sudo systemctl reload nginx

# 5) 자동 갱신 확인
systemctl list-timers | grep certbot

# 6) 갱신 드라이런
sudo certbot renew --dry-run