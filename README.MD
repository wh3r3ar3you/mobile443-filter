# 🛡️ mobile443 — ASN-фильтр для VPN

Фильтр подключений к VPN-серверу по ASN.  
Разрешает подключения **только с мобильных операторов РФ**, блокирует всё остальное.  
Интеграция с **Remnawave** панелью для Telegram-уведомлений пользователям.

## ⚡ Установка

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Makhkets/mobile443-filter/refs/heads/main/install.sh)
```

## 📋 Что спросит при установке

1. **Порты** — на каких портах фильтровать (например: `443 8443 9443 10443 11443 12443 13443`)
2. **Telegram уведомления** — включить или нет (`y/n`)
3. Если включены:
   - **Токен Telegram бота** — от [@BotFather](https://t.me/BotFather)
   - **Telegram ID админа** — для ежедневной статистики
   - **Адрес панели Remnawave** — например `https://panel.example.com`
   - **API токен Remnawave** — для запросов к панели
   - **Источник Telegram ID** — откуда брать ID пользователя:
     - `1` — из поля `telegramId` в API Remnawave
     - `2` — из поля `username`, парсинг последнего значения после `_`
   - **Путь к access.log** — скрипт попытается найти автоматически

## 📱 Как работают уведомления

### Определение пользователя

1. Iptables логирует заблокированный IP
2. В `access.log` xray по IP находится **ID пользователя** (поле `email`)
3. По этому ID делается запрос к Remnawave API (`/api/users/by-id/{id}`)
4. Из ответа API извлекается Telegram ID (в зависимости от выбранного источника)
5. Пользователю отправляется уведомление о блокировке (cooldown — 6 часов)

### Статистика для админа

Каждый день в **09:00** бот отправляет отчёт: количество блокировок, уникальные IP, топ-10 IP.

## ⚙️ Предварительная настройка xray

Чтобы уведомления работали, нужен `access.log` от xray на хосте.

**1. Добавьте в конфиг xray секцию `log`:**

```json
{
  "log": {
    "access": "/var/log/remnanode/access.log",
    "loglevel": "info"
  }
}
```

**2. Пробросьте логи через Docker volume в `docker-compose.yml`:**

```yaml
volumes:
  - '/var/log/remnanode:/var/log/remnanode'
```

**3. Перезапустите контейнер:**

```bash
docker compose down && docker compose up -d
```

## 🔍 Проверка работы

```bash
# Статус сервисов
systemctl status mobile443-monitor.service --no-pager
systemctl status mobile443-update.timer --no-pager

# Логи монитора
journalctl -u mobile443-monitor.service -f --no-pager

# Правила iptables
iptables -L FILTER_MOBILE_443 -n -v --line-numbers

# Количество IP в allowlist
ipset list allowed_mobile_443 | head -10
```

## �️ Удаление

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Makhkets/mobile443-filter/refs/heads/main/install.sh) remove
```

## ⚙️ Изменение конфигурации

```bash
# Переустановка
./asn.sh remove && ./asn.sh install
```

Или вручную:

```bash
nano /opt/mobile443/config.conf
systemctl restart mobile443-monitor.service
```

## 📂 Структура

```
/opt/mobile443/config.conf       # Конфигурация
/opt/mobile443/asns.conf         # Список ASN
/var/lib/mobile443/              # Состояние (кеш, статистика, lock)
/usr/local/sbin/mobile443-*.sh   # Скрипты
```

## 📝 Лицензия

MIT
