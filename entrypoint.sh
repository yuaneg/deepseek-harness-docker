#!/bin/sh
set -e

DSH_PORT="${DSH_PORT:-3079}"
PROXY_PORT="${PROXY_PORT:-3080}"

# 计时工具（秒级）
START_TIME=$(date +%s)
prev_time=$START_TIME
log_time() {
  NOW=$(date +%s)
  TOTAL=$((NOW - START_TIME))
  DELTA=$((NOW - prev_time))
  prev_time=$NOW
  echo "[timing] +${DELTA}s (total ${TOTAL}s) - $1"
}

log_time "===== entrypoint 开始 ====="

# ── 1. 启动 DSH ──
cd /dsh-src
log_time "进入 /dsh-src"

node apps/cli/lib/bin.js web --port "$DSH_PORT" > /tmp/dsh-web.log 2>&1 &
DSH_PID=$!
log_time "DSH (预编译) 后台启动 (pid $DSH_PID)"

# ── 2. 等待就绪 + 抓 token ──
echo "[dsh] 等待 DSH 就绪 (127.0.0.1:$DSH_PORT) ..."
TOKEN=""
DSH_READY=0
CHECK_COUNT=0
for i in $(seq 1 120); do
  CHECK_COUNT=$((CHECK_COUNT + 1))

  # 尝试从日志捕获 token
  if [ -z "$TOKEN" ]; then
    TOKEN=$(sed -n 's/.*token=\([A-Za-z0-9._~-]\{16,\}\).*/\1/p' /tmp/dsh-web.log 2>/dev/null | tail -1)
    if [ -n "$TOKEN" ]; then
      log_time "✓ token 已捕获 (第 ${CHECK_COUNT} 次循环)"
    fi
  fi

  # 检查 HTTP 是否就绪
  if [ "$DSH_READY" -eq 0 ]; then
    if node -e "fetch('http://127.0.0.1:$DSH_PORT/').then(()=>process.exit(0)).catch(()=>process.exit(1))" 2>/dev/null; then
      log_time "✓ DSH HTTP 就绪 (第 ${CHECK_COUNT} 次循环)"
      echo "[dsh] DSH 就绪 (pid $DSH_PID)"
      DSH_READY=1
    fi
  fi

  # HTTP 就绪且 token 已捕获，退出循环
  if [ "$DSH_READY" -eq 1 ] && [ -n "$TOKEN" ]; then
    log_time "✓ 等待循环结束 (共 ${CHECK_COUNT} 次循环)"
    break
  fi

  # 如果 HTTP 还没就绪，检查进程是否还活着
  if [ "$DSH_READY" -eq 0 ] && ! kill -0 "$DSH_PID" 2>/dev/null; then
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
  log_time "开始 token 交换 (启动 node -e)"
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
  log_time "✓ token 交换完成"

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

log_time "开始生成 nginx 配置"
cat > /etc/nginx/nginx.conf << NGINX_EOF
worker_processes auto;
events { worker_connections 1024; }
http {
    # TCP 优化
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    # Keep-alive 优化（长连接）
    keepalive_timeout 75s;
    keepalive_requests 10000;

    # 大文件支持
    client_max_body_size 100m;
    client_body_buffer_size 10m;
    client_header_buffer_size 16k;
    large_client_header_buffers 4 32k;

    server {
        listen $PROXY_PORT;

        # 禁用请求体大小限制（支持大文件上传）
        client_max_body_size 0;

        location / {
            proxy_pass http://127.0.0.1:$DSH_PORT;
            proxy_http_version 1.1;

            # WebSocket 支持
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";

            # 透传原始请求信息
            proxy_set_header Host 127.0.0.1:$DSH_PORT;
            proxy_set_header Origin http://127.0.0.1:$DSH_PORT;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;

            # 强制上游返回未压缩内容（sub_filter 需要明文才能替换）
            proxy_set_header Accept-Encoding "";

            # 远程访问修复：让 DSH 前端认为始终是 loopback，启用设置面板
            sub_filter_once off;
            sub_filter_types text/javascript application/javascript;
            sub_filter 'isLoopbackHostname(pageLocation.hostname)' 'true';
            sub_filter 'isLoopback: this.connection.isLoopback' 'isLoopback: true';
            sub_filter 'isLoopback:connection.isLoopback' 'isLoopback:true';
            sub_filter 'isLoopback:this.connection.isLoopback' 'isLoopback:true';
            sub_filter 'isLoopback: transport?.ownsHost === true' 'isLoopback: true';
            sub_filter 'isLoopback:transport?.ownsHost===true' 'isLoopback:true';

            # 禁用缓冲，确保实时响应（WebSocket、SSE、流式输出）
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_cache off;

            # 明确告诉 nginx 不要 buffering（双保险）
            proxy_set_header X-Accel-Buffering no;

            # 超时设置（7 天，支持超长 WebSocket 连接）
            proxy_connect_timeout 10s;
            proxy_read_timeout 604800s;
            proxy_send_timeout 604800s;

            # 缓冲区大小（支持大文件/大 WebSocket 帧）
            proxy_buffer_size 64k;
            proxy_buffers 8 64k;
            proxy_busy_buffers_size 128k;

            $COOKIE_LINE
        }
    }
}
NGINX_EOF

log_time "✓ nginx 配置已生成"

# ── 5. 清理 + 启动 nginx ──
cleanup() { kill "$DSH_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo "[nginx] 启动：0.0.0.0:$PROXY_PORT → 127.0.0.1:$DSH_PORT"
log_time "启动 nginx (前台运行)"
nginx -g 'daemon off;'
