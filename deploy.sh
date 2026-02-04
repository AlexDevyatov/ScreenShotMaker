#!/usr/bin/env bash
# deploy.sh — развёртывание ScreenshotMaker на удалённом Linux-сервере.
# Устанавливает Docker, зависимости и запускает веб-сервис.
# Запуск: на сервере в корне проекта выполнить: chmod +x deploy.sh && ./deploy.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Параметры ---
APP_USER="${APP_USER:-$USER}"
APP_PORT="${APP_PORT:-8080}"
IMAGE_NAME="${IMAGE_NAME:-screenshot-maker}"
SERVICE_NAME="${SERVICE_NAME:-screenshot-maker}"

# Проверка: Linux
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Этот скрипт предназначен для Linux. Текущая ОС: $(uname -s)" >&2
    exit 1
fi

# Проверка прав (нужен sudo для установки пакетов)
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo &>/dev/null; then
        SUDO="sudo"
    else
        echo "Запустите скрипт с правами root или установите sudo." >&2
        exit 1
    fi
fi

echo "=== Установка зависимостей ==="

# Определение менеджера пакетов
if command -v apt-get &>/dev/null; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq \
        ca-certificates \
        curl \
        git \
        python3 \
        python3-venv \
        python3-pip
elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
    PKG=$(command -v dnf || command -v yum)
    $SUDO $PKG install -y \
        ca-certificates \
        curl \
        git \
        python3 \
        python3-pip
else
    echo "Поддерживаются только apt и yum/dnf. Установите вручную: Docker, Python 3, venv, pip." >&2
    exit 1
fi

# Установка Docker (если ещё не установлен)
if ! command -v docker &>/dev/null; then
    echo "Установка Docker..."
    curl -fsSL https://get.docker.com | $SUDO sh
    $SUDO usermod -aG docker "$APP_USER" 2>/dev/null || true
    echo "Docker установлен. Для применения группы docker перелогиньтесь или выполните: newgrp docker"
else
    echo "Docker уже установлен: $(docker --version)"
fi

# Docker Compose v2 (плагин) — опционально
if ! docker compose version &>/dev/null 2>&1; then
    echo "Рекомендуется установить Docker Compose (docker compose version). Скрипт продолжит без него."
fi

echo "=== Сборка образа ScreenshotMaker ==="
docker build --platform linux/amd64 -t "$IMAGE_NAME" "$SCRIPT_DIR"

echo "=== Подготовка веб-сервера ==="
VENV_DIR="$SCRIPT_DIR/.venv"
if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -q -r "$SCRIPT_DIR/server/requirements.txt"

# Создание директорий для загрузок и результатов
mkdir -p "$SCRIPT_DIR/uploads" "$SCRIPT_DIR/jobs"
chmod 700 "$SCRIPT_DIR/uploads" "$SCRIPT_DIR/jobs" 2>/dev/null || true

echo "=== Создание systemd-сервиса ==="
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
$SUDO tee "$UNIT_FILE" >/dev/null << EOF
[Unit]
Description=ScreenshotMaker Web Service
After=network.target docker.service

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$SCRIPT_DIR
Environment=PORT=$APP_PORT
Environment=IMAGE_NAME=$IMAGE_NAME
ExecStart=$VENV_DIR/bin/uvicorn server.main:app --host 0.0.0.0 --port $APP_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable "$SERVICE_NAME"
$SUDO systemctl restart "$SERVICE_NAME"

echo ""
echo "Сервис развёрнут."
echo "  URL: http://<IP-сервера>:$APP_PORT"
echo "  Статус: $SUDO systemctl status $SERVICE_NAME"
echo "  Логи:   $SUDO journalctl -u $SERVICE_NAME -f"
echo ""
echo "На сервере с KVM эмулятор будет быстрее. Проверка: ls -l /dev/kvm"
