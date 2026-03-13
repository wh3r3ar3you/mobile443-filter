# 🛡️ mobile443 v0.3.1

Фильтр для VPN-портов, который теперь работает в два слоя:

1. 🚫 `traf_guard` сначала дропает IP из blocklist
2. 📶 затем `mobile allowlist` пускает только IP из мобильных ASN
3. ⛔ всё остальное на указанных портах дропается

При этом обычный режим установки по-прежнему умеет:

- 🤖 уведомлять пользователей в Telegram о блокировке
- 📊 отправлять ежедневную статистику админу
- 🚨 отправлять админу alert при попытке доступа с IP из `traffic-guard` списков
- 🌐 искать пользователя через `xray access.log`
- 🧩 ходить в панель Remnawave за Telegram ID


## ✨ Что изменилось в v0.3.1

- восстановлен полный дефолтный список мобильных ASN
- возвращены `AS16345`, `AS205638` и `AS214257`

## ✨ Что изменилось в v0.3

- добавлен отдельный `DROP`-слой на базе `traffic-guard-lists`
- `DROP` теперь всегда идёт раньше `ACCEPT` по мобильным ASN
- появился отдельный `install_block_only.sh`
- ежедневное обновление списков сведено в единый `systemd timer`
- сохранена совместимость со старым `install.sh` и Telegram/Remnawave flow

## 🧠 Как работает фильтрация

Используются:

- `ipset traf_guard_government`
- `ipset traf_guard_antiscanner`
- `ipset allowed_mobile_443`
- `chain TRAF_GUARD_PRECHECK`
- `chain FILTER_MOBILE_443`

### Полный режим

```text
INPUT/FORWARD/DOCKER-USER -> FILTER_MOBILE_443
FILTER_MOBILE_443 -> TRAF_GUARD_PRECHECK
TRAF_GUARD_PRECHECK: traf_guard_government -> DROP
TRAF_GUARD_PRECHECK: traf_guard_antiscanner -> DROP
FILTER_MOBILE_443: allowed_mobile_443 -> ACCEPT
FILTER_MOBILE_443: LOG
FILTER_MOBILE_443: DROP
```

Иными словами:

- если IP в `government_networks.list` -> `DROP`
- если IP в `antiscanner.list` -> `DROP`
- иначе если IP входит в мобильный allowlist -> `ACCEPT`
- иначе -> `DROP`

### Block-only режим

```text
INPUT/FORWARD/DOCKER-USER -> FILTER_MOBILE_443
FILTER_MOBILE_443 -> TRAF_GUARD_PRECHECK
TRAF_GUARD_PRECHECK: traf_guard_government -> DROP
TRAF_GUARD_PRECHECK: traf_guard_antiscanner -> DROP
FILTER_MOBILE_443: RETURN
```

Здесь режутся только IP из blocklist, а остальной трафик не ломается.

## 📦 Какие списки используются

По умолчанию:

- `TRAF_GUARD_BASE_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public"`
- `GOV_LIST_URL="${TRAF_GUARD_BASE_URL}/government_networks.list"`
- `ANTISCANNER_LIST_URL="${TRAF_GUARD_BASE_URL}/antiscanner.list"`

Локально они хранятся в:

- `/opt/mobile443/lists/government_networks.list`
- `/opt/mobile443/lists/antiscanner.list`

Списки:

- очищаются от пустых строк и комментариев
- проходят базовую проверку CIDR
- не падают на единичных битых строках
- обновляются атомарно
- загружаются в `ipset` через временные наборы и `ipset swap`

## ⚙️ Режимы установки

### 1. Обычный режим

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh)
```

Что делает:

- включает `traf_guard`
- включает mobile ASN allowlist
- спрашивает порты
- по желанию включает Telegram уведомления
- при включённом Telegram спрашивает:
  - токен бота
  - Telegram ID админа
  - адрес панели Remnawave
  - API токен панели
  - источник Telegram ID
  - путь к `xray access.log`

Обновление существующей установки:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) update
```

`update`:

- смотрит текущий конфиг
- определяет установленный профиль
- делает backup текущего конфига
- удаляет старый runtime проекта
- ставит новую версию поверх со старой конфигурацией
- сохраняет `asns.conf`, если он уже был настроен

### 2. Block-only режим

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh)
```

Этот режим:

- не трогает Telegram
- не спрашивает Remnawave API
- не ищет `xray access.log`
- не включает mobile ASN allowlist

Но спрашивает:

1. 🧱 Какие blocklist включить:
   - оба списка
   - только `government`
   - только `antiscanner`
2. 🔌 Какие порты фильтровать через пробел

Обновление block-only установки:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh) update
```

Здесь тоже используется безопасный путь: `backup -> remove -> reinstall`.

## 📱 Telegram и Remnawave

В обычном режиме всё осталось как раньше.

### Как определяется пользователь

1. `iptables` логирует заблокированное подключение
2. по IP ищется пользователь в `xray access.log`
3. из лога берётся `email` / ID пользователя
4. по этому ID идёт запрос в Remnawave API
5. из ответа берётся Telegram ID
6. пользователю уходит уведомление о блокировке

### Что получает админ

Раз в день отправляется статистика:

- количество блокировок
- число уникальных IP
- top IP
- размер mobile allowlist
- размер traffic-guard списков

И отдельно бот шлёт мгновенные Telegram-уведомления админу, если кто-то пытается подключиться с IP из сетей `traffic-guard`.

Дополнительно админ получает оперативный alert, если подключение прилетело из:

- `government_networks.list`
- `antiscanner.list`

Для таких событий используются отдельные лог-префиксы в `iptables`, а бот шлёт уведомление с IP, портом и причиной блокировки.

## 🕛 Автообновление

Используется:

- `mobile443-update.service`
- `mobile443-update.timer`
- `mobile443-apply.service`

Таймер запускается ежедневно в `00:00`.

В это обновление входят:

- `government_networks.list`
- `antiscanner.list`
- mobile ASN allowlist, если он включён
- пересборка `ipset`
- приведение `iptables` chain к нужному виду без дублей

Если включён Telegram, дополнительно ставятся:

- `mobile443-monitor.service`
- `mobile443-stats.service`
- `mobile443-stats.timer`

## 🧾 Конфиг

Основной конфиг:

- `/opt/mobile443/config.conf`

Ключевые флаги:

```bash
ENABLE_TRAF_GUARD="true|false"
ENABLE_TRAF_GUARD_GOVERNMENT="true|false"
ENABLE_TRAF_GUARD_ANTISCANNER="true|false"
ENABLE_MOBILE_ALLOW="true|false"
ENABLE_TELEGRAM="true|false"
PORTS="443 8443"
TRAF_GUARD_BASE_URL="..."
GOV_LIST_URL="..."
ANTISCANNER_LIST_URL="..."
```

Примеры:

```bash
# Обычная установка
ENABLE_TRAF_GUARD="true"
ENABLE_TRAF_GUARD_GOVERNMENT="true"
ENABLE_TRAF_GUARD_ANTISCANNER="true"
ENABLE_MOBILE_ALLOW="true"

# Block-only
ENABLE_TRAF_GUARD="true"
ENABLE_TRAF_GUARD_GOVERNMENT="true"
ENABLE_TRAF_GUARD_ANTISCANNER="true"
ENABLE_MOBILE_ALLOW="false"
ENABLE_TELEGRAM="false"
```

## 🔍 Команды проверки

### Iptables

```bash
iptables-save | grep -E 'FILTER_MOBILE_443|TRAF_GUARD_PRECHECK|allowed_mobile_443|traf_guard_'
iptables -L TRAF_GUARD_PRECHECK -n -v --line-numbers
iptables -L FILTER_MOBILE_443 -n -v --line-numbers
```

### Ipset

```bash
ipset list traf_guard_government | head -20
ipset list traf_guard_antiscanner | head -20
ipset list allowed_mobile_443 | head -20
```

### Systemd

```bash
systemctl status mobile443-update.service --no-pager
systemctl status mobile443-update.timer --no-pager
systemctl list-timers --all | grep mobile443
```

### Telegram monitor

```bash
systemctl status mobile443-monitor.service --no-pager
systemctl status mobile443-stats.timer --no-pager
journalctl -u mobile443-monitor.service -f --no-pager
```

## 🗑️ Удаление

Обычный режим:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) remove
```

Block-only:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh) remove
```

Удаляются только сущности проекта:

- `FILTER_MOBILE_443`
- `TRAF_GUARD_PRECHECK`
- ipset проекта
- systemd unit проекта
- `/opt/mobile443`
- `/var/lib/mobile443`

## 📁 Основные файлы

```text
/opt/mobile443/config.conf
/opt/mobile443/asns.conf
/opt/mobile443/lists/government_networks.list
/opt/mobile443/lists/antiscanner.list
/var/lib/mobile443/prefixes.txt
/usr/local/sbin/mobile443-common.sh
/usr/local/sbin/mobile443-update.sh
/usr/local/sbin/mobile443-apply-cache.sh
```
