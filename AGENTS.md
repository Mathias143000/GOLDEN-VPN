# Техническое задание: Golden Install VPN Stack

> Актуальное изменение от 2026-06-19: основной TCP/443 контур заменен на Trojan XHTTP TLS.
> Старые упоминания VLESS/REALITY ниже считаются устаревшими, если они противоречат `install-vpn-stack.sh` и `README.md`.

## 0. Аудит текущего скрипта и roadmap улучшений

Этот раздел имеет приоритет над устаревшими пунктами ниже, если они расходятся с текущим `install-vpn-stack.sh`.

### 0.0 DoD status after P0-P2 implementation

This section is normative for the current project state. Older VLESS/REALITY sections below are legacy notes only and must not override the current Trojan XHTTP TLS implementation.

Implemented DoD items:

```text
CLI modes: install, preflight, validate/verify, report, render-decoy
Reports: /root/vpn-keys/install-report.txt and /root/vpn-keys/install-report.json
AWG report: /opt/vpn-stack/awg-tuning-report.json
Decoy manifest: /opt/vpn-stack/decoy-manifest.json
AWG profiles: dns, quic-lite, video-call, mobile-low-mtu, random-balanced, custom
AWG_MTU=auto with PMTU probe and 1280 fallback
AWG overrides: AWG_JC/JMIN/JMAX/S1-S4/H1-H4/I1-I5/MTU/DNS/ALLOWED_IPS/KEEPALIVE/ENDPOINT_PORT
AWG helpers: list, show, revoke, rotate, profile, show-config, explain, analyze, capture, analyze-live
Decoy profiles: network-monitor, software-status, edge-docs, availability-lab
Decoy controls: DECOY_PROFILE, DECOY_SEED, DECOY_BRAND, DECOY_REGION
Decoy safety: static only, no external URLs, no forms, no JS, forbidden-word scan before nginx reload
Tcpdump policy: never automatic during install; only explicit vpn-awg helper commands
Default install flow: two-stage bootstrap -> reboot -> one-shot install
Installer status: vpn-install-status watch
Subscription helper: vpn-sub create/list/show/revoke/rotate
Subscription URL shape: https://DOMAIN/s/<token>
```

### 0.0.1 Two-stage installer flow

This section is normative for new work.

Default `./install-vpn-stack.sh` must run `bootstrap`, not the full monolithic install. The bootstrap stage must:

```text
ask interactively for DOMAIN, EMAIL, SERVER_LOCATION, CF_Token unless env overrides are already set
offer Advanced tuning? [y/N] for AWG_OBFS_PROFILE, AWG_MTU, DECOY_PROFILE, DECOY_SEED
save /etc/golden-vpn-installer/install.env with root-only permissions
install bootstrap dependencies and wait for apt/dpkg locks through DPkg::Lock::Timeout
verify/keep SSH reachable before firewall or reboot changes
install vpn-install-status
schedule vpn-stack-resume-install.service/timer for one stage2 attempt after reboot
reboot once
```

The stage2 `install` run must:

```text
read the saved env
configure the full VPN stack
write progress to /var/log/vpn-stack/install-progress.env
write logs to /var/log/vpn-stack-resume-install.log when systemd launched
remove the one-shot service/timer after the first attempt
keep env/log/status available after failure for manual retry
not retry automatically on every reboot
```

`vpn-install-status watch` is the primary post-reboot UX. It should show pinned or periodically redrawn colored progress plus recent logs in TTY, and line-oriented status/logs in non-TTY.

### 0.0.2 Subscription system roadmap

Hiddify Manager (`https://github.com/hiddify/Hiddify-Manager`) is the UX and endpoint-behavior reference for subscription import flows. Golden VPN must not vendor Hiddify Manager, install Hiddify Panel, add x-ui, add a backend admin, add Cloudflare Tunnel, or add a database-backed panel.

The lightweight subscription layer is static nginx + bash helpers:

```text
vpn-sub create <name>
vpn-sub list
vpn-sub show <name>
vpn-sub revoke <name>
vpn-sub rotate <name>
```

`vpn-sub create <name>` creates a linked bundle:

```text
Trojan XHTTP TLS client
Hysteria2 client
AmneziaWG client config
unguessable token with at least 128-bit entropy
metadata: /opt/vpn-stack/subscriptions/<token>/meta.json
public files: /var/www/subscriptions/<token>/
```

URL model:

```text
Browser portal: https://DOMAIN/s/<token>
Client import URL: https://DOMAIN/s/<token>
Plain subscription payload: https://DOMAIN/s/<token>/sub.txt
Base64 subscription payload: https://DOMAIN/s/<token>/sub.base64
AmneziaWG download: https://DOMAIN/s/<token>/awg.conf
AmneziaWG preview: https://DOMAIN/s/<token>/awg
```

Subscription payload v1:

```text
sub.txt contains trojan:// and hysteria2:// links
sub.base64 contains a base64 encoded version of sub.txt
index.html is a clean static portal with copy/download links
awg.conf is downloadable separately because many clients do not reliably import AWG from mixed subscription payloads
awg preview is a noindex static HTML page
```

Nginx and security requirements:

```text
/s/<token> is handled by a dedicated location outside decoy generation/scanning
access_log off for subscription locations to avoid token leakage
X-Robots-Tag: noindex, nofollow
no directory listing
no external JS, CDN, forms, login, admin, cookies, analytics
install reports must mention feature paths and URL shape only, never tokens or client secrets
revoke removes nginx-served files and disables protocol credentials
rotate revokes old files/credentials and creates a fresh token plus fresh protocol credentials
```

### 0.1 Текущее состояние

Фактическая архитектура скрипта:

```text
Trojan XHTTP TLS → 443/tcp через nginx HTTPS location + Xray unix socket
Hysteria2 Salamander → 8443/udp
AmneziaWG 2.0 → 51820/udp
Decoy HTTPS site → встроенный статический генератор HTML/CSS
Grafana + Prometheus + Node Exporter → localhost-only
Client labels → <PROTOCOL>-<LOCATION>-<NAME>
```

Уже реализовано:

```text
SERVER_LOCATION из двух ASCII-букв
TROJAN-<LOCATION>-<name>
HYSTERIA-<LOCATION>-<name>
AWG-<LOCATION>-<name>
QR-коды в helper-командах
ручной two-stage install без auto reboot/resume по умолчанию
ожидание apt/dpkg lock через DPkg::Lock::Timeout
ASCII-валидация EMAIL
ZeroSSL primary + fallback CA через DNS-01
AWG_OBFS_PROFILE=dns|quic-lite
AWG_MTU по умолчанию 1280, допустимо 1200..1420
ручные AWG diagnostics: vpn-awg analyze, vpn-awg capture
рандомный decoy site без внешних CDN/JS/forms/backend
```

Главные проблемы текущего скрипта:

```text
AGENTS.md ниже содержит много устаревших требований про VLESS REALITY.
AmneziaWG параметры рандомятся из двух грубых профилей, но нет объяснимого выбора под конкретную сеть.
tcpdump не используется автоматически для принятия решений; он только ручной diagnostic helper.
MTU задан явно, но нет PMTU/DF-probe и нет автоподбора по маршруту.
Decoy site рандомится только из встроенных списков; нет профилей отрасли, seed, preview и контроля уникальности.
Install flow все еще слишком монолитный: одна большая bash-программа без unit-тестов функций.
Нет команд list/revoke/rotate для клиентов.
Нет отдельного config/env-файла с полным описанием всех tunables.
Нет audit report после установки в машинно-читаемом JSON.
```

### 0.2 Улучшения install flow

Следующий желательный install flow:

```text
1. preflight-only:
   - проверка root, OS, kernel, DNS, Cloudflare token, email, SERVER_LOCATION
   - проверка SSH listener и UFW без изменения VPN-конфигов
   - проверка apt/dpkg lock и pending reboot
   - вывод понятного отчета PASS/WARN/FAIL

2. manual reboot gate:
   - скрипт не должен сам перезагружать VPS по умолчанию
   - если нужен kernel reboot, скрипт останавливается с понятной командой
   - auto resume допускается только через явный флаг и должен быть deprecated

3. install:
   - установка пакетов
   - выпуск сертификата
   - настройка контуров
   - настройка monitoring/logrotate/timers

4. verify:
   - проверка listeners
   - проверка systemd services
   - проверка decoy HTTPS
   - проверка helper-команд без создания лишних тестовых клиентов по умолчанию

5. report:
   - человекочитаемый summary
   - JSON-report в /root/vpn-keys/install-report.json
```

Нужные команды:

```bash
./install-vpn-stack.sh preflight
./install-vpn-stack.sh install
./install-vpn-stack.sh verify
./install-vpn-stack.sh report
```

### 0.3 Полная кастомизация AmneziaWG

Сейчас AWG использует профили:

```text
AWG_OBFS_PROFILE=dns
AWG_OBFS_PROFILE=quic-lite
AWG_MTU=1280
```

Нужно развить это до полноценной системы профилей:

```text
AWG_OBFS_PROFILE=dns
AWG_OBFS_PROFILE=quic-lite
AWG_OBFS_PROFILE=video-call
AWG_OBFS_PROFILE=mobile-low-mtu
AWG_OBFS_PROFILE=random-balanced
AWG_OBFS_PROFILE=custom
```

Для `custom` должны поддерживаться все поля:

```text
AWG_JC
AWG_JMIN
AWG_JMAX
AWG_S1
AWG_S2
AWG_S3
AWG_S4
AWG_H1
AWG_H2
AWG_H3
AWG_H4
AWG_I1
AWG_I2
AWG_I3
AWG_I4
AWG_I5
AWG_MTU
AWG_DNS
AWG_ALLOWED_IPS
AWG_KEEPALIVE
AWG_ENDPOINT_PORT
```

Требования к AWG tuning:

```text
не делать вид, что параметры "оптимальны", если они просто сгенерированы случайно
логировать выбранный профиль и источник каждого значения: default/profile/user/random
писать /opt/vpn-stack/awg-tuning-report.json
писать комментарий в клиентский .conf с профилем, MTU и датой генерации
добавить vpn-awg profile, vpn-awg show-config, vpn-awg explain
добавить vpn-awg revoke <name>
добавить vpn-awg list
добавить vpn-awg rotate <name>
```

MTU надо улучшить:

```text
текущий default 1280 оставить безопасным fallback
добавить AWG_MTU=auto
при auto сделать PMTU probe через ping -M do -s ...
проверять несколько targets: 1.1.1.1, 8.8.8.8, DOMAIN
не запускать auto-MTU, если ICMP недоступен; fallback 1280
писать результат probe в awg-tuning-report.json
```

tcpdump использовать только явно:

```text
не запускать tcpdump автоматически без явного согласия
vpn-awg capture 30 сохраняет pcap
vpn-awg analyze 20 делает pcap + summary размеров пакетов
добавить vpn-awg analyze-live без сохранения pcap
добавить redaction warning: pcap содержит метаданные и должен храниться приватно
добавить авто-рекомендации: no packets / only inbound / only outbound / handshake seen
```

### 0.4 Decoy site roadmap

Текущий decoy:

```text
встроенный статический HTML/CSS
рандомный brand/tagline/focus/region/colors/build_id/status_note/docs_title
страницы: /, /status, /docs, /privacy, /404.html, /robots.txt
без JS, forms, cookies, analytics, external CDN
```

Нужно улучшить до профильного генератора:

```text
DECOY_PROFILE=monitoring
DECOY_PROFILE=software
DECOY_PROFILE=hosting
DECOY_PROFILE=docs
DECOY_PROFILE=status
DECOY_PROFILE=consulting
DECOY_PROFILE=random
```

Нужные переменные:

```text
DECOY_BRAND
DECOY_PROFILE
DECOY_SEED
DECOY_REGION
DECOY_LANG=en|ru
DECOY_COLOR_MODE=auto|blue|green|slate|neutral
DECOY_EXTRA_PAGES=0|1
DECOY_ROBOTS_MODE=allow|quiet
DECOY_CANONICAL_HOST
```

Требования к decoy:

```text
оставаться статичным
не использовать внешние шрифты, CDN, аналитики, формы и login/admin
не содержать слов vpn/proxy/tunnel/wireguard/trojan/hysteria/amnezia
генерировать sitemap.xml опционально
делать deterministic output при DECOY_SEED
писать /opt/vpn-stack/decoy-manifest.json
добавить команду vpn-decoy-regenerate
добавить команду vpn-decoy-preview, которая показывает список файлов и sha256
```

Нужно добавить проверку decoy:

```text
curl -k https://DOMAIN/
curl -k https://DOMAIN/status
curl -k https://DOMAIN/404-does-not-exist
проверить отсутствие external URLs в HTML/CSS
проверить отсутствие forbidden words
проверить, что Trojan path не светится в public HTML
```

### 0.5 Trojan/Hysteria/client lifecycle

Нужно добавить полный lifecycle:

```text
vpn-trojan list
vpn-trojan revoke <name>
vpn-trojan rotate <name>
vpn-trojan show <name>

vpn-hysteria list
vpn-hysteria revoke <name>
vpn-hysteria rotate <name>
vpn-hysteria show <name>

vpn-awg list
vpn-awg revoke <name>
vpn-awg rotate <name>
vpn-awg show <name>
```

Правила naming:

```text
имя клиента от пользователя: только [A-Za-z0-9._-]
итоговый label: <PROTOCOL>-<SERVER_LOCATION>-<name>
если пользователь уже ввел полный label, не дублировать prefix/location
```

### 0.6 Observability и диагностика

Нужно улучшить мониторинг:

```text
systemd service health в Grafana
node_exporter dashboard 1860 оставить
добавить provisioned dashboard для VPN stack
добавить textfile collector для:
  - активные сервисы
  - количество клиентов
  - дата последнего успешного cert renewal
  - swap status
  - выбранный AWG profile и MTU
```

Логи:

```text
секреты не должны попадать в stdout/journal
CF_Token, passwords, private keys не логировать
ключи писать только в /root/vpn-keys с 0600
install-report.json должен маскировать секреты
```

### 0.7 Тестирование и качество

Нужно добавить локальный test harness:

```text
bash -n install-vpn-stack.sh
shellcheck install-vpn-stack.sh
тест извлеченных heredoc helper-скриптов через bash -n
тест regex для EMAIL, DOMAIN, SERVER_LOCATION
тест генерации label_name
тест render decoy во временную директорию
тест AWG profile generation в dry-run
```

Желательные режимы:

```bash
./install-vpn-stack.sh --dry-run
./install-vpn-stack.sh --render-only /tmp/vpn-stack-render
./install-vpn-stack.sh --validate-only
```

### 0.8 Приоритеты реализации

Порядок улучшений:

```text
P0:
  - убрать оставшиеся устаревшие VLESS/REALITY противоречия из AGENTS.md
  - добавить --validate-only и preflight
  - добавить install-report.json
  - добавить AWG profile report

P1:
  - AWG custom profile со всеми параметрами
  - AWG_MTU=auto через PMTU probe
  - vpn-awg list/revoke/rotate/show
  - decoy manifest + forbidden-word scanner

P2:
  - decoy profiles + DECOY_SEED
  - vpn-decoy-regenerate / preview
  - VPN stack Grafana dashboard

P3:
  - shellcheck/Bats CI
  - test matrix Ubuntu 22.04/24.04/Debian 12
  - structured JSON logs for install phases
```

## 1. Назначение

Необходимо разработать единый установочный скрипт `install-vpn-stack.sh`, который на чистом Ubuntu/Debian VPS автоматически разворачивает готовую VPN-инфраструктуру.

Скрипт должен разворачивать сервер с нуля без ручной сборки отдельных компонентов и без переноса старых конфигураций.

Итоговая архитектура:

```text
Trojan XHTTP TLS → 443/tcp
Hysteria2 Salamander → 8443/udp
AmneziaWG 2.0 → 51820/udp
Decoy HTTPS site → https://DOMAIN/
Grafana + Prometheus + Node Exporter → localhost-only
Node Exporter Full dashboard → Grafana dashboard ID 1860
```

В Golden Install не должны входить:

```text
Cloudflare orange cloud CDN
Cloudflare Tunnel
WARP
Telegram bot
Hiddify Panel
x-ui Panel
emergency export/restore
миграция старых ключей
```

---

## 2. Входные переменные

Перед запуском пользователь задаёт:

```bash
export DOMAIN="s5.super-lemming.online"
export EMAIL="teriomta@gmail.com"
export CF_Token="CLOUDFLARE_DNS_TOKEN"
```

Скрипт обязан проверить:

```text
запущен ли он от root
DOMAIN не пустой
EMAIL не пустой
CF_Token не пустой
определяется ли публичный IPv4 сервера
определяется ли внешний сетевой интерфейс сервера
```

DNS-запись домена заранее должна быть настроена так:

```text
A DOMAIN → IPv4 сервера
Cloudflare Proxy Status: DNS only / серое облако
```

Orange cloud не использовать.

---

## 3. Итоговая схема портов

Снаружи должны быть доступны только:

```text
443/tcp      nginx stream router → VLESS REALITY XHTTP / decoy
8443/udp     Hysteria2 Salamander
51820/udp    AmneziaWG
```

Локально должны слушать:

```text
127.0.0.1:10443    Xray VLESS REALITY XHTTP backend
127.0.0.1:8444     nginx HTTPS decoy backend
127.0.0.1:3000     Grafana
127.0.0.1:9090     Prometheus
127.0.0.1:9100     Node Exporter
```

Не должно быть наружу:

```text
0.0.0.0:3000
0.0.0.0:9090
0.0.0.0:9100
0.0.0.0:8080
```

---

## 4. Базовые пакеты

Скрипт должен установить:

```text
curl
wget
unzip
jq
openssl
ca-certificates
socat
qrencode
ufw
lsb-release
gnupg
iptables
python3
build-essential
dkms
nginx
libnginx-mod-stream
prometheus
prometheus-node-exporter
grafana
```

Не устанавливать:

```text
cloudflare-warp
hiddify
x-ui
certbot
lego
```

---

## 5. SSL-сертификат

Сертификат нужен для:

```text
decoy HTTPS site
Hysteria2 TLS
```

VLESS REALITY не использует обычный сертификат домена для своего TLS-профиля, но сертификат всё равно обязателен для decoy и Hysteria2.

Сертификат выпускать через:

```text
acme.sh + ZeroSSL + Cloudflare DNS-01
```

Пути итоговых файлов:

```text
/etc/letsencrypt/live/$DOMAIN/fullchain.pem
/etc/letsencrypt/live/$DOMAIN/privkey.pem
```

Требования:

```text
не использовать Let's Encrypt как основной CA
не использовать HTTP-01 challenge
не требовать открытый 80/tcp
после выпуска проверить openssl x509
после выпуска проверить openssl pkey
```

ACME-состояние сохранить:

```text
/root/.acme.sh
/root/acme-zerossl
```

---

## 6. Decoy HTTPS site

Decoy-сайт должен открываться по адресу:

```text
https://DOMAIN/
```

Содержимое страницы должно быть нейтральным, без слов VPN/proxy:

```text
Service status
This service is online.
Maintenance and availability monitoring endpoint.
```

Страница должна храниться в:

```text
/var/www/decoy/index.html
```

Decoy-сайт должен обслуживаться локальным nginx HTTPS backend на:

```text
127.0.0.1:8444
```

Этот backend использует сертификат:

```text
/etc/letsencrypt/live/$DOMAIN/fullchain.pem
/etc/letsencrypt/live/$DOMAIN/privkey.pem
```

Обычный браузерный запрос:

```text
https://DOMAIN/
```

должен попадать на decoy site.

---

## 7. VLESS REALITY XHTTP

Основной TCP-контур вместо Trojan:

```text
VLESS REALITY XHTTP
порт входа: 443/tcp
transport: xhttp
mode: stream-one
security: reality
fingerprint: chrome
mask target: www.vk.com:443
client SNI: www.vk.com
```

### 7.1 Общая схема

На `443/tcp` слушает nginx stream router.

Схема:

```text
клиент / браузер
↓
DOMAIN:443
↓
nginx stream ssl_preread
├── SNI www.vk.com / vk.com → Xray REALITY XHTTP 127.0.0.1:10443
└── SNI DOMAIN / default    → decoy HTTPS 127.0.0.1:8444
```

Обычный браузер:

```text
https://DOMAIN/
```

должен попасть на decoy site.

VLESS REALITY клиент подключается к:

```text
DOMAIN:443
```

но внутри ссылки использует:

```text
sni=www.vk.com
fp=chrome
security=reality
type=xhttp
```

### 7.2 Xray REALITY backend

Xray должен слушать локально:

```text
127.0.0.1:10443
```

Файл конфигурации:

```text
/opt/vpn-stack/xray/config.json
```

Сервис:

```text
xray-vless-reality-xhttp.service
```

Сохраняемые параметры:

```text
/opt/vpn-stack/vless-reality-uuid.txt
/opt/vpn-stack/vless-reality-path.txt
/opt/vpn-stack/vless-reality-private-key.txt
/opt/vpn-stack/vless-reality-public-key.txt
/opt/vpn-stack/vless-reality-short-id.txt
```

Генерация REALITY-ключей:

```bash
/usr/local/bin/xray x25519
```

Генерация UUID:

```bash
/usr/local/bin/xray uuid
```

Генерация shortId:

```bash
openssl rand -hex 8
```

XHTTP path должен быть случайным:

```text
/hex/hex/
```

Пример:

```text
/9f2a01d0e3bd43a7/aa12bb34cc56dd78/
```

REALITY target:

```text
www.vk.com:443
```

REALITY serverNames:

```json
[
  "www.vk.com",
  "vk.com"
]
```

REALITY fingerprint в клиентской ссылке:

```text
chrome
```

### 7.3 Nginx stream router

Nginx должен иметь stream-конфигурацию вида:

```nginx
stream {
    map $ssl_preread_server_name $vpn_backend {
        www.vk.com xray_reality;
        vk.com xray_reality;
        default decoy_https;
    }

    upstream xray_reality {
        server 127.0.0.1:10443;
    }

    upstream decoy_https {
        server 127.0.0.1:8444;
    }

    server {
        listen 443;
        proxy_pass $vpn_backend;
        ssl_preread on;
    }
}
```

Для этого в установке должен быть установлен модуль:

```text
libnginx-mod-stream
```

Nginx HTTP/HTTPS backend для decoy должен слушать только:

```text
127.0.0.1:8444
```

---

## 8. Hysteria2 Salamander

Второй контур:

```text
Hysteria2 Salamander
порт: 8443/udp
TLS: сертификат DOMAIN
```

Файлы:

```text
/opt/vpn-stack/hysteria/config.yaml
/opt/vpn-stack/hysteria-auth.txt
/opt/vpn-stack/hysteria-obfs.txt
/opt/vpn-stack/hysteria-clients.json
```

Сервис:

```text
hysteria2.service
```

Изначально создать одного клиента:

```text
main-hysteria-client
```

Для новых клиентов использовать режим:

```yaml
auth:
  type: userpass
```

Каждый новый клиент должен получать отдельную пару:

```text
username
password
```

Ссылка клиента должна сохраняться в:

```text
/root/vpn-keys/hysteria/<name>.txt
```

---

## 9. AmneziaWG 2.0

Третий контур:

```text
AmneziaWG 2.0
порт: 51820/udp
интерфейс: awg0
сеть: 10.66.66.0/24
сервер: 10.66.66.1/24
```

Серверный конфиг:

```text
/etc/amnezia/amneziawg/awg0.conf
```

Первый клиент:

```text
/root/vpn-keys/awg/main-awg.conf
```

Endpoint в клиентских конфигах должен быть доменным:

```text
Endpoint = DOMAIN:51820
```

Не использовать IP в Endpoint, чтобы при переносе на новый сервер не переписывать все клиентские конфиги вручную.

Обязательные параметры AWG:

```text
Jc
Jmin
Jmax
S1
S2
S3
S4
H1
H2
H3
H4
```

Включить сервисы:

```text
amneziawg-ensure-module.service
awg-quick@awg0.service
```

Добавить зависимость:

```text
awg-quick@awg0 стартует после amneziawg-ensure-module.service
```

---

## 10. Swap

Отдельно swap заранее не создавать.

Логика после установки AmneziaWG:

```text
проверить swapon --show
если swap уже есть — оставить
если swap отсутствует — создать /swapfile 2G
всегда выставить vm.swappiness=10
```

Файл настроек:

```text
/etc/sysctl.d/99-vpn-swap.conf
```

Параметры:

```text
vm.swappiness=10
vm.vfs_cache_pressure=50
```

---

## 11. Firewall

Открыть:

```bash
ufw allow 443/tcp
ufw allow 8443/udp
ufw allow 51820/udp
```

Не открывать наружу:

```text
3000/tcp
9090/tcp
9100/tcp
8080/tcp
8444/tcp
10443/tcp
```

---

## 12. Helper-скрипты

После установки должны быть только 4 основные команды:

```text
vpn-vless-reality
vpn-hysteria
vpn-awg
vpn-help
```

Не должно быть:

```text
vpn
vpn-trojan
vpn-vless-xhttp
бота Telegram
старых helper-скриптов
```

---

### 12.1 `vpn-vless-reality <name>`

Назначение: создать нового VLESS REALITY XHTTP клиента.

Скрипт должен:

```text
сгенерировать новый UUID
добавить клиента в /opt/vpn-stack/xray/config.json
проверить конфиг через xray run -test
перезапустить xray-vless-reality-xhttp
вывести VLESS ссылку в терминал
сохранить ссылку в /root/vpn-keys/vless-reality/<name>.txt
```

Формат ссылки:

```text
vless://UUID@DOMAIN:443?security=reality&type=xhttp&encryption=none&path=ENCODED_PATH&mode=stream-one&sni=www.vk.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&spx=%2F#VLESS-REALITY-XHTTP-name
```

Параметры:

```text
UUID       → новый UUID клиента
DOMAIN     → домен сервера
path       → /opt/vpn-stack/vless-reality-path.txt
sni        → www.vk.com
fp         → chrome
pbk        → /opt/vpn-stack/vless-reality-public-key.txt
sid        → /opt/vpn-stack/vless-reality-short-id.txt
spx        → /
```

---

### 12.2 `vpn-hysteria <name>`

Назначение: создать нового Hysteria2-клиента.

Скрипт должен:

```text
добавить клиента в /opt/vpn-stack/hysteria-clients.json
перерендерить /opt/vpn-stack/hysteria/config.yaml в userpass mode
перезапустить hysteria2
вывести hysteria2:// ссылку
сохранить ссылку в /root/vpn-keys/hysteria/<name>.txt
```

---

### 12.3 `vpn-awg <name>`

Назначение: создать нового AmneziaWG-клиента.

Скрипт должен:

```text
выдать следующий свободный IP из 10.66.66.0/24
создать ключи клиента
добавить Peer в /etc/amnezia/amneziawg/awg0.conf
добавить peer в активный awg0 через awg set
вывести .conf в терминал
сохранить .conf в /root/vpn-keys/awg/<name>.conf
```

---

### 12.4 `vpn-help`

Команда должна показывать:

```text
как создать VLESS REALITY XHTTP клиента
как создать Hysteria2 клиента
как создать AmneziaWG клиента
где лежат ключи
как проверить сервисы
как открыть Grafana через SSH tunnel
как импортировать dashboard 1860
```

Также должна поддерживать вызовы:

```bash
vpn-help reality phone1
vpn-help xhttp phone1
vpn-help vless phone1
vpn-help hysteria phone1
vpn-help awg phone1
```

---

## 13. Мониторинг

Установить и настроить:

```text
Prometheus
Node Exporter
Grafana
```

### 13.1 Node Exporter

Слушает только:

```text
127.0.0.1:9100
```

### 13.2 Prometheus

Слушает только:

```text
127.0.0.1:9090
```

Scrape targets:

```yaml
127.0.0.1:9090
127.0.0.1:9100
```

Retention:

```text
--storage.tsdb.retention.time=7d
--storage.tsdb.retention.size=1GB
```

### 13.3 Grafana

Слушает только:

```text
127.0.0.1:3000
```

Автоматически создать datasource:

```text
Name: Prometheus
Type: prometheus
URL: http://127.0.0.1:9090
Default: true
```

### 13.4 Dashboard

Нужно предусмотреть популярный dashboard:

```text
Node Exporter Full
Dashboard ID: 1860
```

Желательно реализовать автоматический provisioning dashboard JSON в Grafana.

Если автоматический импорт не реализован, `vpn-help` должен явно писать:

```text
Grafana → Dashboards → New → Import → 1860 → datasource Prometheus
```

---

## 14. Ограничение логов и хранения

Настроить journald:

```text
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=7day
```

Файл:

```text
/etc/systemd/journald.conf.d/limits.conf
```

Настроить logrotate:

```text
/var/log/vpn-stack/*.log
daily
rotate 7
compress
copytruncate
```

Файл:

```text
/etc/logrotate.d/vpn-stack
```

---

## 15. Soft reboot

Настроить мягкую ежедневную перезагрузку:

```text
04:00 Europe/Moscow
```

Через systemd timer:

```text
vpn-soft-reboot.service
vpn-soft-reboot.timer
```

Требования:

```text
Persistent=false
лог: /var/log/vpn-soft-reboot.log
команда: systemctl reboot
```

Скрипт:

```text
/usr/local/sbin/vpn-soft-reboot.sh
```

---

## 16. Boot healthcheck

Добавить healthcheck после загрузки сервера.

Сервис:

```text
vpn-stack-healthcheck.service
vpn-stack-healthcheck.timer
```

Запуск:

```text
OnBootSec=2min
```

Проверяет и при необходимости перезапускает:

```text
nginx
xray-vless-reality-xhttp
hysteria2
prometheus
prometheus-node-exporter
grafana-server
amneziawg-ensure-module
awg-quick@awg0
```

Лог:

```text
/var/log/vpn-stack-healthcheck.log
```

---

## 17. Автозагрузка

Включить автозагрузку:

```bash
systemctl enable nginx
systemctl enable xray-vless-reality-xhttp
systemctl enable hysteria2
systemctl enable amneziawg-ensure-module
systemctl enable awg-quick@awg0
systemctl enable prometheus
systemctl enable prometheus-node-exporter
systemctl enable grafana-server
systemctl enable vpn-soft-reboot.timer
systemctl enable vpn-stack-healthcheck.timer
```

---

## 18. Финальные проверки установщика

В конце install script должен вывести:

```bash
ss -lntup | grep -E ':443|:8443|:51820|:3000|:9090|:9100|:10443|:8444'

systemctl status nginx --no-pager
systemctl status xray-vless-reality-xhttp --no-pager
systemctl status hysteria2 --no-pager
systemctl status awg-quick@awg0 --no-pager -l
systemctl status prometheus --no-pager
systemctl status prometheus-node-exporter --no-pager
systemctl status grafana-server --no-pager
```

Ожидаемое состояние:

```text
*:443/tcp             nginx stream router
127.0.0.1:10443       Xray VLESS REALITY XHTTP
127.0.0.1:8444        nginx decoy HTTPS backend
*:8443/udp            Hysteria2
*:51820/udp           AmneziaWG
127.0.0.1:3000        Grafana
127.0.0.1:9090        Prometheus
127.0.0.1:9100        Node Exporter
```

Проверка decoy:

```bash
curl -vk https://$DOMAIN/
```

Проверка helper:

```bash
vpn-help
vpn-vless-reality test-reality
vpn-hysteria test-hy2
vpn-awg test-awg
```

---

## 19. Grafana usage

Grafana не открывается наружу.

Подключение только через SSH tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 root@SERVER_IP
```

Открыть в браузере:

```text
http://localhost:3000
```

Логин по умолчанию:

```text
admin / admin
```

После первого входа сменить пароль.

Dashboard:

```text
Dashboards → New → Import → 1860
Datasource → Prometheus
```

Если dashboard auto-provisioning реализован, dashboard должен появиться автоматически.

---

## 20. Что не входит в Golden Install

Не включать:

```text
Cloudflare orange cloud CDN
Cloudflare Tunnel
WARP
Telegram bot
Hiddify panel
x-ui panel
Trojan TCP/TLS
обычный VLESS XHTTP TLS без Reality
emergency export/restore
автоматическую миграцию старых ключей
```

---

## 21. Итоговый результат

После запуска `install-vpn-stack.sh` новый сервер должен быть полностью готов:

```text
1. Открывается decoy site по https://DOMAIN/
2. Создаются VLESS REALITY XHTTP ключи одной командой
3. Создаются Hysteria2 ключи одной командой
4. Создаются AmneziaWG .conf одной командой
5. Работает Grafana через SSH tunnel
6. Prometheus собирает CPU/RAM/Disk/Network
7. Dashboard Node Exporter Full 1860 доступен или готов к импорту
8. Логи и метрики ограничены по хранению
9. Ежедневный soft reboot в 04:00 МСК настроен
10. После reboot сервисы автоматически поднимаются
```

---

## 22. Важное замечание по REALITY

VLESS REALITY XHTTP с маскировкой под VK и `fp=chrome` является отдельным TCP-контуром и не заменяет полностью UDP-контуры.

Финальная архитектура должна сохранять три независимых варианта подключения:

```text
VLESS REALITY XHTTP → основной TCP/443 контур
Hysteria2 Salamander → быстрый UDP-контур
AmneziaWG 2.0 → отдельный UDP/WG-like контур
```

Это нужно, чтобы сервер не зависел от одного протокола и одного типа фильтрации.
