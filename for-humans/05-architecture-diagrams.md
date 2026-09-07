# Шаблоны схем архитектуры

Это обезличенное представление целевой архитектуры. Оно описывает роли,
границы доверия и сетевые пути, но намеренно не содержит реальных доменов,
IP-адресов, имён пользователей, провайдеров или секретов.

Обозначения вроде `PUBLIC_DOMAIN`, `PUBLIC_HOST_IP` и `VPN_HUB_IP` — шаблонные
роли. Их не нужно заменять реальными значениями в опубликованной версии.

## High-level: сервисы и границы

```mermaid
flowchart LR
    employee[Сотрудники<br/>обычный браузер]
    operator[Оператор<br/>WireGuard-клиент]
    internet((Интернет))

    employee --> internet
    operator -->|VPN-туннель| app_vps

    subgraph app_vps[VPS A — приложения и периметр]
        public_proxy[Public reverse proxy<br/>PUBLIC_HOST_IP]
        internal_proxy[Internal reverse proxy<br/>VPN_HUB_IP]
        mattermost[Mattermost]
        openproject[OpenProject]
        grafana[Grafana и админ-сервисы]
        app_data[(Базы приложений)]
        local_backup[(Локальная backup-копия)]

        public_proxy --> mattermost
        public_proxy --> openproject
        internal_proxy --> grafana
        mattermost --> app_data
        openproject --> app_data
        app_data --> local_backup
    end

    internet -->|HTTPS: PUBLIC_DOMAIN| public_proxy

    subgraph git_vps[VPS B — Git-платформа]
        gitlab[GitLab CE]
        runner[Runner]
        git_data[(Git-данные)]
        gitlab --> git_data
        runner --> gitlab
    end

    operator -->|приватный административный путь| git_vps
    app_vps -. резервные копии .-> offsite[(Offsite backup storage)]
    git_vps -. резервные копии .-> offsite
```

Основное правило: Mattermost и OpenProject — явно публичные бизнес-сервисы;
Grafana и административные поверхности доступны только по приватному пути.
Git-платформа находится на отдельном сервере и не устанавливается на VPS A.

## Low-level: сетевые пути внутри VPS A

```mermaid
flowchart TB
    public_client[Публичный клиент]
    vpn_client[VPN-клиент]

    subgraph host[VPS A]
        ext_if[Внешний интерфейс<br/>PUBLIC_HOST_IP]
        wg_if[WireGuard-интерфейс<br/>VPN_HUB_IP]
        firewall[Host firewall<br/>default deny]

        public_caddy[corp-caddy-public<br/>bind: PUBLIC_HOST_IP only]
        internal_caddy[corp-caddy-internal<br/>bind: VPN_HUB_IP only]

        subgraph mm_front[Mattermost frontend network]
            mm_web[Mattermost web]
        end
        subgraph op_front[OpenProject frontend network]
            op_web[OpenProject web]
        end
        subgraph admin_front[Internal proxy network]
            admin_web[Grafana / admin endpoints]
        end

        subgraph private_data[Backend networks — internal only]
            mm_db[(Mattermost DB)]
            op_db[(OpenProject DB/cache)]
            metrics[(Metrics and logs)]
        end

        ext_if --> firewall --> public_caddy
        wg_if --> firewall --> internal_caddy
        public_caddy -->|отдельное ACL-подключение| mm_web
        public_caddy -->|отдельное ACL-подключение| op_web
        internal_caddy --> admin_web
        mm_web --> mm_db
        op_web --> op_db
        admin_web --> metrics
    end

    public_client -->|HTTP/HTTPS| ext_if
    vpn_client -->|VPN| wg_if
```

Инварианты шаблона:

- public и internal proxy привязаны к разным явным адресам; wildcard отсутствует;
- приложения не публикуют host-порты;
- каждый публичный сервис получает отдельную frontend-сеть;
- базы, cache, метрики и логи остаются в backend-сетях без внешнего маршрута;
- секреты существуют только как SOPS-зашифрованные файлы и runtime-файлы 0600;
- backup вводится до появления данных приложений;
- GitLab относится к VPS B и пропускается при установке VPS A.
