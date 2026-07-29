# Обзор: что такое bootstrap и зачем он нужен

## Задача

Есть голый VPS. Нужна корпоративная инфраструктура: git с CI, трекер задач,
вики, публичный сайт, VPN для доступа сотрудников, обратный прокси с
сертификатами, мониторинг, бэкапы, которые действительно восстанавливаются, и
AI-оператор, который умеет разбираться с алертами.

Это шесть разных областей ответственности. Каждая живёт в своём репозитории,
чтобы у них были независимые права доступа и независимые релизные циклы. Но
поставить их в произвольном порядке нельзя, а состояние установки нужно где-то
хранить. Этим и занимается `bootstrap`.

## Что делает именно эта репа

| Делает | Не делает |
|---|---|
| Измеряет хост (`recon.sh`) | Не ставит GitLab, VPN, бэкапы — этим заняты другие репы |
| Решает, влезет ли профиль в машину | Не решает, как настроен sshd |
| Ставит Docker Engine (единственное решение об этом) | Не трогает ничего вне `/opt/corp-infra` и `/var/lib/corp-infra`, кроме Docker |
| Держит канонический `lib/common.sh` | Не правит вендоренные копии в чужих репах |
| Запускает пять этапов в правильном порядке и проверяет переходы | Не выполняет шаги этапов сама |

## Карта шести репозиториев

```
corp-infra-bootstrap     ← вы здесь. Оркестрация, recon, профили, библиотека
  │
  ├─ 1. corp-infra-security     Базлайн хоста и секреты
  │        sshd, ufw, fail2ban, unattended-upgrades, sysctl, auditd,
  │        age-ключ + sops, процедура escrow
  │
  ├─ 2. corp-infra-vpn-proxy    Сетевой периметр
  │        WireGuard-хаб 10.8.0.0/24, caddy-public (0.0.0.0:443),
  │        caddy-internal (только на адресе wg0)
  │
  ├─ 3. corp-infra-backup       Долговечность
  │        restic по схеме 3-2-1, локальный репозиторий + offsite,
  │        systemd-таймеры, восстановление, учения
  │
  ├─ 4. corp-infra-ent-infra    Бизнес-сервисы
  │        GitLab CE + runner, трекер, вики BookStack, сайт Hugo,
  │        observability (Prometheus, Loki, Grafana, Alloy)
  │
  └─ 5. corp-infra-pop-agents   AI-эксплуатация
           пользователь opsagent с минимальными правами, 5 обёрток,
           runbooks по каждому алерту, эскалация к человеку
```

Порядок жёсткий. Обоснование в двух словах:

- **security первым** — потому что всё остальное ставится уже на защищённый
  хост, а не «защитим потом»;
- **vpn-proxy вторым** — потому что дальше сервисы публикуются только внутрь
  VPN, и путь доступа должен существовать раньше сервисов;
- **backup третьим, до данных** — сервис попадает в бэкап в момент установки.
  Если ставить бэкап последним, в набор попадёт то, что вспомнили, а не то, что
  нужно;
- **ent-infra четвёртым** — собственно сервисы;
- **pop-agents последним** — AI-оператор работает поверх готовой
  инфраструктуры, ему нечего эксплуатировать раньше.

## Что где лежит на VPS

```
/opt/corp-infra/                 чекауты реп, root:root 0755
├── bootstrap/                     каноникал lib/common.sh, recon.sh, profiles/
├── security/                      harden.sh, age-escrow.sh, .sops.yaml
├── vpn-proxy/                     install-wireguard.sh, install-proxy.sh, Caddyfile.d/
├── backup/                        install-backup.sh, backup.sh, restore.sh, hooks/
├── ent-infra/                     compose/*.yml, observability/, hooks/
├── pop-agents/                    install-agent.sh, runbooks/
├── wrappers/                      привилегированные обёртки opsagent
└── versions.env                   пины версий шести реп

/etc/corp-infra/                 runtime-конфиги из sops, каталог 0700
└── <service>/.env                 0600, в .gitignore

/srv/corp-infra/                 данные всех stateful-сервисов
├── gitlab/{config,logs,data,backups,etc-gitlab.tar.gz}
├── runner/{config.toml,cache}
├── openproject/{pgdata,assets,dumps}
├── bookstack/{config,mariadb,dumps}
├── observability/{prometheus,loki,grafana,alertmanager}
├── caddy/{public,internal}/data   ACME-аккаунты и сертификаты
└── site/public                    собранная статика Hugo

/var/lib/corp-infra/             состояние оркестрации, 0750
├── state.json                     этап, профиль, версии реп
├── markers/*.json                 события между репами
├── manifests/*.backup-manifest.json  что каждый сервис отдаёт в бэкап
├── recon/{latest.json,history/}
├── escrow/age-key.escrow.json     аттестация escrow (публичный материал)
└── backup/{coverage.json,last-*.json,drills.jsonl}

/var/log/corp-infra/             логи скриптов, 0750
├── <repo>/<script>.log
├── agent/{sessions,escalations,inbox}/
└── sudo-io/

/var/backups/corp-infra/restic-local/    локальный restic-репозиторий

/root/.config/sops/age/keys.txt  0600. НЕ в бэкапе — см. ниже
/etc/wireguard/                  wg0.conf, privatekey, peers/ — В бэкапе, приоритет P1
```

Правило владения: **у каждого пути ровно один хозяин-репа**. Чужой скрипт может
путь читать (для `--check`), но не менять. Отсюда, например, берётся
`request-port.sh` в `security`: это единственный способ для чужого контекста
попросить открыть порт, вместо прямого `ufw allow`.

## Почему приватный age-ключ не в бэкапе

Пароль от restic-репозитория лежит в файле, зашифрованном sops. Sops
расшифровывает его тем самым age-ключом. Положить age-ключ внутрь бэкапа,
который без него не открывается, — значит не получить ничего, кроме
дополнительного риска утечки.

Поэтому ключ хранится **вне VPS**, минимум в двух независимых местах: в общем
(не личном) сейфе командного менеджера паролей, где к нему есть доступ хотя бы у
двух человек, и в офлайн-копии. Установка не идёт дальше этапа `security`, пока
это не подтверждено вручную вводом отпечатка ключа из escrow-копии.

Это не бюрократия. Ровно это отличает «у нас есть бэкапы» от «у нас есть
бэкапы, которые мы можем открыть».

## Куда дальше

| Хочу | Читать |
|---|---|
| Поставить всё с нуля | [`01-quickstart.md`](01-quickstart.md) |
| Понять, какой профиль выбрать | [`02-profiles.md`](02-profiles.md) |
| Разобраться, что показывает `state.sh show` | [`03-state-and-markers.md`](03-state-and-markers.md) |
| Что-то пошло не так | [`04-troubleshooting.md`](04-troubleshooting.md) |
