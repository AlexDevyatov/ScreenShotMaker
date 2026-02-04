#!/usr/bin/env bash
# run.sh — скрипт внутри контейнера: запуск эмулятора, смена локали, установка APK, снятие скриншотов.
# Ожидает: APK по пути APK_PATH или /workspace/app.apk. Результат: /screenshots/main_ru.png, main_en.png, main_es.png

set -e

# Таймаут ожидания загрузки эмулятора (секунды; без KVM загрузка дольше)
EMU_BOOT_TIMEOUT=120
# Таймаут ожидания после ребута по локали
REBOOT_TIMEOUT=90
# Задержка после запуска приложения перед скриншотом (секунды)
SCREENSHOT_DELAY=5

# Путь к APK: переменная окружения или значение по умолчанию
APK_PATH="${APK_PATH:-/workspace/app.apk}"
SCREENSHOTS_DIR="${SCREENSHOTS_DIR:-/screenshots}"
AVD_NAME="${AVD_NAME:-Pixel_5_API_33}"

# Проверка наличия APK
if [[ ! -f "$APK_PATH" ]]; then
    echo "ERROR: APK not found at $APK_PATH" >&2
    exit 1
fi

# Каталог с build-tools для aapt (разбор APK)
BUILD_TOOLS_DIR="${ANDROID_HOME}/build-tools/34.0.0"
AAPT="${BUILD_TOOLS_DIR}/aapt"
if [[ ! -x "$AAPT" ]]; then
    echo "ERROR: aapt not found at $AAPT" >&2
    exit 1
fi

# Извлечение package и launcher activity из APK
get_package() {
    "$AAPT" dump badging "$APK_PATH" 2>/dev/null | sed -n "s/package: name='\([^']*\)'.*/\1/p" | head -1
}
get_launcher_activity() {
    "$AAPT" dump badging "$APK_PATH" 2>/dev/null | sed -n "s/.*launchable-activity: name='\([^']*\)'.*/\1/p" | head -1
}

PACKAGE=$(get_package)
ACTIVITY=$(get_launcher_activity)
if [[ -z "$PACKAGE" ]]; then
    echo "ERROR: Could not get package name from APK" >&2
    exit 1
fi
if [[ -z "$ACTIVITY" ]]; then
    echo "WARN: No launchable-activity found, using package as activity (monkey)" >&2
    ACTIVITY=""
fi

echo "APK: $APK_PATH"
echo "Package: $PACKAGE"
echo "Launcher activity: $ACTIVITY"
echo "Screenshots dir: $SCREENSHOTS_DIR"
mkdir -p "$SCREENSHOTS_DIR"

# Ожидание полной загрузки Android (boot_completed)
wait_for_boot() {
    local timeout=${1:-$EMU_BOOT_TIMEOUT}
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if adb shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
            echo "Boot completed in ${elapsed}s"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo "ERROR: Emulator did not boot within ${timeout}s" >&2
    return 1
}

# Завершение эмулятора при выходе (успешном или по ошибке)
cleanup() {
    echo "Stopping emulator..."
    adb emu kill 2>/dev/null || true
}
trap cleanup EXIT

# Запуск эмулятора в фоне без GUI
# -no-modem избегает ошибки "address resolution failed for ::1" в Docker без IPv6
# -gpu auto: с KVM даёт ускорение; без KVM откатится на swiftshader (медленно)
echo "Starting emulator (no window, no audio)..."
emulator -avd "$AVD_NAME" \
    -no-window \
    -no-audio \
    -no-boot-anim \
    -no-modem \
    -gpu auto \
    -no-snapshot-load \
    -wipe-data \
    -no-sim \
    -memory 2048 \
    &

EMU_PID=$!
echo "Emulator PID: $EMU_PID"

# Ждём появления устройства
echo "Waiting for device..."
adb wait-for-device
echo "Device connected, waiting for boot..."
if ! wait_for_boot "$EMU_BOOT_TIMEOUT"; then
    kill $EMU_PID 2>/dev/null || true
    exit 1
fi

# Дополнительная пауза после boot для стабильности
sleep 5

# Локали: короткое имя для имени файла и полный тег для системы
# Формат для setprop persist.sys.locale: ru-RU, en-US, es-ES (Android 13/14)
LOCALES=( "ru:ru-RU" "en:en-US" "es:es-ES" )

for entry in "${LOCALES[@]}"; do
    lang="${entry%%:*}"
    locale_full="${entry##*:}"
    echo "=== Locale: $locale_full ($lang) ==="

    # Смена системной локали. На Android 13/14 в эмуляторе с root доступно через setprop + reboot.
    adb root 2>/dev/null || true
    adb shell setprop persist.sys.locale "$locale_full"
    adb shell setprop persist.sys.language "${locale_full%%-*}"
    adb shell setprop persist.sys.country "${locale_full##*-}"
    echo "Rebooting to apply locale..."
    adb reboot
    adb wait-for-device
    if ! wait_for_boot "$REBOOT_TIMEOUT"; then
        echo "ERROR: Emulator did not boot after reboot for locale $locale_full" >&2
        continue
    fi
    sleep 3

    # Установка APK (переустановка для чистого состояния)
    echo "Installing APK..."
    adb install -r "$APK_PATH" || { echo "WARN: install -r failed, trying install"; adb install "$APK_PATH" || true; }

    # Запуск приложения (главный экран)
    if [[ -n "$ACTIVITY" ]]; then
        adb shell am start -n "${PACKAGE}/${ACTIVITY}" -a android.intent.action.MAIN -c android.intent.category.LAUNCHER
    else
        adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1
    fi
    sleep "$SCREENSHOT_DELAY"

    # Скриншот в PNG
    out_file="${SCREENSHOTS_DIR}/main_${lang}.png"
    adb exec-out screencap -p > "$out_file"
    if [[ -s "$out_file" ]]; then
        echo "Saved: $out_file"
    else
        echo "WARN: Screenshot empty or failed: $out_file" >&2
    fi
done

# Опционально: архив скриншотов
if command -v zip &>/dev/null; then
    cd "$SCREENSHOTS_DIR"
    zip -q screenshots.zip main_ru.png main_en.png main_es.png 2>/dev/null && echo "Created: $SCREENSHOTS_DIR/screenshots.zip" || true
fi

echo "Done. Screenshots in $SCREENSHOTS_DIR"
