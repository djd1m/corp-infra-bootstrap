# corp-infra-bootstrap

**EN.** Umbrella repository of the corp-infra set: environment recon, the
canonical shell library, deployment profiles and the five-stage bootstrap of a
corporate infrastructure on a bare VPS.

**RU.** Умбрелла-репозиторий набора corp-infra: разведка окружения, каноническая
shell-библиотека, профили развёртывания и пятиэтапный bootstrap корпоративной
инфраструктуры на голом VPS.

---

## Что это

`corp-infra-bootstrap` — единственная точка входа в набор из шести репозиториев,
который превращает чистый VPS в рабочую корпоративную инфраструктуру: git,
трекер, вики, сайт, VPN, обратный прокси, мониторинг, бэкапы и AI-оператор.

Эта репа сама почти ничего не устанавливает. Она отвечает за **оркестрацию**:

- **разведка** (`recon.sh`) — единственный источник фактов об окружении;
- **профили** (`profiles/*.json`) — сколько чего влезает в машину, с честной
  арифметикой RAM и диска;
- **каталог провайдеров** (`providers/*.json`) — ограничения площадки как
  конфиг, а не как код;
- **общая библиотека** (`lib/common.sh`) — каноникал, который вендорится в
  остальные пять реп;
- **машина состояний** (`bootstrap.sh`) — жёсткий порядок этапов и правило
  перехода между ними.

## Роль умбреллы: порядок пяти этапов

Порядок зафиксирован и не настраивается (ADR-012 §2).

| # | Этап | Репозиторий | Что делает | Маркер |
|---|---|---|---|---|
| 1 | `security` | `corp-infra-security` | Базлайн хоста: sshd, ufw, fail2ban, unattended-upgrades, sysctl, auditd; генерация age-ключа и escrow | `security.hardened`, `secrets.escrow.ok` |
| 2 | `vpn-proxy` | `corp-infra-vpn-proxy` | WireGuard-хаб и два Caddy: публичный и внутренний (только через VPN) | `vpn.ready`, `proxy.ready` |
| 3 | `backup` | `corp-infra-backup` | restic 3-2-1, локальный репозиторий плюс offsite, таймеры, учения | `backup.ready` |
| 4 | `ent-infra` | `corp-infra-ent-infra` | GitLab, трекер, вики, сайт, observability — по составу профиля | `ent-infra.<svc>.installed` |
| 5 | `pop-agents` | `corp-infra-pop-agents` | AI-оператор `opsagent` с минимальными правами и runbooks | `agents.ready` |

**Почему бэкап третьим, а не последним.** Инфраструктура бэкапа готова *до*
появления данных. Сервис попадает в бэкап в момент установки, а не «когда-нибудь
потом» — момент, который на практике не наступает.

**Правило перехода.** Этап N+1 не стартует, пока маркер этапа N не равен `ok`
**и** живой `--check` соответствующей репы не вернул 0. Маркер — это заявление,
а не доказательство: реальность дрейфует от маркеров при любом ручном
вмешательстве (INV-BS-1, INV-GLOBAL-2).

## Быстрый старт

```bash
git clone https://github.com/<org>/corp-infra-bootstrap.git /opt/corp-infra/bootstrap
/opt/corp-infra/bootstrap/scripts/recon.sh --json | python3 -m json.tool
sudo /opt/corp-infra/bootstrap/scripts/bootstrap.sh --profile core-16
```

Первая команда ничего не меняет: `recon.sh --json` только измеряет хост и
печатает JSON. Начните с неё — она же скажет, какой профиль рекомендован и что
мешает установке (`judgments.blockers[]`).

Подробный разбор — [`for-humans/01-quickstart.md`](for-humans/01-quickstart.md).

## Профили

Числа — из технической архитектуры, не из головы. `Σ steady` — установившееся
потребление, `Σ cap` — сумма жёстких лимитов.

| Профиль | vCPU / RAM / Диск | Состав | Σ steady | Σ cap | Трекер |
|---|---|---|---|---|---|
| `all-in-one-32` | 8 / 32 GB / 500 GB | всё, включая OpenProject | 19.28 GB (60 %) | 28.90 GB (90 %) | OpenProject CE |
| **`core-16`** (по умолчанию) | 8 / 16 GB / 350 GB | всё, кроме OpenProject; GitLab memory-constrained | 11.08 GB (69 %) | 16.40 GB (102.5 %) | GitLab issues |
| `two-vps-split-a` | 8 / 16 GB / 350 GB | узел «git»: GitLab и CI | 11.18 GB (70 %) | 16.23 GB (101 %) | — |
| `two-vps-split-b` | 4 / 12 GB / 200 GB | узел «apps»: всё остальное | 7.03 GB (59 %) | 11.10 GB (93 %) | OpenProject CE |

`minimal-8` **не поддерживается**: GitLab на 8 GB выживает только с
memory-constrained тюнингом и не оставляет места ни на что. Документированный
путь для 8 GB — Gitea/Forgejo вместо GitLab, но это другой продукт и другое
решение.

Проверить арифметику можно, ничего не устанавливая:

```bash
./scripts/sizing-check.sh --static --all
```

Подробнее — [`for-humans/02-profiles.md`](for-humans/02-profiles.md).

## Куда идти дальше — четыре трека

| Трек | Кому | Начать с |
|---|---|---|
| Люди | администратору, который ставит всё руками | [`for-humans/00-overview.md`](for-humans/00-overview.md) |
| AI, сильная модель | агенту, который умеет планировать и восстанавливаться после ошибок | [`for-ai-smart/00-goals.md`](for-ai-smart/00-goals.md) |
| AI, слабая модель | агенту, которому нужны точные команды и STOP-гейты | [`for-ai-dumb/00-start-here.md`](for-ai-dumb/00-start-here.md) |
| Любой AI | канонический вход, выбор трека, инварианты | [`AGENTS.md`](AGENTS.md) |

## Проверка «всё ли на месте»

```bash
./scripts/doctor.sh
```

Запускает `recon.sh --check`, `sizing-check.sh --check`, `sync-lib.sh --check` и
`bootstrap.sh --check`, печатает сводную таблицу. Ничего не меняет. Код выхода:
0 — всё зелено, 1 — что-то провалено, 2 — что-то не удалось проверить.

## Соседи

- Умбрелла набора: [обзор шести реп и порядок этапов](../README.md).
- Предыдущего этапа нет — этот репозиторий открывает цепочку.
- Следующий этап: [`corp-infra-security`](../security/README.md) — базлайн хоста,
  ufw с цепочкой DOCKER-USER, секреты sops+age.

Версия репозитория: `1.0.0`. Библиотека: `lib/VERSION` — канонический экземпляр,
из которого `scripts/sync-lib.sh` раздаёт байт-идентичные копии (гейт G-09).

## Лицензия

MIT — см. [`LICENSE`](LICENSE).
