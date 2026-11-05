#!/usr/bin/env bash
# Проверка окна приложения в изолированной сети: настоящие nfqws2 и nftables, сеть и файрвол компьютера не затрагиваются.
# Прав администратора не требует. Снимки экрана остаются в указанной папке.
#
#   tests/gui-test.sh [ПАПКА_ДЛЯ_СНИМКОВ]
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/zapret-cap-gui-shots}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SANDBOX_GUI="$OUT" exec "$REPO/tests/sandbox-test.sh"
