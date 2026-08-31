# Golden VPN: журнал решённых проблем

Актуально на 2026-08-30. Документ фиксирует реальные сбои, найденные при
установке, обновлении и эксплуатации Golden VPN. Секреты, клиентские адреса,
пароли, токены и содержимое профилей намеренно не приводятся.

Статусы:

- **В скрипте** — защита или исправление входит в текущий `install-vpn-stack.sh`.
- **На сервере** — исправлялось эксплуатационной настройкой сервера.
- **На клиенте** — причина находится вне VPN-сервера и требует настройки приложения или ОС.

## Короткая схема диагностики

Не считать тайм-аут доказательством поломки протокола. Проверять по порядку:

1. Сервис запущен и слушает ожидаемый TCP/UDP-порт.
2. Пакеты клиента доходят до сервера и сервер отвечает.
3. Через туннель открывается контрольный URL по доменному имени.
4. Тот же URL открывается с заранее заданным IP.
5. DNS-запрос действительно выходит с VPN-сервера, а не локально у клиента.

Полезный минимум на сервере:

```bash
vpn-install-status status
vpn-install-status log 200
systemctl --failed --no-pager
systemctl is-active hysteria2 awg-quick@awg0 nginx
ss -H -lntup
df -hT /
df -i /
```

## 1. `No space left on device` при создании пользователя

**Симптом**

```text
groupadd: /etc/group... file write error: No space left on device
groupadd: cannot lock /etc/group
```

**Причина**

Корневой раздел был заполнен на 100%, при этом inode оставались свободны. На
проверенных серверах основными потребителями оказались Docker JSON log,
`syslog`, Grafana, x-ui и journald. Ошибка `groupadd` была следствием, а не
проблемой `/etc/group`.

**Диагностика**

```bash
df -hT /
df -i /
journalctl --disk-usage
du -xhd1 /var /root /opt 2>/dev/null | sort -h
find /var /root /opt -xdev -type f -size +100M \
  -printf '%12s  %p\n' 2>/dev/null | sort -nr | head -30
lsof +L1
```

**Результат**

После освобождения места системные файлы снова создавались нормально. В Golden
ограничены journald и ротация собственных логов. Сторонние Docker/Grafana/x-ui
логи нужно ограничивать отдельно. **Статус: в скрипте + эксплуатация.**

## 2. `ssh-keyscan`: unsupported KEX method

**Симптом**

```text
choose_kex: unsupported KEX method sntrup761x25519-sha512@openssh.com
```

**Причина**

Устаревший Windows OpenSSH-клиент не понимал первый алгоритм, объявленный новым
OpenSSH-сервером. Это не означало поломку SSH на VPS.

**Решение**

Обновить Windows OpenSSH либо получить и сверить fingerprint обычным `ssh` с
актуальным клиентом. Fingerprint добавляется только после независимой сверки.
**Статус: на клиенте.**

## 3. acme.sh падал с `shift: can't shift that many`

**Симптом**

Ручной запуск скачанного install-wrapper с некорректным аргументом email
завершался внутри `acme.sh` ошибкой `shift`.

**Причина**

Смешивались синтаксис web-installer и синтаксис установленного `acme.sh`.
Переменная email передавалась как произвольный positional argument.

**Результат**

Текущий Golden устанавливает acme.sh контролируемым способом, регистрирует
аккаунт отдельной командой и валидирует ASCII email до обращения к CA. Не
повторять старую команду вида:

```text
HOME=/root sh /tmp/install-acme.sh email="${EMAIL}"
```

**Статус: в скрипте.**

## 4. `The domain is not a cert name`

**Симптом**

```text
The domain 'example.org' is not a cert name
Cannot find path: '/root/.acme.sh/example.org_ecc'
```

**Причина**

`--install-cert` запускался до успешного `--issue`, с другим CA/account state
или без совпадающего `--ecc`. Установка сертификата не выпускает его.

**Правильный порядок**

1. Выпустить сертификат DNS-01 для точного `DOMAIN`.
2. Убедиться, что появился каталог `<DOMAIN>_ecc`.
3. Выполнить `--install-cert -d "$DOMAIN" --ecc`.
4. Установить fullchain/key в `/etc/letsencrypt/live/$DOMAIN/`.
5. Проверить сертификат и приватный ключ до reload nginx/Hysteria.

Golden выполняет этот порядок автоматически. **Статус: в скрипте.**

## 5. ZeroSSL: `502 Bad Gateway`, nonce retries и EAB errors

**Симптом**

DNS challenge создавался, после чего CA отвечал `502`, `403`, ошибкой EAB или
`Could not get nonce` до исчерпания повторов.

**Причина**

Внешний сбой ZeroSSL/EAB API, а не nginx и не открытый порт 80. Для DNS-01 порт
80 не требуется.

**Результат**

ZeroSSL остаётся основным CA, но Golden безопасно переключается на Let's Encrypt
DNS-01, если ZeroSSL недоступен. Сохранённые env/log позволяют повторить stage2
вручную. **Статус: в скрипте.**

## 6. Resume-install: `storage_hint: command not found`

**Симптом**

После перезагрузки чтение `/etc/golden-vpn-installer/install.env` пыталось
исполнить часть значения как shell-команду.

**Причина**

Значения с пробелами/служебными символами сохранялись без полноценного
shell-quoting.

**Результат**

Сохранение installer env экранирует каждое значение; секреты не печатаются.
Stage2 читает только ожидаемые переменные. **Статус: в скрипте.**

## 7. Мерцающий лог и зависание на 96% cleanup

**Симптомы**

- полный install log постоянно перерисовывал терминал;
- установка визуально оставалась на `96% Cleaning one-time resume state`;
- при неудаче было непонятно, какую команду запускать дальше.

**Результат**

Интерактивный вход показывает компактный текущий этап, progress bar и только
полезные предупреждения. Полный лог остаётся в отдельном файле. One-shot unit
удаляется после первой попытки, но env/log/status сохраняются при ошибке:

```bash
vpn-install-status status
vpn-install-status log 200
bash /root/vpn-stack-resume/install-vpn-stack.sh install
```

**Статус: в скрипте.**

## 8. Helper создавал ключ, но затем выполнял `cat: PHONE`

**Симптомы**

```text
cat: PHONE: No such file or directory
cat: /root/vpn-keys/.../KEY-NAME.txt: No such file or directory
```

**Причина**

Шаблон helper-скрипта смешивал heredoc, placeholder и буквальное имя примера.
Часть шаблона выполнялась во время установки, а не при вызове helper.

**Результат**

Helper принимает фактический positional argument, валидирует имя, сначала
записывает файл с правами `0600`, затем выводит тот же ключ и QR в консоль.
Литеральные `PHONE`/`KEY-NAME` больше не исполняются. **Статус: в скрипте.**

## 9. Обновление не должно удалять профили

**Риск**

Повторный clean install генерирует новую серверную идентичность и не является
обновлением рабочего сервера.

**Результат**

Для рабочих серверов используются только:

```bash
./install-vpn-stack.sh upgrade-check
./install-vpn-stack.sh upgrade
```

Перед применением создаётся root-only backup и secret-free manifest. Xray,
Hysteria, AWG, client files и subscriptions сравниваются byte-for-byte. При
расхождении upgrade считается неуспешным. Есть явный `upgrade-rollback`.
**Статус: в скрипте.**

## 10. AWG: handshake есть, но DNS/трафика нет

**Найденные причины**

- неверные forwarding/NAT/firewall rules;
- DNS `8.8.8.8`, который в некоторых клиентских сетях перестал отвечать
  корректно;
- слишком большой MTU и отсутствие MSS normalization на проблемном маршруте;
- устаревшие AWG-параметры или несовместимый клиент.

**Результат**

Golden включает forwarding/NAT, фиксирует внешний endpoint на `443/udp`,
поддерживает AWG 3.1, безопасный MTU/PMTU flow и сохраняет идентичность ключей
при tuning migration. Базовый DNS в выдаваемых профилях — `1.1.1.1`, но при
клиентской DNS-утечке открытый DNS всё равно может быть перехвачен провайдером.
**Статус: в скрипте + на клиенте.**

## 11. Hysteria2: тайм-аут долгоживущей UDP-сессии

**Симптом**

Подключение устанавливалось, затем все TCP streams одновременно получали
`timeout: no recent network activity`. Сам сервер при этом быстро открывал те же
сайты.

**Причина**

Деградация/фильтрация постоянного UDP-потока на одном порту клиентской сетью.
Это отличалось от блокировки сайта на VPS.

**Результат**

Salamander использует port hopping:

```text
8443,20000-50000/udp
```

Старый `8443/udp` сохранён для совместимости, включён
`disablePathMTUDiscovery: true`, а существующие usernames/passwords/obfs не
меняются. Hiddify JSON сохраняет multi-port настройки Hysteria. **Статус: в скрипте + на сервере.**

## 12. Hysteria работает, но YouTube показывает «Нет Интернета»

**Подтверждённые наблюдения**

- VPN egress соответствовал публичному адресу US-сервера;
- YouTube по заранее указанному IP через тот же туннель отвечал HTTP `204`;
- `i.ytimg.com` и `youtubei.googleapis.com` разрешались;
- только `youtube.com` через `1.1.1.1`/`8.8.8.8` получал `NXDOMAIN`;
- серия тестовых DNS-запросов не появилась на внешнем интерфейсе US-сервера;
- DoH `https://1.1.1.1/dns-query` через туннель возвращал настоящий адрес.

**Причина**

Старый клиент на проверенной Windows-машине выпускал обычный DNS вне Hysteria TUN.
Открытый UDP/53 перехватывался ТСПУ; с 26 августа 2026 для отдельных доменов
возвращался поддельный `NXDOMAIN`. Замена одного открытого DNS IP на другой не
помогала.

**Решение для Brave**

Открыть `brave://settings/security`, включить Secure DNS, выбрать custom provider
и указать:

```text
https://1.1.1.1/dns-query
```

Затем полностью перезапустить Brave и очистить системный кэш:

```powershell
ipconfig /flushdns
```

Это клиентский обход. Перевыпуск Hysteria-профиля здесь ничего не меняет.
**Статус: на клиенте, решено.**

## 14. P2P забивает интерактивный трафик

**Наблюдение**

Во время диагностики одного профиля сервер получал десятки BitTorrent/P2P
подключений к случайным адресам и портам, тогда как браузерный запрос к YouTube
не доходил. CPU/RAM/conntrack сервера оставались в норме.

**Вывод**

Перед оценкой качества видео остановить torrent/P2P и повторить тест. Серверный
тайм-аут до случайного peer не доказывает поломку Hysteria или сайта.
**Статус: эксплуатационная рекомендация.**

## 15. Сертификат: срок и автоматическое продление

Сертификат действует в пределах срока, выданного CA; точную дату показывает:

```bash
openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" \
  -noout -dates -issuer -subject
```

acme.sh планирует продление заранее. Golden устанавливает renewal hook для
reload nginx и уведомления, а `vpn-cert-notify.timer` ежедневно проверяет срок с
дедупликацией порогов 30/14/7/3/1/0 дней. **Статус: в скрипте.**

## 16. Telegram-выгрузка была неполной

**Проблема**

Первый export содержал только AWG, хотя требовались все действующие типы ключей
одним документом.

**Результат**

`inventory --type all --send` создаёт один typed SQLite bundle с AWG, Trojan и
Hysteria. Issuer bot только выпускает/экспортирует ключи и сообщает о TLS;
`vpn-seller` остаётся владельцем customer mapping, уведомлений и аварийной
замены. **Статус: в скрипте.**

## 17. Автообновления могли сломать рабочий контур

**Решение**

- AWG обновляется только официальными пакетами с сохранением rollback packages.
- Xray/Hysteria обновляются только со stable channel.
- Перед рестартом проверяются конфиги; после — sockets/listeners/services.
- При неуспехе восстанавливается предыдущий binary/config state.
- Mimic/kernel-module packages не обновляются unattended.
- Ежедневная перезагрузка сервера отключена.
- Если точный rollback-пакет исчез из репозитория, обновление безопасно
  пропускается без изменения пакетов и без ложного состояния `failed` у unit.

Пользовательские профили при engine update не ротируются. **Статус: в скрипте.**

## 18. Что не считать исправлением

- Перевыпускать ключ, если transport работает, а сломан клиентский DNS.
- Запускать clean `install` поверх рабочего сервера.
- Удалять lock-файл apt/dpkg вместо ожидания владельца lock.
- Отключать проверку конфигов или rollback ради успешного exit code.
- Делать вывод о блокировке VPS только по traceroute со звёздочками: многие
  маршрутизаторы не отвечают на TTL-expired, продолжая передавать трафик.
- Печатать токены, private keys, passwords или полные профили в диагностические
  логи и отчёты.

## 19. Когда обновлять этот журнал

Добавлять запись после подтверждения причины измерением. Для каждой новой записи
фиксировать:

1. точный симптом;
2. минимальный воспроизводимый тест;
3. подтверждённую причину;
4. исправление и rollback;
5. способ проверки результата;
6. требуется ли изменение Golden Script или это клиентская/операторская проблема.

## 20. AWG: высокая скорость VPS, но низкая скорость туннеля

**Симптом**

Прямая проверка сети VPS показывала сотни Мбит/с, Hysteria2 и Trojan также
работали быстро, но AWG особенно сильно проседал на передаче от клиента к
серверу. Смена MTU с `1420` на `1320` или `1280` не устраняла проблему.

**Подтверждённая причина**

Системные UDP receive/send buffers оставались на значении `212992` байта. Во
время контролируемого теста рос счётчик `UdpRcvbufErrors`: ядро отбрасывало
датаграммы раньше, чем AWG успевал их обработать. Ограничением являлся UDP
socket buffer, а не пропускная способность VPS и не размер клиентского пакета.

**Исправление**

Golden на clean install и на profile-preserving `upgrade` применяет:

```text
net.core.rmem_default = 4194304
net.core.rmem_max = 16777216
net.core.wmem_default = 4194304
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 4096
```

Настройки хранятся в
`/etc/sysctl.d/97-golden-vpn-udp-buffers.conf`. Они не меняют ключи, peers,
endpoint или AWG 3.1 obfuscation-параметры.

**Проверка**

```bash
sysctl net.core.rmem_default net.core.rmem_max \
  net.core.wmem_default net.core.wmem_max net.core.netdev_max_backlog
nstat -az UdpRcvbufErrors UdpSndbufErrors
ss -u -a -n -m | grep -E ':443|:8443'
```

Сравнивать `nstat` нужно до и после одинаковой нагрузки: накопительный счётчик
сам по себе не доказывает текущую потерю пакетов. **Статус: в скрипте.**

## 21. Регрессионное покрытие журнала

Инциденты, вызванные самим установщиком, закрыты кодом и автоматическими
проверками. Внешние сбои CA, фильтрация сети и падение клиентского приложения не
могут быть гарантированно предотвращены серверным bash-скриптом; для них Golden
сохраняет состояние, применяет fallback либо выдаёт профиль, исключающий уже
известную клиентскую причину.

| Инцидент | Защита при новой установке/upgrade | Проверка |
|---|---|---|
| Заполненный диск | storage gate, journald/logrotate limits | `test-storage-gate-contract.sh`, `_validate_storage_configs.sh` |
| Ошибочный запуск acme.sh / неизвестный cert name | контролируемая установка, строгий issue→install-cert | `test-acme-ca-fallback.sh` |
| ZeroSSL 502/nonce/EAB | повтор сохранённого заказа, затем LE DNS-01 fallback | `test-acme-ca-fallback.sh` |
| Повреждённый resume env | shell-quoting и allowlist переменных | `test-compact-install-ui.sh`, `test-rendered-shell-syntax.sh` |
| Мерцание/96% cleanup | компактный status UI и одноразовый resume unit | `test-compact-install-ui.sh` |
| `cat: PHONE`/неверный helper | positional argument, atomic file output, syntax tests | `test-rendered-shell-syntax.sh` |
| Потеря профилей при обновлении | backup, byte-for-byte invariant, rollback | `test-upgrade-profile-preservation.sh` |
| AWG DNS/NAT/MTU и неполные legacy params | forwarding/NAT, DNS, PMTU, восстановление AWG 3.1 полей | `test-awg31-config.sh`, `test-awg-helper-param-recovery.sh` |
| Hysteria UDP timeout | port hopping и сохранение credentials | `test-hysteria-profiles.sh` |
| DNS leak в старом клиенте | Hiddify JSON с DoH through tunnel без plaintext fallback | `test-hiddify-json-profiles.sh` |
| Истечение TLS | renewal hook и ежедневный deduplicated notifier | `test-bot-telegram-integration.sh` |
| Неполная bot-выгрузка | один typed bundle для `--type all --send` | `test-bot-telegram-integration.sh` |
| Риск engine auto-update | stable-only, config validation, healthcheck, rollback; безопасный skip имеет exit 0 | `test-engine-updater-contract.sh` |
| Низкая AWG-скорость из-за UDP drops | постоянные увеличенные UDP buffers на install и upgrade | `test-udp-buffer-tuning.sh` |

`ssh-keyscan` со старым Windows OpenSSH, P2P-нагрузка и локальная остановка
клиентского сервиса относятся к клиенту/эксплуатации и не создаются установщиком.
