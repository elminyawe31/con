FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    ROOT_PASSWORD=ELMINYAWE \
    TZ=UTC \
    LANG=en_US.UTF-8

# 1. تثبيت الحزم الأساسية و pyenv
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      openssh-server sudo curl wget git vim nano htop tmux \
      zip unzip tar rsync net-tools iproute2 iputils-ping dnsutils \
      build-essential python3 python3-pip ca-certificates gnupg lsb-release \
      software-properties-common locales tzdata cron bash-completion man-db \
      jq less file passwd openssh-client \
      make libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
      libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev && \
    locale-gen en_US.UTF-8 && \
    rm -rf /var/lib/apt/lists/*

# 2. تثبيت pyenv وإصدارات بايثون
RUN curl -fsSL https://pyenv.run | bash
ENV PYENV_ROOT="/root/.pyenv"
ENV PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
RUN pyenv install 3.11 && \
    pyenv install 3.12 && \
    pyenv install 3.13 && \
    pyenv global 3.13

# 3. تثبيت ttyd (الـ Web Terminal على بورت 8080)
RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in amd64) t=x86_64;; arm64) t=aarch64;; *) t="$arch";; esac && \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${t}" \
      -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd

# 4. تثبيت Cloudflared
RUN curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared

# 5. تثبيت PufferPanel
RUN curl -s https://packagecloud.io/install/repositories/pufferpanel/pufferpanel/script.deb.sh | os=ubuntu dist=noble bash && \
    apt-get install -y pufferpanel && \
    rm -rf /var/lib/apt/lists/*

# 6. إعداد مجلدات PufferPanel وملف الكونفيج الإجباري على بورت 8081
RUN mkdir -p /var/lib/pufferpanel/email /var/lib/pufferpanel/servers /etc/pufferpanel
RUN echo '{}' > /var/lib/pufferpanel/email/emails.json
COPY <<'EOF' /etc/pufferpanel/config.json
{
  "panel": {
    "web": {
      "listen": "0.0.0.0:8081"
    },
    "database": {
      "dialect": "sqlite3",
      "url": "file:/var/lib/pufferpanel/pufferpanel.db?cache=shared&mode=rwc"
    }
  },
  "daemon": {
    "sftp": {
      "port": 5657
    }
  }
}
EOF

# 7. إعداد SSH
RUN mkdir -p /run/sshd && \
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# 8. ملف التشغيل الرئيسي (Entrypoint)
COPY <<'EOF' /entrypoint.sh
#!/usr/bin/env bash
set -e

echo "root:${ROOT_PASSWORD}" | chpasswd
/usr/sbin/sshd

export PYENV_ROOT="/root/.pyenv"
export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
eval "$(pyenv init -)"

# تشغيل PufferPanel في الخلفية على بورت 8081
nohup pufferpanel run > /var/log/pufferpanel.log 2>&1 &

# تشغيل الـ Web Terminal على بورت 8080
/usr/local/bin/ttyd --port 8080 --writable --credential "root:${ROOT_PASSWORD}" /bin/bash -l &

# تشغيل Cloudflare Tunnel للـ Web Terminal
(while true; do
  > /tmp/cf.log
  /usr/local/bin/cloudflared tunnel --url http://localhost:8080 >> /tmp/cf.log 2>&1
  sleep 5
done) &

# طباعة بيانات الدخول
(while true; do
  sleep 5
  URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf.log | tail -n 1)
  echo "================================================"
  echo "  ✅ WEB TERMINAL IS READY!"
  echo "  Link: ${URL:-Waiting for Cloudflare Tunnel...}"
  echo "  User: root | Pass: ${ROOT_PASSWORD}"
  echo "================================================"
  echo "  🚀 PufferPanel is running on port 8081"
  echo "  (Railway Settings -> Networking -> Generate Domain -> Port 8081)"
  echo "================================================"
  sleep 25
done) &

tail -f /tmp/cf.log
EOF
RUN chmod +x /entrypoint.sh

EXPOSE 8080 8081 22 5657

CMD ["/entrypoint.sh"]
