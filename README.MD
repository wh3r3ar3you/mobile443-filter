# 🛡️ mobile443 v0.5

Фильтр для VPN-портов, который теперь работает в два слоя:

1. 🚫 `traf_guard` сначала дропает IP из blocklist
2. 📶 затем `mobile allowlist` пускает только IP из мобильных ASN + точечных сетей
3. ⛔ всё остальное на указанных портах дропается

При этом обычный режим установки по-прежнему умеет:

- 🤖 уведомлять пользователей в Telegram о блокировке
- 📊 отправлять ежедневную статистику админу
- 🚨 отправлять админу alert при попытке доступа с IP из `traffic-guard` списков
- 🌐 искать пользователя через `xray access.log`
- 🧩 ходить в панель Remnawave за Telegram ID

А после установки на сервере доступна интерактивная консоль `mobile443` —
управление фильтром без переустановки: обновление списков, точечные исключения,
диагностика, статистика и настройка Telegram/Remnawave. См. раздел «🎛 Консоль
управления mobile443» ниже.

## ✨ Что изменилось в v0.5

- `AS12389` (Ростелеком) исключён из полного пула ASN — весь анонс ASN
  слишком широкий и затрагивает домашний проводной broadband, а не только
  мобильные сети
- вместо него добавлен курируемый список из 31 точечной сети в
  `static_networks.conf` — он всегда подмешивается в mobile-allowlist
  независимо от текущего набора ASN
- исключённые ASN сохраняются в `asns_excluded.conf` и их можно вернуть в
  пул одной командой из консоли `mobile443`
- добавлен `excluded_networks.conf` — точечный бан-лист сетей, которые
  никогда не попадут в allowlist, даже если их анонсирует один из ASN пула
- добавлена интерактивная консоль **`mobile443`** (устанавливается в
  `PATH`, запускается командой `sudo mobile443`) — обновление списков,
  возврат ASN, управление исключениями, статус/диагностика, статистика и
  настройка Telegram/Remnawave прямо на сервере
- `install.sh` / `install_block_only.sh` больше не требуют вручную ставить
  `curl` — используется `curl`, затем `wget`, и только если нет ни того,
  ни другого — скрипт сам поставит `curl` через `apt`

## ✨ Что изменилось в v0.4

- обновлена логика пользовательских Telegram-уведомлений
- добавлена возможность задать кастомный текст уведомления с подстановкой `{ip}`
- добавлен расширенный режим извлечения Telegram ID из `username` с произвольным разделителем
- изменена логика работы с `xray access.log`: первое подключение логируется, затем IP попадает во временный deferred block
- добавлен ASN `AS35816` (Sevastar)
- добавлены ASN `AS42842` (Beeline/vimpelcom), ASN `AS47204` (Luhansk mobile), ASN `AS31499` (Мотив телеком)

## ✨ Что изменилось в v0.3.1

- восстановлен полный дефолтный список мобильных ASN
- возвращены `AS16345`, `AS205638` и `AS214257`
- Добавлены ASN Волна-мобайл ( оператор мобильной связи в Крыму и Севастополе )

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

## 🧬 ASN, точечные сети и исключения

Mobile-allowlist строится не только из ASN. Есть четыре файла в
`/opt/mobile443/`, которые вместе формируют финальный список сетей:

| Файл | Назначение |
|---|---|
| `asns.conf` | Активный пул ASN — для каждого раз в сутки запрашиваются анонсированные префиксы у RIPEstat |
| `asns_excluded.conf` | ASN, исключённые из пула (весь анонс ASN слишком широкий) — хранятся для быстрого возврата |
| `static_networks.conf` | Курируемые вручную сети — **всегда** подмешиваются в allowlist, независимо от пула ASN |
| `excluded_networks.conf` | Точечный бан-лист — сети отсюда никогда не попадут в allowlist, даже если их анонсирует ASN из пула |

При каждом обновлении списков (`mobile443-update.sh`) порядок такой:

```text
1. Собрать анонсированные префиксы всех ASN из asns.conf (RIPEstat)
2. Подмешать сети из static_networks.conf
3. Отсортировать и отфильтровать по формату CIDR
4. Вычесть сети, попадающие под excluded_networks.conf
5. Загрузить результат в ipset allowed_mobile_443
```

### Почему AS12389 (Ростелеком) исключён

Полный анонс `AS12389` включает не только мобильные сети Ростелекома, но и
огромный объём домашнего проводного broadband — что делает allowlist
слишком широким. Поэтому ASN исключён и заменён точечным списком из 31
сети в `static_networks.conf`. Этот же механизм подходит для любых других
операторов в будущем: исключить широкий ASN в `asns_excluded.conf` и
добавить точный список сетей в `static_networks.conf`.

Управлять этим удобнее всего через консоль `mobile443` (см. ниже), но при
желании файлы можно редактировать вручную — просто не забудьте после
изменений запустить `mobile443-update.sh` или `sudo mobile443` → «Обновить
списки сейчас».

## ⚙️ Режимы установки

Команда сама использует `curl`, а если его нет — `wget`. Устанавливать
что-либо руками перед запуском не нужно. Если на сервере нет ни `curl`,
ни `wget` одновременно (случай крайне редкий), поставьте один из них:
`apt install -y curl`.

### 1. Обычный режим

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh || wget -qO- https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh)
```
❗ Первичное обновление списков может занять от 2 до 5 минут ❗

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
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh || wget -qO- https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) update
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
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh || wget -qO- https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh)
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
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh || wget -qO- https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh) update
```

Здесь тоже используется безопасный путь: `backup -> remove -> reinstall`.

### 📝 3. Включение логов на ноде

> **Важно:** Если у вас включены уведомления для пользователей, необходимо обязательно настроить логирование на вашей ноде.

Для этого выполните два простых шага:

**Шаг 1: Обновление `docker-compose.yml`**
Добавьте следующий маппинг томов в конфигурацию вашей ноды:

```yaml
        volumes:
            - '/var/log/remnanode:/var/log/remnanode'
```

**Шаг 2: Обновление конфигурации Xray**
Добавьте или обновите блок логов в конфигурационном файле Xray:

```json
  "log": {
      "access": "/var/log/remnanode/access.log",
      "loglevel": "info"
  }
```

## 📱 Telegram и Remnawave

В обычном режиме всё осталось как раньше.

Дополнительно в `v0.4`:

- можно выбрать источник Telegram ID:
  - `telegramId` из API Remnawave
  - последнюю часть `username` после `_`
  - последнюю часть `username` после своего разделителя, либо весь `username` целиком
- можно указать своё сообщение пользователю при блокировке
- в кастомном сообщении поддерживается переменная `{ip}` и `\n` для переноса строки

### Как определяется пользователь

1. `iptables` логирует немобильное подключение
2. соединение кратковременно пропускается до `xray`, чтобы запись успела появиться в `access.log`
3. по IP ищется пользователь в `xray access.log`
4. из лога берётся `email` / ID пользователя
5. IP добавляется во временный `deferred block`
6. по ID идёт запрос в Remnawave API
7. из ответа берётся Telegram ID
8. пользователю уходит уведомление о блокировке

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

## 🎛 Консоль управления `mobile443`

После установки (полный или block-only режим) в `PATH` появляется команда:

```bash
sudo mobile443
```

Это интерактивное меню для управления фильтром без переустановки и без
ручного редактирования конфигов:

```text
╔═══════════════════════════════════════════════╗
║             mobile443 — консоль                ║
╚═══════════════════════════════════════════════╝

  1) 🔄 Обновить списки сейчас
  2) ↩️  Вернуть ASN в полный пул
  3) 🚫 Управление исключениями сетей
  4) 🩺 Статус и диагностика
  5) 📊 Статистика (как отправляет бот)
  6) 🤖 Настроить Telegram / Remnawave
  7) 🗑️  Удалить mobile443
  0) Выход
```

### Что делает каждый пункт

1. **Обновить списки сейчас** — запускает `mobile443-update.service`
   вручную, не дожидаясь полуночи, и показывает последние строки журнала.
2. **Вернуть ASN в полный пул** — показывает ASN из `asns_excluded.conf`
   (например, `AS12389`) и по выбору переносит его обратно в `asns.conf`.
3. **Управление исключениями сетей** — добавляет или удаляет записи в
   `excluded_networks.conf`: такие сети никогда не попадут в
   mobile-allowlist, даже если их анонсирует ASN из пула.
4. **Статус и диагностика** — сводка по конфигу, размерам ASN/сетевых
   пулов, счётчикам `ipset`, правилам `iptables` и статусам systemd-юнитов
   в одном экране (то же самое, что раньше приходилось собирать вручную
   командами из раздела «🔍 Команды проверки» ниже).
5. **Статистика (как отправляет бот)** — тот же отчёт, что
   `mobile443-stats.service` раз в день шлёт админу в Telegram
   (блокировки, уникальные IP, топ IP, размеры списков), но по запросу,
   в любой момент, прямо в терминале. Можно сразу же отправить этот отчёт
   в Telegram, не дожидаясь таймера.
6. **Настроить Telegram / Remnawave** — если при установке интеграция не
   была включена (или её нужно перенастроить), этот пункт задаёт те же
   вопросы, что и `install.sh` (токен бота, admin ID, панель Remnawave,
   API токен, источник Telegram ID, кастомное сообщение, путь к
   `access.log`), сохраняет их в `config.conf` и разворачивает
   `mobile443-monitor.service` / `mobile443-stats.timer` без полной
   переустановки.
7. **Удалить mobile443** — то же самое, что `install.sh remove`, только
   офлайн и без повторного скачивания скрипта: снимает `iptables`/`ipset`,
   останавливает и удаляет systemd-юниты, чистит `/opt/mobile443` и
   `/var/lib/mobile443`, и в конце удаляет саму консоль.

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
TG_ID_SOURCE="telegramId|username|username_custom"
TG_CUSTOM_MESSAGE="..."
TG_USERNAME_SEPARATOR="_|:|-|..."
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
ipset list mobile443_deferred_block | head -20
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

Быстрее всего — прямо на сервере: `sudo mobile443` → пункт **7) Удалить
mobile443** (не требует сети и повторного скачивания скрипта).

Либо через установщик:

Обычный режим:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh || wget -qO- https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) remove
```

Block-only:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh || wget -qO- https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh) remove
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
/opt/mobile443/asns_excluded.conf
/opt/mobile443/static_networks.conf
/opt/mobile443/excluded_networks.conf
/opt/mobile443/lists/government_networks.list
/opt/mobile443/lists/antiscanner.list
/var/lib/mobile443/prefixes.txt
/usr/local/sbin/mobile443
/usr/local/sbin/mobile443-common.sh
/usr/local/sbin/mobile443-update.sh
/usr/local/sbin/mobile443-apply-cache.sh
```
