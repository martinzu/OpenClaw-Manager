FROM node:lts

# 安装必要工具：curl, bash, git, cron
# 注意：不用 Alpine，官方安装脚本依赖 Homebrew，仅支持 Debian/Ubuntu
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    bash \
    git \
    cron \
    # Chromium 及运行所需系统库（ARM64 原生支持，不用 Google Chrome）
    chromium \
    chromium-driver \
    fonts-noto-cjk \
    # 音视频处理工具
    ffmpeg \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# 用 pip 安装最新的 yt-dlp
RUN pip install --no-cache-dir --break-system-packages -U yt-dlp

# 告知 Puppeteer/Playwright 使用系统 Chromium，跳过自动下载
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

# 与官方镜像保持一致：设置 HOME，openclaw 配置存放在 /home/node/.openclaw
ENV HOME=/home/node

WORKDIR /home/node

# 通过官方安装脚本安装 OpenClaw
RUN curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard

# 补装 feishu 插件缺失的依赖
RUN npm install -g @larksuiteoapi/node-sdk \
    && npm cache clean --force

# 创建 cron 日志目录
RUN mkdir -p /var/log/cron

ENV NODE_ENV=production

# 暴露网关端口（与 .env 中 OPENCLAW_GATEWAY_PORT 对应）
EXPOSE 18789

# entrypoint 只负责启动 cron 守护进程，其余命令由 CMD / docker-compose command 传入
COPY <<'EOF' /entrypoint.sh
#!/bin/sh
# 启动系统 cron 守护进程（后台运行，负责执行备份等定时任务）
cron
# 执行传入的主进程命令（来自 CMD 或 docker-compose command，不消耗 OpenClaw token）
exec "$@"
EOF
RUN chmod +x /entrypoint.sh

# 默认命令，可被 docker-compose 的 command: 覆盖以指定 --bind / --port 等参数
# openclaw 命令 symlink 在 /usr/local/bin/openclaw -> ../lib/node_modules/openclaw/openclaw.mjs
CMD ["openclaw", "gateway", "--allow-unconfigured"]

ENTRYPOINT ["/entrypoint.sh"]