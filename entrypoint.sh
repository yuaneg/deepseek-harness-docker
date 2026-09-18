#!/bin/sh
set -e

DSH_PORT="${DSH_PORT:-3079}"
PROXY_PORT="${PROXY_PORT:-3080}"

# ── 1. 启动 DSH ──
cd /dsh-src
pnpm dsh web -- --port "$DSH_PORT" > /tmp/dsh-web.log 2>&1 &
DSH_PID=$!

# ── 2. 等待就绪 + 抓 token ──
echo "[dsh] 等待 DSH 就绪 (127.0.0.1:$DSH_PORT) ..."
TOKEN=""
for i in $(seq 1 120); do
  TOKEN=$(sed -n 's/.*token=\([A-Za-z0-9._~-]\{16,\}\).*/\1/p' /tmp/dsh-web.log 2>/dev/null | tail -1)
  if node -e "fetch('http://127.0.0.1:$DSH_PORT/').then(()=>process.exit(0)).catch(()=>process.exit(1))" 2>/dev/null; then
    echo "[dsh] DSH 就绪 (pid $DSH_PID)"
    break
  fi
  if ! kill -0 "$DSH_PID" 2>/dev/null; then
    echo "[dsh] 错误：DSH 进程已退出"
    cat /tmp/dsh-web.log
    exit 1
  fi
  sleep 1
done

# ── 3. Token 交换 → 获取 auth cookie ──
AUTH_COOKIE=""
if [ -n "$TOKEN" ]; then
  echo "[auth] 使用 token 换取会话 cookie..."
  AUTH_COOKIE=$(node -e "
    (async () => {
      const res = await fetch('http://127.0.0.1:$DSH_PORT/?token=$TOKEN', { redirect: 'manual' });
      const cookies = res.headers.getSetCookie ? res.headers.getSetCookie() : [];
      if (cookies.length) {
        const parts = cookies.map(c => c.split(';')[0]).join('; ');
        console.log(parts);
      }
    })();
  " 2>/dev/null)

  if [ -n "$AUTH_COOKIE" ]; then
    echo "[auth] cookie 已获取"
  else
    echo "[auth] cookie 获取失败"
  fi
else
  echo "[auth] 未捕获到 token"
fi

# ── 4. 生成 nginx 配置 ──
COOKIE_LINE=""
if [ -n "$AUTH_COOKIE" ]; then
  COOKIE_LINE="proxy_set_header Cookie \"$AUTH_COOKIE\";"
fi

cat > /etc/nginx/nginx.conf << NGINX_EOF
worker_processes auto;
events { worker_connections 1024; }
http {
    server {
        listen $PROXY_PORT;
        location / {
            proxy_pass http://127.0.0.1:$DSH_PORT;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host 127.0.0.1:$DSH_PORT;
            proxy_set_header Origin http://127.0.0.1:$DSH_PORT;
            $COOKIE_LINE
        }
    }
}
NGINX_EOF

echo "[nginx] 配置已生成"

# ── 5. 清理 + 启动 nginx ──
cleanup() { kill "$DSH_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo "[nginx] 启动：0.0.0.0:$PROXY_PORT → 127.0.0.1:$DSH_PORT"
nginx -g 'daemon off;'
