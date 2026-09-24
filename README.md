# Infrastructure Repository — PizzaShop

Репозиторий для платформенной инфраструктуры внутри Kubernetes-кластера,
которая живёт независимо от жизненного цикла релизов приложения

## Что здесь разворачивается

- **RabbitMQ Cluster Operator** + `RabbitmqCluster` CR для окружений `dev` и `staging`.
  Учётные данные администратора RabbitMQ берутся не из values/env напрямую,
  а из HashiCorp Vault (KV v2) и передаются оператору через `externalSecret`.
- Манифесты для третьего окружения `prom` (`rabbitmq/prom/`) уже лежат в репо,
  но джоб `deploy-rabbitmq-prom` в `.gitlab-ci.yml` пока закомментирован —
  нет `sync-secret-prom`. Включим, когда понадобится.

## Почему отдельный репозиторий

- Инфраструктура (брокеры, операторы, ingress-controller и т.п.) меняется
  значительно реже кода приложения — нет смысла привязывать её обновление
  к релизным тегам оркестратора `cicd`.
- Сбой при обновлении инфраструктуры не должен блокировать релиз приложения,
  и наоборот.

## Предварительные шаги в Vault (выполняются один раз вручную)

Оператор **не пишет** учётные данные в Vault — только читает. Поэтому перед
первым деплоем нужно вручную положить пару username/password:

\`\`\`bash
vault kv put kv/pizzashop/dev/infrastructure username="admin" password="<STRONG_PASSWORD>"
vault kv put kv/pizzashop/staging/infrastructure username="admin" password="<STRONG_PASSWORD>"
\`\`\`

И создать AppRole для чтения этих путей из CI (см. политику в комментариях
`.gitlab-ci.yml`). Полученные `role_id`/`secret_id` добавить в GitLab CI/CD
Variables как `VAULT_ROLE_ID` / `VAULT_SECRET_ID` (Masked + Protected),
а также `VAULT_ADDR` — адрес Vault.

## Порядок деплоя (пайплайн)

1. `install-operator` (manual) — устанавливает RabbitMQ Cluster Operator и CRD
   в кластер. Запускается один раз (или при обновлении версии оператора).
2. `sync-secret-dev` / `sync-secret-staging` — читает creds из Vault,
   создаёт/обновляет Kubernetes `Secret` с ключами `username`/`password`.
3. `deploy-rabbitmq-dev` / `deploy-rabbitmq-staging` — применяет CR
   `RabbitmqCluster` и `Ingress` для management UI.

## Проверка после деплоя

\`\`\`bash
kubectl get rabbitmqcluster -n pizzashop-dev
kubectl get pods,svc -n pizzashop-dev -l app.kubernetes.io/name=rabbitmq
kubectl get secret rabbitmq-default-user-external -n pizzashop-dev -o jsonpath='{.data.username}' | base64 -d
\`\`\`
