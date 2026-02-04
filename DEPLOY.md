# Развёртывание ScreenshotMaker на удалённом сервере

Пошаговая инструкция по установке веб-сервиса на Linux-сервере (VPS, облако или свой хост).

## Требования к серверу

- **ОС:** Linux (Ubuntu 22.04+, Debian 11+ или RHEL/CentOS с yum/dnf)
- **Права:** возможность установки пакетов (sudo или root)
- **Ресурсы:** минимум 4 GB RAM, 2 CPU, 20 GB диск (эмулятор и образ занимают место)
- **Сеть:** открытый порт для веб-интерфейса (по умолчанию 8080)
- **Рекомендуется:** поддержка KVM (`/dev/kvm`) — без неё эмулятор работает медленнее

Проверка KVM на хосте:
```bash
ls -l /dev/kvm
# Если есть — аппаратная виртуализация доступна
```

---

## Шаг 1: Подключение к серверу

```bash
ssh user@your-server-ip
```

Убедитесь, что установлены `curl`, `git` и есть доступ в интернет.

---

## Шаг 2: Клонирование репозитория

```bash
cd ~
git clone https://github.com/AlexDevyatov/ScreenShotMaker.git
cd ScreenShotMaker
```

Либо скопируйте проект на сервер любым удобным способом (scp, rsync) и перейдите в каталог проекта.

---

## Шаг 3: Запуск скрипта развёртывания

```bash
chmod +x deploy.sh
./deploy.sh
```

Скрипт по очереди:

1. Устанавливает зависимости: Docker, Python 3, venv, pip
2. Собирает Docker-образ с Android SDK и эмулятором
3. Создаёт виртуальное окружение Python и ставит зависимости веб-сервера
4. Регистрирует и запускает systemd-сервис `screenshot-maker`

При первом запуске установка может занять 10–15 минут (скачивание Docker, образов, Android SDK).

---

## Шаг 4: Проверка работы

- **Статус сервиса:**
  ```bash
  sudo systemctl status screenshot-maker
  ```

- **Логи:**
  ```bash
  sudo journalctl -u screenshot-maker -f
  ```

- **Доступ к интерфейсу:** откройте в браузере:
  ```
  http://<IP-вашего-сервера>:8080
  ```
  Перетащите APK-файл в зону загрузки и дождитесь появления скриншотов.

---

## Настройка (опционально)

Перед запуском `./deploy.sh` можно задать переменные окружения:

| Переменная      | По умолчанию   | Описание |
|-----------------|----------------|----------|
| `APP_PORT`      | `8080`         | Порт веб-сервера |
| `APP_USER`      | текущий пользователь | Под каким пользователем запускается сервис |
| `IMAGE_NAME`    | `screenshot-maker` | Имя Docker-образа |
| `SERVICE_NAME`  | `screenshot-maker` | Имя systemd-сервиса |

Пример — запуск на порту 80 (потребуется root или capability):
```bash
sudo APP_PORT=80 ./deploy.sh
```

---

## Файрвол

Если вклюлён ufw или firewalld, откройте порт:

**ufw (Ubuntu/Debian):**
```bash
sudo ufw allow 8080/tcp
sudo ufw reload
```

**firewalld (RHEL/CentOS):**
```bash
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --reload
```

---

## Прокси (Nginx) — опционально

Чтобы отдавать сервис по 80/443 и при необходимости добавить HTTPS:

```nginx
# /etc/nginx/sites-available/screenshot-maker
server {
    listen 80;
    server_name your-domain.com;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 100M;
    }
}
```

Включение и перезагрузка Nginx:
```bash
sudo ln -s /etc/nginx/sites-available/screenshot-maker /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

---

## Полезные команды

| Действие | Команда |
|----------|---------|
| Перезапуск сервиса | `sudo systemctl restart screenshot-maker` |
| Остановка | `sudo systemctl stop screenshot-maker` |
| Запуск | `sudo systemctl start screenshot-maker` |
| Отключить автозапуск | `sudo systemctl disable screenshot-maker` |
| Логи за последний час | `sudo journalctl -u screenshot-maker --since "1 hour ago"` |

---

## Обновление после изменений в репозитории

```bash
cd ~/ScreenShotMaker
git pull
docker build --platform linux/amd64 -t screenshot-maker .
.venv/bin/pip install -r server/requirements.txt
sudo systemctl restart screenshot-maker
```

---

## Возможные проблемы

**Сервис не стартует**  
Проверьте логи: `sudo journalctl -u screenshot-maker -n 50`. Убедитесь, что порт 8080 свободен: `ss -tlnp | grep 8080`.

**Docker: permission denied**  
Добавьте пользователя в группу docker и перелогиньтесь:  
`sudo usermod -aG docker $USER` → выйти из SSH и зайти снова.

**Эмулятор не поднимается / таймаут**  
На VPS без KVM один запуск может занимать 5–10 минут. Если падает по таймауту — увеличьте ресурсы сервера (RAM/CPU) или проверьте, что образ собран для `linux/amd64`.

**Нет доступа снаружи**  
Проверьте: 1) сервис слушает `0.0.0.0:8080` (в deploy так и задано); 2) файрвол открыт; 3) у облачного провайдера в security group разрешён входящий трафик на порт 8080.
