FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    ROOT_PASSWORD=ELMINYAWE \
    TZ=UTC \
    LANG=en_US.UTF-8 \
    PUFFER_PORT=8082 \
    PUFFER_ADMIN_USER=admin \
    PUFFER_ADMIN_PASS=admin123

RUN apt-get update -y || (sleep 5 && apt-get update -y) && \
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

# 1. تثبيت pyenv وإصدارات بايثون
RUN curl -fsSL https://pyenv.run | bash

ENV PYENV_ROOT="/root/.pyenv"
ENV PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"

RUN pyenv install 3.11 && \
    pyenv install 3.12 && \
    pyenv install 3.13 && \
    pyenv global 3.13

# 2. تثبيت ttyd (الـ Web Terminal)
RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in amd64) t=x86_64;; arm64) t=aarch64;; *) t="$arch";; esac && \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${t}" \
      -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd

# 3. تثبيت Cloudflared
RUN curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared

# 4. تثبيت PufferPanel
RUN curl -s https://packagecloud.io/install/repositories/pufferpanel/pufferpanel/script.deb.sh | os=ubuntu dist=noble bash && \
    apt-get install -y pufferpanel && \
    rm -rf /var/lib/apt/lists/*

# 5. إعداد مجلدات وملفات PufferPanel
RUN mkdir -p /var/lib/pufferpanel/email /var/lib/pufferpanel/servers /var/lib/pufferpanel/binaries
RUN echo '{}' > /var/lib/pufferpanel/email/emails.json

# إنشاء ملف config.json للوحة وتحديد البورت 8082
COPY <<'EOF' /var/lib/pufferpanel/config.json
{
  "panel": {
    "web": {
      "listen": "0.0.0.0:8082"
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

# 6. إعداد SSH
RUN mkdir -p /run/sshd && \
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# 7. ملف التشغيل الرئيسي (Entrypoint)
COPY <<'EOF' /entrypoint.sh
#!/usr/bin/env bash
set -e

# تفعيل باسورد الـ root و SSH
echo "root:${ROOT_PASSWORD}" | chpasswd
/usr/sbin/sshd

# تفعيل pyenv
export PYENV_ROOT="/root/.pyenv"
export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
eval "$(pyenv init -)"

# تشغيل PufferPanel في الخلفية
cd /var/lib/pufferpanel
nohup pufferpanel run > /var/log/pufferpanel.log 2>&1 &

# إنشاء حساب الأدمن تلقائياً للوحة (بعد ما اللوحة تفتح)
(
  sleep 5
  if ! pufferpanel user list 2>/dev/null | grep -q "${PUFFER_ADMIN_USER}"; then
      echo "Creating PufferPanel admin user..."
      printf "%s\n%s\n%s\n%s\n%s\n" "${PUFFER_ADMIN_USER}" "admin@localhost.com" "${PUFFER_ADMIN_PASS}" "${PUFFER_ADMIN_PASS}" "y" | pufferpanel user add || true
  fi
) &

# تشغيل الـ Web Terminal (ttyd) على بورت 8080
/usr/local/bin/ttyd --port 8080 --writable --credential "root:${ROOT_PASSWORD}" /bin/bash -l &

# تشغيل Cloudflare Tunnel للـ Web Terminal
(while true; do
  > /tmp/cf.log
  /usr/local/bin/cloudflared tunnel --url http://localhost:8080 >> /tmp/cf.log 2>&1
  echo "Cloudflared stopped. Restarting in 5 seconds..." >> /tmp/cf.log
  sleep 5
done) &

# طباعة بيانات الدخول
(while true; do
  sleep 5
  URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf.log | tail -n 1)
  echo "================================================"
  echo "  ✅ WEB TERMINAL IS READY!"
  echo "  Link: ${URL:-Waiting for Cloudflare Tunnel...}"
  echo "  User: root"
  echo "  Pass: ${ROOT_PASSWORD}"
  echo "================================================"
  echo "  🚀 PufferPanel is running on port ${PUFFER_PORT}"
  echo "  (Go to Railway Settings -> Networking -> Generate Domain for Port ${PUFFER_PORT})"
  echo "  Panel User: ${PUFFER_ADMIN_USER}"
  echo "  Panel Pass: ${PUFFER_ADMIN_PASS}"
  echo "================================================"
  sleep 25
done) &

tail -f /tmp/cf.log
EOF

RUN chmod +x /entrypoint.sh

# تعريض البورتات (8080 للـ Terminal، 8082 للوحة، 22 للـ SSH، 5657 للـ SFTP)
EXPOSE 8080 8082 22 5657

CMD ["/entrypoint.sh"]
