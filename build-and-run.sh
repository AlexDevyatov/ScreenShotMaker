#!/usr/bin/env bash
# build-and-run.sh — скрипт на хосте: сборка Docker-образа, монтирование APK и папки со скриншотами, запуск с KVM.
# Использование: ./build-and-run.sh [путь_к_apk] [путь_к_папке_скриншотов]
# Пример: ./build-and-run.sh ./app-release.apk ./screenshots

set -e

# Поиск docker в PATH или типичных путях (Docker Desktop на macOS часто не в PATH при запуске из IDE)
DOCKER_CMD="${DOCKER_CMD:-}"
if [[ -z "$DOCKER_CMD" ]]; then
    if command -v docker &>/dev/null; then
        DOCKER_CMD="docker"
    elif [[ -x /usr/local/bin/docker ]]; then
        DOCKER_CMD="/usr/local/bin/docker"
    elif [[ -x "$HOME/.docker/bin/docker" ]]; then
        DOCKER_CMD="$HOME/.docker/bin/docker"
    elif [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
        DOCKER_CMD="/Applications/Docker.app/Contents/Resources/bin/docker"
    else
        echo "ERROR: docker not found. Install Docker Desktop or add docker to PATH." >&2
        echo "On macOS: open Docker Desktop and run this script from a terminal where 'docker' is available." >&2
        exit 127
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-screenshot-maker}"
# Путь к APK: первый аргумент или app-release.apk в текущей директории
APK_INPUT="${1:-${SCRIPT_DIR}/app-release.apk}"
# Папка на хосте для скриншотов: второй аргумент или ./screenshots относительно скрипта
OUTPUT_DIR="${2:-${SCRIPT_DIR}/screenshots}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# Проверка наличия APK
if [[ ! -f "$APK_INPUT" ]]; then
    echo "Usage: $0 <path-to.apk> [output-dir]" >&2
    echo "APK not found: $APK_INPUT" >&2
    exit 1
fi

# Абсолютный путь к APK для монтирования
APK_ABS="$(cd "$(dirname "$APK_INPUT")" && pwd)/$(basename "$APK_INPUT")"

echo "Building Docker image: $IMAGE_NAME (linux/amd64 for Android x86_64 emulator)"
"$DOCKER_CMD" build --platform linux/amd64 -t "$IMAGE_NAME" "$SCRIPT_DIR"

# KVM только на Linux (ускоряет эмулятор). На macOS /dev/kvm нет — запускаем без него (медленнее).
DOCKER_RUN_EXTRA=()
if [[ -e /dev/kvm ]]; then
    DOCKER_RUN_EXTRA+=( --device /dev/kvm )
    echo "Using /dev/kvm for hardware acceleration."
else
    echo "No /dev/kvm (e.g. macOS) — emulator will use software rendering (slower)."
fi

echo "Running container (APK: $APK_ABS, output: $OUTPUT_DIR)"
"$DOCKER_CMD" run --rm --platform linux/amd64 \
    "${DOCKER_RUN_EXTRA[@]}" \
    -v "${APK_ABS}:/workspace/app.apk:ro" \
    -v "${OUTPUT_DIR}:/screenshots" \
    -e "APK_PATH=/workspace/app.apk" \
    -e "SCREENSHOTS_DIR=/screenshots" \
    "$IMAGE_NAME"

echo "Screenshots (and optionally screenshots.zip) are in: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
