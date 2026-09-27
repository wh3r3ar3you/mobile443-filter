# 🛡️ mobile443 v0.9

> ⚠️ **Список сетей Ростелекома (замена `AS12389`) пока в режиме
> тестирования.** 31 сеть в `static_networks.conf` — это стартовый
> курируемый набор, а не финальный. Если знаете более точные/актуальные
> мобильные сети оператора (или нашли баг в другой части замены ASN) —
> присылайте pull request, будем рады.

> ℹ️ **С v0.7 фильтр работает на `nftables`** — своя таблица
> `ip mobile443`, которую не трогают ни Docker, ни UFW.

Фильтр для VPN-портов, который работает в два слоя:

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

## ✨ Что изменилось в v0.9

### 🚀 Параметры установки

Все ответы установщика теперь можно передать флагами — удобно раскатывать
фильтр на пачку серверов одной командой, без ответов на вопросы:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) install \
  --ports "443 8443" --backend nftables --no-telegram -y
```

- 🏷 каждый флаг отвечает на свой вопрос; всё, что не передано, спрашивается
  как раньше
- 🤐 `-y` / `--yes` — не задавать вопросов вообще, незаданное берётся по
  умолчанию
- 🖥 без терминала (`ssh host 'bash -s'`, ansible, cloud-init) установщик сам
  переходит в неинтерактивный режим — pty-обёртки больше не нужны
- 🌱 те же значения можно передать переменными окружения `M443_*`
- ➕ `--manual-allow` сразу кладёт доверенные адреса в `manual_allow.conf`
- 🛑 некорректное значение останавливает установку до каких-либо изменений

Полный список — в разделе «🚀 Установка с параметрами» ниже.

## ✨ Что изменилось в v0.8

### 🧹 Ревизия мобильного allowlist (MTS / Beeline / MegaFon / T2)

Секции «большой четвёрки» прогнаны через несколько источников
(RIPEstat, RIPE DB `aut-num`, PeeringDB, bgpview) плюс эмпирическая
проверка реальных мобильных IP. Из пула убраны ASN, которые ничего не
давали или, наоборот, **ослабляли** фильтр:

| Категория | ASN | Почему убрали |
|---|---|---|
| 💀 Мёртвые (0 анонсов) | `48615` `47218` `43841` `42891` `41976` `31268` `25290` `20663` `12396` | не анонсируют ни одного префикса — в наборе давали пустоту |
| ☁️ ЦОД / облако | `8263` `24866` (Cloud-Megafon), `202804` (Inplat) | это хостинг-диапазоны — ровно те сети, откуда идут сканеры и активные пробы. Держать их в allowlist = дыра в самой логике фильтра |
| 🏠 Чистый fixed | `6854` (Synterra) `50928` (Syntsib) `29648` (Comline) `34552` (TKUral) `20632` (PeterStar) `16043` (Samara-Telecom) `42842` (Helios-TV) `30922` (MTS-FBN-Siberia) `13174` (MTSNet) `21365` (Inteleca) `34351` (MTS-Ivanovo) | проводной broadband / ТВ / магистраль, а не мобильные подписчики |
| 🌍 Иностранный | `13116` | Tele2 **Sverige AB** — шведское материнское юрлицо, не РФ-мобайл |
| ♊ Дубликат | `48092` | было указано дважды |

Итог по «четвёрке» — **20 ASN вместо 44**:

- **MTS:** `8359`
- **Beeline:** `3216`, `16345` — мобильный CGNAT `3216` подтверждён по реальному IP (`81.9.0.0/17`, проверка с телефона)
- **MegaFon:** GSM-филиалы + Yota/SonicDuo — `31133` `47395` `35298` `31224` `31213` `31208` `31205` `31195` `31163` `25159`
- **T2:** `12958` `15378` `42437` `48092` `48190` `41330` `39374`

> ℹ️ ASN-фильтр = «сети мобильных операторов», а **не** «100 % сотовые IP»:
> у MTS/MegaFon/Beeline мобайл и fixed сидят в одних ASN и на уровне ASN
> не разделяются. Для строгого cellular-only нужен префиксный источник
> (например connection-type = Cellular), списком ASN это не решается.

### ➕ Добавлены операторы

- 📵 **Phoenix** (ДНР) — `214721`, `204108`
- 📵 **Севтелеком** (Севастополь) — `59833`, `47203`

Регионально-специфичные мобильные сети, которых раньше не было в пуле.
Остальные операторы (Miranda, Sberbank-Telecom, Sevastar, T-mobile/Alfa,
Volna-Mobile, MCS, MOTIV) — без изменений.

### 🔁 Как это накатывается

Список ASN лежит в `asns.conf`. После правки файла набор префиксов
пересобирается из RIPEstat и применяется **одной атомарной nft-транзакцией**
(`mobile443-update.sh` или консоль `mobile443` → «Обновить списки») с
предохранителями: обновление отклоняется, если суммарно префиксов меньше
500 или их стало меньше 70 % от прошлого набора. `static_networks.conf`,
`manual_allow.conf` и пользовательские исключения при этом не затрагиваются.

## ✨ Что изменилось в v0.7

### 🔀 Переход на nftables

Весь фильтр переехал с `iptables + ipset` на **`nftables`** — собственная
таблица `ip mobile443`, которую не трогают ни Docker, ни UFW:

- правила применяются **одной атомарной транзакцией** `nft -f`: если
  что-то не применилось, старые правила остаются в силе (раньше набор
  правил собирался по одной команде и мог остаться в полусобранном виде)
- вход в фильтр — свои hook-цепочки с `priority -10`, то есть **раньше**
  цепочек Docker и UFW. Костыли с `DOCKER-USER` больше не нужны: Docker
  физически не может «перекрыть» наши правила своими
- в hook `forward` порт назначения матчится **до DNAT**
  (`ct original proto-dst`), поэтому проброс портов вида `10443:443`
  фильтруется корректно
- списки грузятся в nft-наборы с `flags interval` + `auto-merge`
  (объединение перекрывающихся сетей), блокировки монитора — в набор с
  `flags timeout` и **переживают пересборку правил**
- лимит LOG-строк — per-IP (`dynamic`-набор), один активный поток больше
  не «съедает» бюджет логирования остальных

При обновлении старые `iptables`-цепочки (`FILTER_MOBILE_443`,
`TRAF_GUARD_PRECHECK`) и `ipset`-наборы автоматически вычищаются.

### 📵 Работа без логов xray (immediate-режим)

Персональные Telegram-уведомления пользователю требуют `xray access.log`:
соединение пропускается до xray, monitor находит по IP email пользователя
и только потом блокирует. **Если логи xray отключены, блокировать было
нечем — и Wi-Fi-подключения проходили свободно.**

Теперь режим выбирается автоматически:

| Режим | Когда включается | Как блокирует |
|---|---|---|
| `immediate` | логи xray отключены (`XRAY_ACCESS_LOG` пуст) или Telegram не настроен | немобильные IP дропаются **сразу** в nftables |
| `deferred` | Telegram настроен **и** указан путь к `access.log` | первое соединение пропускается до xray, monitor опознаёт пользователя, блокирует IP и шлёт уведомление |

Установщик и консоль теперь прямо спрашивают, включено ли логирование
xray, и не заставляют выдумывать путь к несуществующему файлу. В
`immediate`-режиме продолжают работать админ-алерты Traffic Guard и
статистика. Текущий режим виден в `sudo mobile443` → «Статус и
диагностика».

### 🩹 Прочие исправления «фильтр стоит, а не блокирует»

- **Monitor больше не оставляет фильтр открытым.** В `deferred`-режиме он
  отказывался блокировать IP, если не нашёл его в `access.log` — то есть при
  зондах без аутентификации, xray без `email` в логе или запоздавшей записи
  не блокировалось ничего. Теперь такой IP блокируется на 10 минут без
  уведомления (fail-closed), опознанный — на час с уведомлением
- **Настройка Telegram через консоль перезапускает monitor.** Раньше
  `enable --now` на уже запущенном сервисе ничего не делал, и monitor
  продолжал жить со старым конфигом (`ENABLE_TELEGRAM=false`) — т.е. так
  и не начинал блокировать
- **Monitor обрабатывает события параллельно** (с лимитом и дедупликацией
  по IP): раньше очередь стояла из-за `sleep`/`curl` в обработчиках, и при
  потоке событий блокировка отставала на минуты
- **Путь к `xray access.log` валидируется** при установке и в консоли, а
  monitor при старте предупреждает (и шлёт alert админу), если указанный
  лог недоступен — раньше идентификация молча отключалась навсегда

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
- добавлен `manual_allow.conf` — обратный механизм: сети оттуда ВСЕГДА
  получают `ACCEPT`, раньше traf_guard-блоклистов и раньше проверки
  мобильного ASN — для доверенных адресов (например, свой домашний IP)
- добавлена интерактивная консоль **`mobile443`** (устанавливается в
  `PATH`, запускается командой `sudo mobile443`) — обновление списков,
  возврат ASN, управление исключениями и ручным allow-листом,
  статус/диагностика, статистика и настройка Telegram/Remnawave прямо на
  сервере; вся навигация в меню — цифрами, без буквенных горячих клавиш
- `mobile443-monitor.service` (сбор статистики блокировок: счётчики, топ
  IP) теперь ставится и работает всегда, в обоих режимах установки —
  раньше он поднимался только при включённом Telegram. Сама отправка в
  Telegram (`mobile443-stats.timer`) как и раньше требует настроенной
  интеграции, но смотреть статистику через консоль можно и без неё
- исправлены три бага, найденные при первом реальном прогоне на сервере:
  - при исключении `AS12389` из уже работающей установки кеш
    `mobile allowlist` теперь сбрасывается, иначе safe-check в
    `mobile443-update.sh` принимал ожидаемое уменьшение количества
    префиксов (например, с ~5700 до ~2600) за аварийное падение и
    отказывался обновляться
  - миграция `AS12389` (`strip_legacy_rostelecom_from_asns`) больше не
    роняет установщик через `set -e`, если мигрировать уже нечего
    (свежая установка или повторный запуск после миграции)
  - `mobile443-monitor.sh` больше не падает при отключённом Telegram —
    раньше он писал статистику блокировки и тут же завершался с ошибкой
    из-за `return` без явного кода после проверки `ENABLE_TELEGRAM`
- traffic-guard списки (`government_networks.list`, `antiscanner.list`)
  теперь при недоступности `raw.githubusercontent.com` (таймауты
  встречаются на некоторых хостах/сетях) автоматически пробуют зеркало
  на jsDelivr (`TRAF_GUARD_BASE_URL_FALLBACK`), прежде чем считать
  обновление неудавшимся
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

Всё живёт в одной таблице `ip mobile443`:

| Объект | Назначение |
|---|---|
| `set manual_allow` | ручной allow-лист (всегда `accept`) |
| `set mobile_allow` | мобильный allowlist из ASN |
| `set tg_government` | traffic-guard: госсети |
| `set tg_antiscanner` | traffic-guard: сканеры |
| `set deferred_block` | блокировки от монитора (с таймаутом) |
| `set log_limit` | per-IP лимит LOG-строк |
| `chain prefilter_input` | hook `input`, priority `-10` |
| `chain prefilter_forward` | hook `forward`, priority `-10` (матч порта до DNAT) |
| `chain filter443` | сама логика фильтрации |

### Полный режим (`immediate` — логи xray отключены)

```text
prefilter_input:   tcp/udp dport {порты}            -> jump filter443
prefilter_forward: ct original proto-dst {порты}    -> jump filter443
filter443: ip saddr @manual_allow    -> accept
filter443: ip saddr @tg_government   -> log + drop
filter443: ip saddr @tg_antiscanner  -> log + drop
filter443: ip saddr @mobile_allow    -> accept
filter443:                              log + drop
```

Иными словами:

- если IP в `manual_allow.conf` -> `accept` сразу, минуя всё остальное
- если IP в `government_networks.list` -> `drop`
- если IP в `antiscanner.list` -> `drop`
- иначе если IP входит в мобильный allowlist -> `accept`
- иначе -> `drop`

### Полный режим (`deferred` — Telegram + доступный access.log)

```text
filter443: ip saddr @manual_allow    -> accept
filter443: ip saddr @tg_government   -> log + drop
filter443: ip saddr @tg_antiscanner  -> log + drop
filter443: ip saddr @mobile_allow    -> accept
filter443: ip saddr @deferred_block  -> drop
filter443:                              log + accept   # monitor опознает и заблокирует
```

Последнее правило пропускает **первое** соединение до xray, чтобы monitor
успел найти пользователя в `access.log` и отправить ему уведомление; сразу
после этого IP уезжает в `deferred_block` и следующие соединения дропаются.
Если пользователя опознать не удалось — IP всё равно блокируется
(на 10 минут вместо часа), фильтр не остаётся открытым.

### Block-only режим

```text
prefilter_input/forward -> jump filter443
filter443: ip saddr @manual_allow    -> accept
filter443: ip saddr @tg_government   -> log + drop
filter443: ip saddr @tg_antiscanner  -> log + drop
filter443:                              (конец цепочки, трафик проходит)
```

Здесь режутся только IP из blocklist, а остальной трафик не ломается.

## 📦 Какие списки используются

По умолчанию:

- `TRAF_GUARD_BASE_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public"`
- `GOV_LIST_URL="${TRAF_GUARD_BASE_URL}/government_networks.list"`
- `ANTISCANNER_LIST_URL="${TRAF_GUARD_BASE_URL}/antiscanner.list"`

Если основной источник (`raw.githubusercontent.com`) недоступен или
таймаутится с хоста сервера (бывает на некоторых сетях), скрипт
автоматически пробует зеркало на jsDelivr:

- `TRAF_GUARD_BASE_URL_FALLBACK="https://cdn.jsdelivr.net/gh/shadow-netlab/traffic-guard-lists@main/public"`
- `GOV_LIST_URL_FALLBACK`, `ANTISCANNER_LIST_URL_FALLBACK` — аналогично, от fallback-базы

Список считается недоступным только если не получилось скачать **ни с
одного** источника — тогда `mobile443-update.sh` завершается с ошибкой
(без изменения текущих правил).

Локально они хранятся в:

- `/opt/mobile443/lists/government_networks.list`
- `/opt/mobile443/lists/antiscanner.list`

Списки:

- очищаются от пустых строк и комментариев
- проходят базовую проверку CIDR
- не падают на единичных битых строках
- обновляются атомарно
- загружаются в nft-наборы одной транзакцией `nft -f` (при ошибке
  остаются прежние правила)

## 🧬 ASN, точечные сети и исключения

Mobile-allowlist строится не только из ASN. Есть пять файлов в
`/opt/mobile443/`, которые вместе формируют финальный список сетей:

| Файл | Назначение |
|---|---|
| `asns.conf` | Активный пул ASN — для каждого раз в сутки запрашиваются анонсированные префиксы у RIPEstat |
| `asns_excluded.conf` | ASN, исключённые из пула (весь анонс ASN слишком широкий) — хранятся для быстрого возврата |
| `static_networks.conf` | Курируемые вручную сети — **всегда** подмешиваются в allowlist, независимо от пула ASN |
| `excluded_networks.conf` | Точечный бан-лист — сети отсюда никогда не попадут в allowlist, даже если их анонсирует ASN из пула |
| `manual_allow.conf` | Ручной allow-лист — сети отсюда ВСЕГДА получают `ACCEPT`, раньше traf_guard и раньше проверки ASN (см. ниже) |

При каждом обновлении списков (`mobile443-update.sh`) порядок такой:

```text
1. Собрать анонсированные префиксы всех ASN из asns.conf (RIPEstat)
2. Подмешать сети из static_networks.conf
3. Отсортировать и отфильтровать по формату CIDR
4. Вычесть сети, попадающие под excluded_networks.conf
5. Загрузить результат в nft-набор mobile_allow
```

`manual_allow.conf` в этот пайплайн не входит — он живёт в отдельном
наборе `manual_allow` и проверяется первым правилом цепочки `filter443`,
до traf_guard-наборов и до `mobile_allow`. Поэтому вычитание через
`excluded_networks.conf` на него не действует — это осознанный «пропуск
несмотря ни на что» для доверенных адресов.

### Почему AS12389 (Ростелеком) исключён

Полный анонс `AS12389` включает не только мобильные сети Ростелекома, но и
огромный объём домашнего проводного broadband — что делает allowlist
слишком широким. Поэтому ASN исключён и заменён точечным списком из 31
сети в `static_networks.conf`. Этот же механизм подходит для любых других
операторов в будущем: исключить широкий ASN в `asns_excluded.conf` и
добавить точный список сетей в `static_networks.conf`.

### Зачем нужен ручной allow-лист

`excluded_networks.conf` и `manual_allow.conf` — противоположности:
первый **убирает** сеть из allowlist (бан), второй **гарантирует** проход
сети через фильтр несмотря ни на что (даже на traf_guard-блоклисты). Это
для доверенных адресов, которым нужен доступ не через мобильный интернет
— например, свой домашний или офисный IP. Для одного IP используйте
маску `/32` (например `203.0.113.5/32`).

⚠️ Осторожно с диапазонами: сеть шире `/32` в этом файле пропустит **весь**
диапазон без проверки ASN.

Управлять всем этим удобнее всего через консоль `mobile443` (см. ниже), но
при желании файлы можно редактировать вручную — просто не забудьте после
изменений запустить `mobile443-update.sh` (или `mobile443-apply-cache.sh`
для `manual_allow.conf`, обновление списков не требуется) либо
воспользоваться самой консолью.

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
- спрашивает порты (или берёт из `--ports`, см. «🚀 Установка с параметрами»)
- по желанию включает Telegram уведомления
- при включённом Telegram спрашивает:
  - токен бота
  - Telegram ID админа
  - адрес панели Remnawave
  - API токен панели
  - источник Telegram ID
  - **включено ли логирование xray**; если да — путь к `access.log`,
    если нет — фильтр работает в `immediate`-режиме (блокировка сразу,
    без персональных уведомлений)

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

Удаление существующей установки:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh || wget -qO- https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) remove
```
`remove`:
- Удаляет все фильтры
- Удаляет все файлы конфигураций
- Отключает systemd юниты


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

### 🚀 Установка с параметрами (раскатка на серверы)

Любой вопрос установщика можно закрыть флагом. Флаги пишутся после действия
(`install` / `update`) и работают с обоими установщиками — `install.sh` и
`install_block_only.sh`:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) install [флаги]
```

| Флаг | Переменная | Вопрос | Значения |
|---|---|---|---|
| `--ports "443 8443"` | `M443_PORTS` | порты фильтрации | через пробел или запятую |
| `--backend nftables` | `M443_BACKEND` | движок файрвола | `nftables` / `iptables` |
| `--lists both` | `M443_LISTS` | traffic-guard листы (block-only) | `both` / `government` / `antiscanner` |
| `--telegram` / `--no-telegram` | `M443_TELEGRAM` | Telegram-уведомления | `y` / `n` |
| `--tg-token TOKEN` | `M443_TG_TOKEN` | токен бота (сам включает Telegram) | |
| `--tg-admin ID` | `M443_TG_ADMIN` | Telegram ID админа | |
| `--panel-url URL` | `M443_PANEL_URL` | адрес панели Remnawave | `https://panel.example.com` |
| `--panel-token TOKEN` | `M443_PANEL_TOKEN` | API-токен панели | |
| `--tg-id-source telegramId` | `M443_TG_ID_SOURCE` | откуда брать Telegram ID | `telegramId` / `username` / `custom` |
| `--tg-separator SEP` | `M443_TG_SEPARATOR` | разделитель в username (`custom`) | можно `""` — username целиком |
| `--tg-message TEXT` | `M443_TG_MESSAGE` | своё сообщение пользователю | HTML, переменная `{ip}` |
| `--xray-log auto` | `M443_XRAY_LOG` | логи xray | `auto` — найти, `none` — выключены, `/путь/access.log` |
| `--manual-allow "IP,CIDR"` | `M443_MANUAL_ALLOW` | — | адреса в `manual_allow.conf` (IP без маски = `/32`) |
| `-y` / `--yes` | `M443_YES=1` | — | не задавать вопросов |
| `-h` / `--help` | — | — | справка |

Правила:

- флаг важнее переменной окружения
- незаданный флаг = обычный вопрос; с `-y` или без терминала — ответ по
  умолчанию (порт `443`, `nftables`, оба листа, Telegram выключен, логи
  xray выключены, стандартное сообщение, Telegram ID из `telegramId`)
- токены в выводе установщика маскируются (`******`)
- для Telegram без вопросов обязательны `--tg-token`, `--tg-admin`,
  `--panel-url` и `--panel-token` — иначе установка сразу остановится
- `--xray-log` с путём к ещё не существующему файлу принимается с
  предупреждением (нода может появиться позже)
- при `update` конфигурация берётся из текущей установки; из флагов
  применяется только `--manual-allow`

Примеры:

```bash
# Эталон флита: порты 443 и 8443, nftables, без Telegram
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) install \
  --ports "443 8443" --backend nftables --no-telegram -y

# С Telegram и персональными уведомлениями
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) install \
  --ports "443 8443" --backend nftables \
  --tg-token "123456:ABC..." --tg-admin 111111111 \
  --panel-url https://panel.example.com --panel-token "eyJ..." \
  --tg-id-source telegramId --xray-log /var/log/remnanode/access.log -y

# Block-only: только government-лист
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh) install \
  --lists government --ports 443 -y

# Добавить доверенный адрес при обновлении
bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) update --manual-allow 203.0.113.5
```

Раскатка на несколько серверов:

```bash
for host in 203.0.113.10 203.0.113.11 203.0.113.12; do
  ssh -p 54777 root@"$host" \
    "bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) install --ports '443 8443' --backend nftables --no-telegram -y"
done
```

Или через переменные окружения — удобно для ansible / cloud-init:

```bash
M443_PORTS="443 8443" M443_BACKEND=nftables M443_TELEGRAM=n M443_YES=1 \
  bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh)
```

### 📝 3. Включение логов на ноде (только для персональных уведомлений)

> **Важно:** Логи нужны **только** если вы хотите, чтобы бот писал
> пользователю о блокировке. Сама фильтрация от логов не зависит: без них
> фильтр работает в `immediate`-режиме и блокирует немобильные IP сразу.
> Если логи xray выключены — просто ответьте «n» на вопрос установщика,
> путь придумывать не нужно.

Для включения логов выполните два простых шага:

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

Работает только в `deferred`-режиме (Telegram настроен **и** указан путь
к `access.log`):

1. `nftables` логирует немобильное подключение
2. соединение кратковременно пропускается до `xray`, чтобы запись успела появиться в `access.log`
3. по IP ищется пользователь в `xray access.log`
4. из лога берётся `email` / ID пользователя
5. IP добавляется во временный `deferred_block` (на 1 час)
6. по ID идёт запрос в Remnawave API
7. из ответа берётся Telegram ID
8. пользователю уходит уведомление о блокировке

⚠️ Если пользователя определить **не удалось** (xray не пишет `email`,
зонд/сканер без аутентификации, запись в логе запоздала) — IP всё равно
блокируется, но на 10 минут и без уведомления (fail-closed).

Если логи xray отключены совсем, этот механизм не используется: фильтр
работает в `immediate`-режиме и блокирует немобильные IP сразу.

### Что получает админ

Статистика — количество блокировок, число уникальных IP, top IP, размер
mobile allowlist, размер traffic-guard списков — **собирается всегда**,
независимо от Telegram, и доступна в любой момент через `sudo mobile443`
→ «Статистика». Раз в день она же отправляется в Telegram, но только
если интеграция настроена.

И отдельно бот шлёт мгновенные Telegram-уведомления админу, если кто-то пытается подключиться с IP из сетей `traffic-guard`.

Дополнительно админ получает оперативный alert, если подключение прилетело из:

- `government_networks.list`
- `antiscanner.list`

Для таких событий используются отдельные лог-префиксы в правилах
`nftables`, а бот шлёт уведомление с IP, портом и причиной блокировки.
Админ-алерты работают в обоих режимах, включая `immediate`.

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
- пересборка nft-наборов и правил одной атомарной транзакцией
  (блокировки в `deferred_block` при этом сохраняются)

Дополнительно всегда ставится `mobile443-monitor.service` — он считает
заблокированные соединения и топ IP в `stats_blocked.txt` независимо от
того, настроен ли Telegram. Эти цифры доступны в любой момент через
`sudo mobile443` → «Статистика» (см. ниже).

Если включён Telegram, дополнительно ставятся:

- `mobile443-stats.service`
- `mobile443-stats.timer`

Они отвечают только за ежедневную отправку того же отчёта в Telegram —
на сам сбор статистики не влияют.

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
  2) ↩️  Вернуть ASN в полный пул и обновить списки
  3) 🚫 Управление исключениями сетей
  4) ✅ Ручной allow-лист (мой IP всегда проходит)
  5) 🩺 Статус и диагностика
  6) 📊 Статистика (как отправляет бот)
  7) 🤖 Настроить Telegram / Remnawave
  8) 🗑️  Удалить mobile443
  0) Выход
```

Все внутренние подменю (например, «добавить/удалить» в пунктах 3 и 4)
тоже управляются цифрами — никаких буквенных горячих клавиш.

### Что делает каждый пункт

1. **Обновить списки сейчас** — запускает `mobile443-update.service`
   вручную, не дожидаясь полуночи, и показывает последние строки журнала.
2. **Вернуть ASN в полный пул и обновить списки** — работает как одна
   кнопка: пока исключён только один ASN (сейчас это `AS12389`), пункт
   меню сразу спрашивает «Вернуть AS12389 целиком в пул и сразу обновить
   списки?» без выбора из списка, переносит его из `asns_excluded.conf`
   обратно в `asns.conf` и тут же запускает `mobile443-update.service`,
   чтобы получить полный анонс ASN. Если исключённых ASN станет несколько
   (для других операторов в будущем), появится выбор нужного — обновление
   списков в любом случае запускается автоматически, без лишних вопросов.
3. **Управление исключениями сетей** — добавляет или удаляет записи в
   `excluded_networks.conf`: такие сети никогда не попадут в
   mobile-allowlist, даже если их анонсирует ASN из пула. Это бан-лист.
4. **Ручной allow-лист** — противоположность пункту 3: добавляет или
   удаляет записи в `manual_allow.conf`, сети из которого ВСЕГДА получают
   `ACCEPT`, раньше traf_guard-блоклистов и раньше проверки мобильного
   ASN. Для одного IP используйте `/32`. После изменения сразу
   перезапускает `mobile443-apply.service`, чтобы применить без ожидания
   таймера.
5. **Статус и диагностика** — сводка по конфигу, текущему режиму
   блокировки (`immediate`/`deferred`), размерам ASN/сетевых пулов,
   наполнению nft-наборов, правилам с счётчиками пакетов и статусам
   systemd-юнитов в одном экране (то же самое, что раньше приходилось
   собирать вручную командами из раздела «🔍 Команды проверки» ниже).
6. **Статистика (как отправляет бот)** — блокировки, уникальные IP, топ
   IP и размеры списков собираются всегда, через `mobile443-monitor.service`,
   независимо от того, настроен ли Telegram. Пункт меню показывает эти
   цифры прямо в терминале по запросу; если Telegram настроен — можно
   сразу же отправить тот же отчёт туда, не дожидаясь ежедневного
   таймера, если нет — просто смотрите здесь.
7. **Настроить Telegram / Remnawave** — если при установке интеграция не
   была включена (или её нужно перенастроить), этот пункт задаёт те же
   вопросы, что и `install.sh` (токен бота, admin ID, панель Remnawave,
   API токен, источник Telegram ID, кастомное сообщение, включены ли логи
   xray и путь к `access.log`), сохраняет их в `config.conf`,
   разворачивает `mobile443-monitor.service` / `mobile443-stats.timer` и
   перезапускает монитор, чтобы он подхватил новый конфиг.
8. **Удалить mobile443** — то же самое, что `install.sh remove`, только
   офлайн и без повторного скачивания скрипта: удаляет таблицу
   `ip mobile443` (плюс legacy-правила `iptables`/`ipset` от версий до
   v0.7), останавливает и удаляет systemd-юниты, чистит `/opt/mobile443` и
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
# Пусто = логи xray отключены = immediate-режим (блокировка сразу).
# Заполнено + ENABLE_TELEGRAM=true = deferred-режим с уведомлениями.
XRAY_ACCESS_LOG="/var/log/remnanode/access.log"
PORTS="443 8443"
TRAF_GUARD_BASE_URL="..."
GOV_LIST_URL="..."
ANTISCANNER_LIST_URL="..."
TRAF_GUARD_BASE_URL_FALLBACK="..."
GOV_LIST_URL_FALLBACK="..."
ANTISCANNER_LIST_URL_FALLBACK="..."
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

### Правила nftables

```bash
nft list table ip mobile443
```

Счётчики пакетов по правилам (главная проверка «работает ли фильтр»):

```bash
nft list chain ip mobile443 filter443
```

### Наборы

```bash
nft list set ip mobile443 mobile_allow | head -20
nft list set ip mobile443 tg_government | head -20
nft list set ip mobile443 manual_allow
nft list set ip mobile443 deferred_block
```

Проверить, попадает ли конкретный IP в набор:

```bash
nft get element ip mobile443 mobile_allow { 203.0.113.7 }
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

- таблица `ip mobile443` целиком (все её цепочки и наборы)
- legacy `FILTER_MOBILE_443` / `TRAF_GUARD_PRECHECK` и ipset от версий до v0.7
- systemd unit проекта
- `/opt/mobile443`
- `/var/lib/mobile443`

Правила других инструментов (Docker, UFW, ваши собственные) не трогаются —
фильтр живёт в своей таблице и удаляется вместе с ней.

## 📁 Основные файлы

```text
/opt/mobile443/config.conf
/opt/mobile443/asns.conf
/opt/mobile443/asns_excluded.conf
/opt/mobile443/static_networks.conf
/opt/mobile443/excluded_networks.conf
/opt/mobile443/manual_allow.conf
/opt/mobile443/lists/government_networks.list
/opt/mobile443/lists/antiscanner.list
/var/lib/mobile443/prefixes.txt
/var/lib/mobile443/ruleset.nft
/usr/local/sbin/mobile443
/usr/local/sbin/mobile443-common.sh
/usr/local/sbin/mobile443-update.sh
/usr/local/sbin/mobile443-apply-cache.sh
```
