# profiles/ — профили развёртывания

**EN.** Machine-readable deployment profiles: RAM and disk budgets per service,
validated against `../schemas/profile.schema.json` and recomputed by gates
G1–G4.

**RU.** Машиночитаемые профили развёртывания: бюджеты RAM и диска по сервисам,
валидируются против `../schemas/profile.schema.json`, пересчитываются гейтами
G1–G4.

---

## Зачем это нужно

Профиль — единственное место, где записано, **что именно** ставится на машину и
**сколько памяти и диска** каждому компоненту разрешено. Дальше всё считается из
него: лимиты в compose, `MemoryMax=` в systemd-слайсах, вердикт `recon.sh`,
проверка перед установкой каждого сервиса.

Числа не выдуманы. Они взяты из таблицы базовых бюджетов технической
архитектуры (05_architecture §1) и просуммированы в §2.3–2.5. Статический гейт в
CI пересчитывает их заново — если таблица в документе и JSON разойдутся, CI это
поймает.

## Четыре профиля

| Файл | `node_role` | vCPU / RAM / Диск | Σ steady | Σ cap | `contention_policy` | Трекер |
|---|---|---|---|---|---|---|
| `all-in-one-32.json` | `single` | 8 / 32768 MB / 500 GB | 19742 MB (60 %) | 29593 MB (90 %) | `slices-v1` | OpenProject CE |
| `core-16.json` **(default)** | `single` | 8 / 16384 MB / 350 GB | 11345 MB (69 %) | 16793 MB (102.5 %) | `slices-v1` | GitLab issues |
| `two-vps-split-a.json` | `git` | 8 / 16384 MB / 350 GB | 11448 MB (70 %) | 16619 MB (101 %) | `slices-v1` | — |
| `two-vps-split-b.json` | `apps` | 4 / 12288 MB / 200 GB | 7198 MB (59 %) | 11366 MB (93 %) | `null` | OpenProject CE |

Ровно один профиль имеет `"default": true`. Это проверяется гейтом.

## Четыре гейта

| Гейт | Условие | Смысл |
|---|---|---|
| **G1** | `Σ steady ≤ 0.75 × RAM` | остаётся не меньше 25 % на page cache, всплески и рост |
| **G2** | `Σ cap ≤ 1.10 × RAM` | overcommit допустим, но ограничен; выше — OOM реален |
| **G3** | если `Σ cap > 1.00 × RAM`, профиль **обязан** объявить `contention_policy` | честное признание overcommit плюс механизм его разрешения |
| **G4** | `disk_total ≥ Σ disk × 1.15` | запас на рост репозиториев и снапшотов |

Пятый гейт **G5** живёт не здесь, а в момент установки каждого сервиса:
`MemAvailable ≥ steady(сервис) + 512 MB`. Он не даёт «долить» сервис в уже
переполненный хост. Реализация — функция `headroom_check` в `../lib/common.sh`.

Проверить всё, ничего не устанавливая:

```bash
../scripts/sizing-check.sh --static --all
```

## Честный overcommit в `core-16`

У профиля по умолчанию `Σ cap` = 16793 MB против 16384 MB физической памяти —
превышение на 409 MB. Это не ошибка и не округление: это означает, что
**одновременный пик GitLab, CI-джобы и бэкапа физически невозможен**.

Именно поэтому G3 требует объявить `contention_policy: "slices-v1"` и заполнить
блок `slices`. Кто именно становится жертвой при нехватке памяти, решается
заранее и записано в профиле:

| Слайс | Кто внутри | Роль при нехватке |
|---|---|---|
| `corp-core` | Caddy ×2, GitLab, observability, BookStack, OpenProject | защищён, `systemd-oomd` его не трогает |
| `corp-ci` | gitlab-runner и job-контейнеры | **первая жертва** |
| `corp-backup` | restic, quiesce-хуки, дампы | окно 03:00–05:00, после дренажа CI |
| `corp-agent` | opsagent | вторая жертва |

Кому overcommit неприемлем — `two-vps-split` или `all-in-one-32`.

## Структура файла

Обязательные поля перечислены в `../schemas/profile.schema.json`. Ключевые:

- `services[]` — то, что видит пользователь. `id` из закрытого множества:
  `gitlab`, `tracker`, `wiki`, `site`, `observability`.
- `platform[]` — то, что есть всегда. `id` из закрытого множества:
  `os-docker`, `wireguard`, `caddy`, `backup`, `opsagent`, `runner`, `ci-slot`.
- `offsite` — цель офсайт-бэкапа. **Конфиг, а не код**: смена цели с B2 на
  Yandex Object Storage KZ — это изменение значения `offsite.primary` и
  подстановка соответствующего env-шаблона в репе `backup`. Ни одна строка
  `backup.sh` не меняется.
- `vpn` — `hub_role` (`self` или `external`) и `provider_policy` — id записи из
  `../providers/`. Тоже конфиг: если провайдер запрещает VPN-хаб в данной
  локации, ставится `hub_role: external`, а код `install-wireguard.sh` остаётся
  прежним.

Сервис с `steady_mb: 0, cap_mb: 0` — не ошибка. Так выглядят варианты, которые
не потребляют RAM: статический сайт Hugo и трекер в варианте
`gitlab-issues` (то есть отдельного трекера нет).

## Как выбрать профиль

1. Запустите `../scripts/recon.sh --json` и посмотрите
   `judgments.profile_recommended`.
2. Если нужен OpenProject и на машине 32 GB — берите `all-in-one-32`.
3. Если нужны и полноценный CI, и OpenProject, но 32 GB одной машиной не
   выходит — `two-vps-split-a` на узле git и `two-vps-split-b` на узле apps.
4. Во всех остальных случаях — `core-16`.

Переопределить рекомендацию: `bootstrap.sh --profile <name>`.
