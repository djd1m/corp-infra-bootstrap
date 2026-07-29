# Состояние и маркеры: что установка знает о себе

## Два файла-носителя состояния

| Что | Где | Кто пишет | Что означает |
|---|---|---|---|
| `state.json` | `/var/lib/corp-infra/state.json`, 0640 | **только** bootstrap | какой профиль выбран, какие этапы пройдены, какие версии реп установлены |
| маркеры | `/var/lib/corp-infra/markers/<stage>.json`, 0644 | репа-производитель этапа | «этап заявлен выполненным» |

Транспорта событий между репами нет: никакой шины, никакого демона. Просто
файлы. Это сделано намеренно — состояние можно посмотреть обычным `cat` и
проверить обычным bash.

## `state.json`

```json
{
  "schema_version": 1,
  "host_id": "sha256:9f2c…",
  "profile": "core-16",
  "profile_forced": false,
  "node_role": "single",
  "current_stage": "ent-infra",
  "stages": {
    "security": "ok",
    "vpn-proxy": "ok",
    "backup": "ok",
    "ent-infra": "pending",
    "pop-agents": "pending"
  },
  "repos": { "corp-infra-bootstrap": "1.0.0", "corp-infra-security": "1.0.0" },
  "lib_version": "1.0.0",
  "images": { "gitlab": "18.1.3-ce.0@sha256:…" },
  "last_recon_at": "2026-07-29T10:11:12Z"
}
```

Отдельного внимания заслуживают три поля:

- **`host_id`** — sha256 от `/etc/machine-id`. Позволяет отличить «маркер этого
  хоста» от «маркер, который переехал вместе с восстановленным каталогом». После
  восстановления на новый VPS маркеры старого хоста не будут приняты — и это
  правильно.
- **`profile_forced`** — `true`, только если оператор явно продавил установку
  флагом `--force-profile` при неопределённом вердикте sizing. При разборе
  инцидента сразу видно, что решение принято человеком.
- **`images`** — история digest'ов образов. Восстановление GitLab возможно
  **только** в точно ту же версию, поэтому знать её нужно до катастрофы, а не
  после.

Посмотреть:

```bash
sudo ./scripts/state.sh show
sudo ./scripts/state.sh get profile
sudo ./scripts/state.sh get stages.backup
```

## Маркеры

```json
{
  "schema_version": 1,
  "stage": "security.hardened",
  "status": "ok",
  "repo": "corp-infra-security",
  "repo_version": "1.0.0",
  "lib_version": "1.0.0",
  "applied_at": "2026-07-29T10:11:12Z",
  "host_id": "sha256:9f2c…",
  "evidence": {
    "sshd_effective_sha256": "…",
    "ufw": "active",
    "age_recipient": "age1…",
    "escrow": "ok"
  }
}
```

Закрытое множество имён — других маркеров не бывает:

`security.hardened` · `secrets.escrow.ok` · `vpn.ready` · `proxy.ready` ·
`backup.ready` · `ent-infra.{gitlab,tracker,wiki,site,observability}.installed` ·
`agents.ready`

Запись атомарна: сначала `<file>.tmp`, потом `mv`. Перезапись разрешена — это и
есть идемпотентность.

```bash
sudo ./scripts/state.sh markers
```

## Главное правило: маркер — это заявление, а не доказательство

Маркер говорит: «этап отработал в 10:11». Он не говорит, что **сейчас** всё в
порядке. Между этими утверждениями умещается всё, что происходит с боевым
сервером: кто-то поправил `sshd_config` руками, контейнер упал, кто-то отключил
ufw «на пять минут» три недели назад.

Поэтому потребитель никогда не принимает решение по одному маркеру. Правило
перехода (INV-BS-1, INV-GLOBAL-2):

```
этап N+1 стартует ⟺ маркер этапа N = ok
                    И живой --check репы N вернул 0
```

В коде это функция `require_stage <stage> <live-check-cmd>`, и она требует
**оба** аргумента. Вызвать `state_check` в одиночку и пойти дальше нельзя по
конструкции.

Здесь разрешается противоречие, которое иначе тлело бы в проекте: маркеры удобны
для оркестрации, но реальность от них дрейфует. Ответ — не отказаться от
маркеров и не поверить им, а требовать оба сигнала.

## Как читать `state.sh show`

```
  STAGE          STATE      MARKER
  ---------------------------------------------
  security       ok         ok (security.hardened)
  vpn-proxy      ok         ok (vpn.ready)
  backup         ok         ok (backup.ready)
  ent-infra      pending    absent (ent-infra.gitlab.installed)
  pop-agents     pending    absent (agents.ready)
```

- **STATE** — что записано в `state.json` (мнение bootstrap);
- **MARKER** — что записано в маркере (мнение репы-производителя).

Эта команда живые `--check` не запускает — она быстрая и читает только файлы.
Полная картина, с живыми проверками:

```bash
sudo ./scripts/bootstrap.sh --check
```

```
  STAGE        MARKER     LIVE CHECK   VERDICT
  -------------------------------------------------------------------
  security     ok         ok           ok
  vpn-proxy    ok         ok           ok
  backup       ok         fail         DRIFT
  ent-infra    absent     n/a          pending
  pop-agents   absent     n/a          pending
```

## Что делать при `DRIFT`

`DRIFT` означает: маркер и реальность не согласуются. Два случая.

### Маркер `ok`, живой `--check` — `fail`

Этап когда-то отработал, но сейчас условие нарушено. Это **самый частый и самый
важный** случай.

1. Узнать, что именно сломалось, — запустить проверку руками и прочитать вывод:

   ```bash
   sudo /opt/corp-infra/backup/scripts/install-backup.sh --check
   ```

2. Починить причину. Не маркер.
3. Перезапустить этап:

   ```bash
   sudo ./scripts/bootstrap.sh --stage backup --profile core-16
   ```

**Не удаляйте маркер, чтобы «обойти» проверку.** Это ровно тот сценарий, ради
которого правило двойного сигнала и существует.

### Маркер отсутствует, живой `--check` — `ok`

Этап фактически применён, но маркера нет: типично после ручной установки или
после восстановления `/var/lib/corp-infra` не полностью. Лечится повторным
прогоном этапа — скрипты идемпотентны, повторный запуск на уже настроенной
системе ничего не ломает и просто запишет маркер:

```bash
sudo ./scripts/bootstrap.sh --stage security --profile core-16
```

Отдельный случай — **`host_id` не совпадает**. Значит, каталог состояния
приехал с другого хоста (восстановление из бэкапа). Маркеры чужого хоста не
принимаются намеренно: они описывают не эту машину. Пройдите этапы заново — по
восстановленным конфигам это быстро.

## Recon-история

```
/var/lib/corp-infra/recon/
├── latest.json
└── history/20260729T101112Z.json
```

`latest.json` считается годным 24 часа. Старше — `bootstrap.sh` перезапустит
recon сам. История нужна для сравнения «было / стало»: после инцидента полезно
увидеть, что диск был на 40 % месяц назад, а не всегда на 92 %.

Посмотреть последний:

```bash
sudo ./scripts/state.sh recon | python3 -m json.tool
```

## Права и владельцы

| Путь | Права | Владелец |
|---|---|---|
| `/var/lib/corp-infra/` | 0750 | root:root |
| `state.json` | 0640 | root:root, единственный писатель — bootstrap |
| `markers/*.json` | 0644 | пишет репа-производитель |
| `manifests/*.json` | 0644 | пишет ent-infra |
| `/var/log/corp-infra/` | 0750 | root:root |
| `/etc/corp-infra/` | 0700 | root:root |
| `/etc/corp-infra/<svc>/.env` | 0600 | сервисный пользователь |

Попытка чужой репы записать `state.json` не проходит: функция `state_set`
проверяет контекст вызова и отказывает с предупреждением.
