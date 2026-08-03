FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    ROOT_PASSWORD=ELMINYAWE \
    TZ=UTC \
    LANG=en_US.UTF-8

# 1. تثبيت الحزم الأساسية، pyenv، sqlite3، و expect (لأتمتة إنشاء الحساب)
RUN apt-get update -y || (sleep 5 && apt-get update -y) && \
    apt-get install -y --no-install-recommends \
      openssh-server sudo curl wget git vim nano htop tmux \
      zip unzip tar rsync net-tools iproute2 iputils-ping dnsutils \
      build-essential python3 python3-pip ca-certificates gnupg lsb-release \
      software-properties-common locales tzdata cron bash-completion man-db \
      jq less file passwd openssh-client sqlite3 expect \
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

# 3. تثبيت ttyd (الـ Web Terminal)
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

# 6. إعداد مجلدات PufferPanel وملف الإعدادات
RUN mkdir -p /var/lib/pufferpanel/email /var/lib/pufferpanel/servers /etc/pufferpanel
RUN echo '{}' > /var/lib/pufferpanel/email/emails.json
COPY <<'EOF' /etc/pufferpanel/config.json
{
  "panel": {
    "web": {
      "listen": "0.0.0.0:8080",
      "files": "/var/www/pufferpanel"
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
RUN cp /etc/pufferpanel/config.json /var/lib/pufferpanel/config.json

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

# 1. تشغيل الـ Web Terminal على بورت 8081
/usr/local/bin/ttyd --port 8081 --writable --credential "root:${ROOT_PASSWORD}" /bin/bash -l &

# 2. تشغيل Cloudflare Tunnel للـ Web Terminal
touch /tmp/cf.log
(while true; do
  /usr/local/bin/cloudflared tunnel --url http://localhost:8081 >> /tmp/cf.log 2>&1
  sleep 5
done) &

# 3. تشغيل PufferPanel مع مراقبتها
(
  cd /var/lib/pufferpanel
  unset PORT
  while true; do
    pufferpanel run > /var/log/pufferpanel.log 2>&1 &
    PUFFER_PID=$!
    
    sleep 5
    if ! kill -0 $PUFFER_PID 2>/dev/null; then
        echo "❌❌ PufferPanel crashed! Error logs:"
        cat /var/log/pufferpanel.log
        echo "Restarting PufferPanel in 5 seconds..."
        sleep 5
    else
        wait $PUFFER_PID
        echo "PufferPanel stopped. Restarting in 5 seconds..."
        sleep 5
    fi
  done
) &

# 4. إنشاء حساب الأدمن تلقائياً (ELMINYAWE) باستخدام expect لتجاوز المشاكل التفاعلية
(
  echo "Waiting for PufferPanel database to initialize..."
  while ! sqlite3 /var/lib/pufferpanel/pufferpanel.db ".tables" 2>/dev/null | grep -q "users"; do
    sleep 2
  done
  
  if ! sqlite3 /var/lib/pufferpanel/pufferpanel.db "SELECT 1 FROM users WHERE email='ELMINYAWE@localhost.com' LIMIT 1;" 2>/dev/null | grep -q 1; then
      echo "Creating Admin User (ELMINYAWE) via expect..."
      expect << 'EXPECT_EOF'
set timeout 20
spawn pufferpanel user add
expect "Username:" { send "ELMINYAWE\r" }
expect "Email:" { send "ELMINYAWE@localhost.com\r" }
expect "Password:" { send "ELMINYAWE\r" }
expect "Confirm Password:" { send "ELMINYAWE\r" }
expect "Admin:" { send "y\r" }
expect eof
EXPECT_EOF
      echo "✅ Admin User created successfully!"
  else
      echo "Admin User (ELMINYAWE) already exists."
  fi
) &

# 5. طباعة بيانات الدخول بشكل احترافي ومنظم
(while true; do
  sleep 5
  URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf.log | tail -n 1)
  
  echo "=========================================================="
  echo "  ✅ WEB TERMINAL IS READY!"
  echo "  Link : ${URL:-Waiting for Cloudflare Tunnel...}"
  echo "  User : root"
  echo "  Pass : ${ROOT_PASSWORD}"
  echo "=========================================================="
  echo "  🚀 PufferPanel is running on port 8080"
  echo "  URL  : (Railway Settings -> Networking -> Port 8080)"
  echo "  Email: ELMINYAWE@localhost.com"
  echo "  Pass : ELMINYAWE"
  echo "=========================================================="
  
  sleep 25
done) &

# الحفاظ على تشغيل الحاوية إلى الأبد
wait
EOF
RUN chmod +x /entrypoint.sh

EXPOSE 8080 8081 22 5657

CMD ["/entrypoint.sh"]
