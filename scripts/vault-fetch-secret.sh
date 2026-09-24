#!/bin/sh
# Читает username/password из Vault KV v2 и создаёт Kubernetes Secret в формате,
# который ждёт RabbitMQ Cluster Operator (secretBackend.externalSecret): нужны
# ключи username, password И default_user.conf (INI-файл) — без него
# init-контейнер setup-container не смонтирует volume rabbitmq-confd, и под
# навечно повиснет в Init:0/1.

set -e

if [ -z "$VAULT_ADDR" ] || [ -z "$VAULT_ROLE_ID" ] || [ -z "$VAULT_SECRET_ID" ]; then
  echo "❌ Не заданы VAULT_ADDR / VAULT_ROLE_ID / VAULT_SECRET_ID"
  exit 1
fi

echo "🔐 Логинимся в Vault через AppRole..."
LOGIN_RESPONSE=$(curl -s --request POST \
  --data "{\"role_id\": \"${VAULT_ROLE_ID}\", \"secret_id\": \"${VAULT_SECRET_ID}\"}" \
  "${VAULT_ADDR}/v1/auth/approle/login")

VAULT_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.auth.client_token // empty')

if [ -z "$VAULT_TOKEN" ]; then
  echo "❌ Не удалось получить Vault token. Ответ Vault:"
  echo "$LOGIN_RESPONSE"
  exit 1
fi
echo "✅ Vault token получен"

echo "📥 Читаем секрет kv/data/${VAULT_KV_PATH}..."
SECRET_RESPONSE=$(curl -s \
  --header "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/kv/data/${VAULT_KV_PATH}")

RABBIT_USER=$(echo "$SECRET_RESPONSE" | jq -r '.data.data.username // empty')
RABBIT_PASS=$(echo "$SECRET_RESPONSE" | jq -r '.data.data.password // empty')

if [ -z "$RABBIT_USER" ] || [ -z "$RABBIT_PASS" ]; then
  echo "❌ Не удалось прочитать username/password по пути kv/data/${VAULT_KV_PATH}"
  echo "$SECRET_RESPONSE"
  exit 1
fi
echo "✅ Credentials получены (username: ${RABBIT_USER})"

# Формируем default_user.conf в точности как это делает сам оператор
DEFAULT_USER_CONF="default_user = ${RABBIT_USER}
default_pass = ${RABBIT_PASS}"

echo "📝 Создаём/обновляем Kubernetes Secret '${K8S_SECRET_NAME}' в ns '${NAMESPACE}'..."
kubectl create secret generic "${K8S_SECRET_NAME}" \
  -n "${NAMESPACE}" \
  --from-literal=username="${RABBIT_USER}" \
  --from-literal=password="${RABBIT_PASS}" \
  --from-literal=default_user.conf="${DEFAULT_USER_CONF}" \
  --dry-run=client -o yaml | kubectl apply -f -

curl -s --header "X-Vault-Token: ${VAULT_TOKEN}" \
  --request POST "${VAULT_ADDR}/v1/auth/token/revoke-self" > /dev/null

echo "✅ Secret ${K8S_SECRET_NAME} обновлён (username, password, default_user.conf), Vault token отозван"
