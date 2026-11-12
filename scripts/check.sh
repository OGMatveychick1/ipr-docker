#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")/.."

PROJECT="ipr-check-$(date +%s)-$$-$RANDOM"

export APP_PORT=0
export MSYS_NO_PATHCONV=1

dc() {
    docker compose -p "$PROJECT" "$@"
}

printf 'Тестовый проект: %s\n' "$PROJECT"

STAGE="подготовка"

cleanup() {
    result=$?
    trap - EXIT

    if [ "$result" -ne 0 ]; then
        printf 'Ошибка на этапе: %s\n' "$STAGE" >&2
        dc logs --no-color --tail 30 || true
    fi

    if ! dc down -v --remove-orphans --rmi local; then
        printf 'Ошибка на этапе: очистка тестового проекта\n' >&2
        result=1
    fi

    exit "$result"
}

trap cleanup EXIT

STAGE="запуск тестового проекта"
dc up -d --build --wait --wait-timeout 60

ADDRESS="$(dc port app 8000)"

check_count() {
    local expected="$1"
    local method="${2:-GET}"
    local path="${3:-/}"
    local response

    response="$(curl -fsS --connect-timeout 2 --max-time 5 \
        -X "$method" "http://$ADDRESS$path")"

    printf '%s\n' "$response"

    printf '%s\n' "$response" | dc exec -T app python -c '
import json
import sys

actual = json.load(sys.stdin)["count"]
expected = int(sys.argv[1])

print(f"expected={expected}, actual={actual}")
sys.exit(0 if actual == expected else 1)
' "$expected"
}

STAGE="проверка начального значения"
check_count 0

STAGE="увеличение счетчика"
for value in 1 2 3; do
    check_count "$value" POST /increment
done

STAGE="пересоздание приложения"
dc up -d --no-deps --force-recreate --wait --wait-timeout 60 app

ADDRESS="$(dc port app 8000)"

STAGE="проверка сохранения счетчика"
check_count 3

check_status() {
    local expected="$1"
    local method="$2"
    local path="$3"
    local reply
    local code

    reply="$(curl -sS --connect-timeout 2 --max-time 30 \
        -X "$method" -w '\n%{http_code}' "http://$ADDRESS$path")"

    code="${reply##*$'\n'}"

    printf '%s %s: expected=%s, actual=%s\n' \
        "$method" "$path" "$expected" "$code"

    if [ "$code" != "$expected" ]; then
        printf '%s\n' "$reply" >&2
        return 1
    fi
}

STAGE="отключение Redis"

app_id="$(dc ps -q app)"
started_before="$(docker inspect "$app_id" --format '{{.State.StartedAt}}')"

dc stop redis

check_status 200 GET /healthz
check_status 503 GET /readyz
check_status 503 POST /increment

STAGE="восстановление Redis"
dc start redis

deadline=$((SECONDS + 60))

until curl -fsS --connect-timeout 2 --max-time 5 \
    "http://$ADDRESS/readyz" > /dev/null 2>&1; do

    if [ "$SECONDS" -ge "$deadline" ]; then
        printf 'Redis не восстановился за отведенное время\n' >&2
        exit 1
    fi

    sleep 1
done

check_status 200 GET /readyz
check_count 3
check_count 4 POST /increment

started_after="$(docker inspect "$app_id" --format '{{.State.StartedAt}}')"

if [ "$started_before" != "$started_after" ]; then
    printf 'Приложение перезапустилось во время проверки\n' >&2
    exit 1
fi

STAGE="создание резервной копии"

dc stop app
dc stop redis

mkdir -p backups
BACKUP_HOST="$(pwd)/backups"

if command -v cygpath > /dev/null 2>&1; then
    BACKUP_HOST="$(cygpath -m "$BACKUP_HOST")"
fi

dc run --rm --no-deps -T \
    --entrypoint tar \
    --volume "${BACKUP_HOST}:/backup" \
    redis -cpf "/backup/${PROJECT}.tar" -C /data .

STAGE="проверка резервной копии"

test -s "backups/${PROJECT}.tar"

dc run --rm --no-deps -T \
    --entrypoint tar \
    --volume "${BACKUP_HOST}:/backup" \
    redis -tvf "/backup/${PROJECT}.tar"

printf '\nПроверки выполнены. Резервная копия: backups/%s.tar\n' "$PROJECT"
