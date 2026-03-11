# mobile443

Фильтр подключений к VPN-портам с двумя слоями проверки:

1. `traf_guard` DROP по внешним blocklist
2. `mobile allow` ACCEPT по allowlist мобильных ASN
3. дефолтный `DROP` для остальных IP на фильтруемых портах

В обычном режиме ставятся оба слоя. В `block-only` режиме ставится только `traf_guard` и остальной трафик не режется.

## Схема обработки

Основные сущности:

- `ipset traf_guard_government`
- `ipset traf_guard_antiscanner`
- `ipset allowed_mobile_443`
- `chain TRAF_GUARD_PRECHECK`
- `chain FILTER_MOBILE_443`

Порядок правил в полном режиме:

```text
INPUT/FORWARD/DOCKER-USER -> FILTER_MOBILE_443
FILTER_MOBILE_443 -> TRAF_GUARD_PRECHECK
TRAF_GUARD_PRECHECK: match traf_guard_government -> DROP
TRAF_GUARD_PRECHECK: match traf_guard_antiscanner -> DROP
FILTER_MOBILE_443: match allowed_mobile_443 -> ACCEPT
FILTER_MOBILE_443: LOG
FILTER_MOBILE_443: DROP
```

В `block-only` режиме:

```text
INPUT/FORWARD/DOCKER-USER -> FILTER_MOBILE_443
FILTER_MOBILE_443 -> TRAF_GUARD_PRECHECK
TRAF_GUARD_PRECHECK: match traf_guard_government -> DROP
TRAF_GUARD_PRECHECK: match traf_guard_antiscanner -> DROP
FILTER_MOBILE_443: RETURN
```

## Источники списков

По умолчанию используются:

- `TRAF_GUARD_BASE_URL="https://raw.githubusercontent.com/wh3r3ar3you/traffic-guard-lists/refs/heads/main/public"`
- `GOV_LIST_URL="${TRAF_GUARD_BASE_URL}/government_networks.list"`
- `ANTISCANNER_LIST_URL="${TRAF_GUARD_BASE_URL}/antiscanner.list"`

Локальные файлы:

- `/opt/mobile443/lists/government_networks.list`
- `/opt/mobile443/lists/antiscanner.list`
- `/var/lib/mobile443/prefixes.txt`

Списки очищаются от пустых строк и комментариев, битые CIDR пропускаются с warning, затем ipset пересобирается через временные наборы и `ipset swap`.

## Установка

Обычный режим:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh)
```

Этот режим:

- включает `traf_guard`
- включает mobile ASN allowlist
- опционально включает Telegram/Remnawave уведомления

Block-only режим:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh)
```

С указанием портов:

```bash
PORTS="443 8443 9443" bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh)
```

`install_block_only.sh` не спрашивает про Telegram, Remnawave, API токены и `xray access.log`.
При этом он спрашивает:

- какие traffic-guard листы включить
- какие порты фильтровать через пробел

## Удаление

Полный режим:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) remove
```

Block-only:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh) remove
```

Удаление чистит только сущности проекта:

- chain `FILTER_MOBILE_443`
- chain `TRAF_GUARD_PRECHECK`
- ipset проекта
- systemd unit проекта
- `/opt/mobile443`
- `/var/lib/mobile443`

## Конфиг

Основной конфиг: `/opt/mobile443/config.conf`

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

Типичные режимы:

```bash
# Обычная установка
ENABLE_TRAF_GUARD="true"
ENABLE_MOBILE_ALLOW="true"

# Block-only
ENABLE_TRAF_GUARD="true"
ENABLE_TRAF_GUARD_GOVERNMENT="true"
ENABLE_TRAF_GUARD_ANTISCANNER="true"
ENABLE_MOBILE_ALLOW="false"
ENABLE_TELEGRAM="false"
```

## Systemd

Устанавливаются:

- `mobile443-apply.service`
- `mobile443-update.service`
- `mobile443-update.timer`

Если включён Telegram, дополнительно:

- `mobile443-monitor.service`
- `mobile443-stats.service`
- `mobile443-stats.timer`

`mobile443-update.service`:

- обновляет `government_networks.list`
- обновляет `antiscanner.list`
- обновляет mobile ASN allowlist, если он включён
- пересобирает ipset
- пересобирает `iptables` chain без дублей

## Команды проверки

Проверка правил:

```bash
iptables-save | grep -E 'FILTER_MOBILE_443|TRAF_GUARD_PRECHECK|allowed_mobile_443|traf_guard_'
iptables -L TRAF_GUARD_PRECHECK -n -v --line-numbers
iptables -L FILTER_MOBILE_443 -n -v --line-numbers
```

Проверка ipset:

```bash
ipset list traf_guard_government | head -20
ipset list traf_guard_antiscanner | head -20
ipset list allowed_mobile_443 | head -20
```

Проверка systemd:

```bash
systemctl status mobile443-update.service --no-pager
systemctl status mobile443-update.timer --no-pager
systemctl list-timers --all | grep mobile443
```

Если включён Telegram:

```bash
systemctl status mobile443-monitor.service --no-pager
systemctl status mobile443-stats.timer --no-pager
journalctl -u mobile443-monitor.service -f --no-pager
```

## Файлы

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
