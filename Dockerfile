# ── 阶段 1：源码编译 ──
FROM node:24-bookworm AS builder
ARG DSH_TAG=dsh-v0.1.6-alpha.2
RUN corepack enable
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ git \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch ${DSH_TAG} \
    https://github.com/deepseek-ai/deepseek-harness.git /dsh-src
WORKDIR /dsh-src
RUN pnpm install --frozen-lockfile
RUN pnpm run build

# ── 阶段 2：运行（nginx 反向代理） ──
FROM node:24-slim
RUN corepack enable
RUN apt-get update && apt-get install -y --no-install-recommends nginx python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /dsh-src /dsh-src
COPY requirements.txt /requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /requirements.txt \
    && ln -sf /usr/bin/python3 /usr/bin/python
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 3080
ENTRYPOINT ["/entrypoint.sh"]
