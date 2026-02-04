# Dockerfile для автоматической генерации скриншотов Android-приложения на разных языках.
# Среда: Linux с KVM. Образ содержит Android SDK, AVD (Pixel 5, Android 34, Google APIs x86_64).

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
# Android SDK
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${PATH}"

# Установка зависимостей: Java, утилиты, библиотеки для эмулятора (без GUI)
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless \
    wget \
    unzip \
    libgl1-mesa-glx \
    libpulse0 \
    libxrandr2 \
    libxcb1 \
    libxkbcommon0 \
    libxcomposite1 \
    libxcursor1 \
    libxi6 \
    libxext6 \
    libxfixes3 \
    libxrender1 \
    libxxf86vm1 \
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-1-3 \
    libxdamage1 \
    libxshmfence1 \
    libasound2 \
    ca-certificates \
    zip \
    && rm -rf /var/lib/apt/lists/*

# Скачивание Android Command Line Tools (официальный пакет Google)
# Используем linux — на arm64 хосте собираем с --platform linux/amd64 для совместимости образа системы x86_64.
ARG CMDLINE_TOOLS_VERSION=13114758
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip" -O /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d /tmp && \
    mv /tmp/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest && \
    rm /tmp/cmdline-tools.zip

# Принятие лицензий
RUN yes | sdkmanager --sdk_root=${ANDROID_HOME} --licenses 2>/dev/null || true

# Установка platform-tools, platforms, build-tools
RUN sdkmanager --sdk_root=${ANDROID_HOME} "platform-tools" && \
    sdkmanager --sdk_root=${ANDROID_HOME} "platforms;android-33" && \
    sdkmanager --sdk_root=${ANDROID_HOME} "platforms;android-34" && \
    sdkmanager --sdk_root=${ANDROID_HOME} "build-tools;34.0.0"

# Эмулятор: sdkmanager не находит пакет "emulator" в репозитории — качаем архив напрямую из Google
# Ставим до system-images, т.к. system-images объявлен как зависимость от emulator
ARG EMULATOR_VERSION=14808823
RUN wget -q "https://dl.google.com/android/repository/emulator-linux_x64-${EMULATOR_VERSION}.zip" -O /tmp/emulator.zip && \
    unzip -q /tmp/emulator.zip -d ${ANDROID_HOME} && \
    rm /tmp/emulator.zip && \
    chmod +x ${ANDROID_HOME}/emulator/emulator ${ANDROID_HOME}/emulator/qemu/linux-x86_64/qemu-system-x86_64 2>/dev/null || true

# System-image: для android-34 sdkmanager требует пакет emulator в репозитории — используем android-33
RUN sdkmanager --sdk_root=${ANDROID_HOME} "system-images;android-33;google_apis;x86_64"

# Создание AVD: Pixel 5, Android 33, Google APIs x86_64
# avdmanager использует ANDROID_HOME из ENV, флаг --sdk_root не поддерживается в create avd
RUN echo "no" | avdmanager create avd \
    -n "Pixel_5_API_33" \
    -k "system-images;android-33;google_apis;x86_64" \
    -d "pixel_5" \
    --force

# Конфигурация AVD для headless
RUN mkdir -p /root/.android/avd/Pixel_5_API_33.avd && \
    echo "hw.gpu.mode=auto" >> /root/.android/avd/Pixel_5_API_33.ini && \
    echo "hw.gpu.enabled=yes" >> /root/.android/avd/Pixel_5_API_33.ini

# Папка для скриншотов внутри контейнера
RUN mkdir -p /screenshots

# Скрипт запуска (монтируется или копируется при сборке)
COPY run.sh /run.sh
RUN chmod +x /run.sh

WORKDIR /workspace

# Точка входа: ожидаем APK по пути /workspace/app.apk (или APK_PATH)
ENTRYPOINT ["/run.sh"]
