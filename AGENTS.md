# Техническое задание: Golden Install VPN Stack

> Актуальное изменение от 2026-06-19: основной TCP/443 контур заменен на Trojan XHTTP TLS.
> Старые упоминания VLESS/REALITY ниже считаются устаревшими, если они противоречат `install-vpn-stack.sh` и `README.md`.

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
