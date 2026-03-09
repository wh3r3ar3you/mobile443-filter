# 🛡️ mobile443 — ASN-фильтр для VPN

Автоматический фильтр подключений к VPN-серверу по ASN (автономным системам).  
Разрешает подключения **только с мобильных операторов РФ**, блокирует всё остальное.

## ✨ Возможности

- 📡 **Фильтрация по ASN** — только мобильные операторы (МТС, Билайн, МегаФон, Tele2, Ростелеком)
- 🔌 **Настраиваемые порты** — задаёте при установке, без хардкода
- 📱 **Telegram-уведомления пользователям** — при блокировке подключения
- 📊 **Ежедневная статистика админу** — сколько заблокировано, топ IP
- 🔄 **Автообновление списков** — ежедневно в 00:00 через RIPEstat API
- 🐳 **Docker-совместимость** — автоматическая интеграция с DOCKER-USER
- 🔗 **Интеграция с Remnanode/Xray** — определение пользователей по email

## ⚡ Быстрая установка

Одна команда на вашем сервере:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/asn/main/install.sh)
```


## 🔧 Ручная установка

```bash
# Клонируем репозиторий
git clone https://github.com/wh3r3ar3you/asn.git
cd asn

# Делаем исполняемым и запускаем
chmod +x asn.sh
./asn.sh install
```

## 📋 Что спросит при установке

1. **Порты** — на каких портах фильтровать (например: `443 8443 9443 10443`)
2. **Telegram уведомления** — включить или нет (`y/n`)
3. Если да:
   - **Токен бота** — получите у [@BotFather](https://t.me/BotFather)
   - **Telegram ID админа** — ваш числовой ID (узнать: [@userinfobot](https://t.me/userinfobot))
   - **Путь к access.log** — скрипт попытается найти автоматически

## 📂 Структура после установки

```
/opt/mobile443/
├── asns.conf          # Список ASN для allowlist
└── config.conf        # Конфигурация (порты, токен, и т.д.)

/var/lib/mobile443/
├── prefixes.txt       # Кеш IP-префиксов
├── stats_blocked.txt  # Лог заблокированных подключений
├── notified.txt       # Трекер уведомлений (cooldown)
└── lock               # Lock-файл

/usr/local/sbin/
├── mobile443-common.sh       # Общие функции
├── mobile443-update.sh       # Обновление ASN-списков
├── mobile443-apply-cache.sh  # Применение кешированных правил
├── mobile443-monitor.sh      # Мониторинг блокировок → Telegram
└── mobile443-stats.sh        # Ежедневная статистика

Systemd сервисы:
├── mobile443-apply.service    # Применение правил при загрузке
├── mobile443-update.service   # Обновление ASN-списков
├── mobile443-update.timer     # Таймер обновления (00:00)
├── mobile443-monitor.service  # Мониторинг блокировок
├── mobile443-stats.service    # Отправка статистики
└── mobile443-stats.timer      # Таймер статистики (09:00)
```

## 🔍 Проверка работы

```bash
# Статус обновления ASN
systemctl status mobile443-update.service --no-pager

# Таймер обновления
systemctl status mobile443-update.timer --no-pager

# Мониторинг блокировок (если включен Telegram)
systemctl status mobile443-monitor.service --no-pager

# Логи монитора в реальном времени
journalctl -u mobile443-monitor.service -f --no-pager

# Текущие правила iptables
iptables -L FILTER_MOBILE_443 -n -v --line-numbers

# Количество IP в allowlist
ipset list allowed_mobile_443 | head -10
```

## 🗑️ Удаление

```bash
./asn.sh remove
```

Или одной командой:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/asn/main/install.sh) remove
```

## 📱 Telegram-уведомления

### Для пользователей
Когда подключение блокируется, бот отправляет сообщение пользователю с предупреждением.

**Как определяется пользователь:**
- Из iptables LOG извлекается заблокированный IP
- В `access.log` xray ищем этот IP → находим email
- Формат email: `idremna_idtelegram` → извлекаем Telegram ID
- Отправляем уведомление (cooldown 6 часов, чтобы не спамить)

> ⚠️ **Ограничение:** уведомление возможно только если IP ранее был виден в access.log xray. Если пользователь впервые подключается с заблокированного IP — xray его не видел.

### Для админа
Каждый день в **09:00** бот отправляет отчёт:
- 🚫 Количество заблокированных соединений
- 🌐 Уникальных заблокированных IP
- 📋 Размер allowlist
- 🔝 Топ-10 заблокированных IP

## 📡 Список поддерживаемых ASN

| Оператор | ASN |
|----------|-----|
| МТС | 8359 |
| Билайн | 3216 |
| МегаФон | 31133, 8263, 6854 и др. |
| Tele2 | 12958, 15378 и др. |
| Miranda | 201776 |
| Сбербанк-Телеком | 206673 |
| Ростелеком | 12389 |

Полный список — в файле `asns.conf` после установки.

## ⚙️ Изменение конфигурации

Для изменения портов, токена или других настроек:

```bash
# Переустановите с новыми параметрами
./asn.sh remove
./asn.sh install
```

Или вручную отредактируйте `/opt/mobile443/config.conf` и перезапустите сервисы:

```bash
nano /opt/mobile443/config.conf
systemctl restart mobile443-apply.service
systemctl restart mobile443-monitor.service
```

## 📝 Лицензия

MIT
