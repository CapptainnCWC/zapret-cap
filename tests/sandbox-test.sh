#!/usr/bin/env bash
# Проверка утилиты в изолированном сетевом окружении: настоящие nfqws2 и nftables, настоящие соединения,
# но сеть, файрвол и файлы компьютера не затрагиваются. Прав администратора не требует.
#
# Сайты изображает локальный сервер в соседнем сетевом пространстве, поэтому тест показывает:
# - утилита запускает тесты всех стратегий и правильно считает результат;
# - пакеты стратегий не ломают соединение с обычным сервером.
# Обходит ли стратегия настоящий DPI, здесь проверить нельзя.
#
#   tests/sandbox-test.sh           полная проверка
#   tests/sandbox-test.sh ALT5 ALT  только стратегии с указанными короткими именами
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${SANDBOX_STAGE:-}" != inside ]; then
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/zapret-cap-sandbox.XXXXXX")"
	trap 'rm -rf "$WORK"' EXIT
	# работаем с копией: тесты меняют списки и пишут результаты
	mkdir "$WORK/app"
	( cd "$REPO" && tar cf - --exclude=./.git --exclude=./state . ) | tar xf - -C "$WORK/app"
	echo "Сборка nfqws2..."
	make -C "$WORK/app/core/nfq2" -j"$(nproc)" >"$WORK/build.log" 2>&1 || { tail -n 20 "$WORK/build.log"; exit 1; }
	# mount: свой /etc/hosts, чтобы тестовые домены вели на локальный сервер.
	# map-auto: дополнительные uid, иначе nfqws2 не сможет сменить пользователя (нужны /etc/subuid и newuidmap).
	# pid: процессы внутри не видят настоящие и не переживают тест
	chmod 755 "$WORK"
	SANDBOX_STAGE=inside WORK="$WORK" unshare --user --map-auto --map-root-user --net --mount --pid --fork --mount-proc --kill-child bash "${BASH_SOURCE[0]}" "$@"
	exit $?
fi

APP="$WORK/app"
Z="$APP/zapret"
export ZAPRET_RUN="$WORK/run" ZAPRET_STATE="$APP/state" ZAPRET_NO_SYSTEMD=1
export ZAPRET_TARGETS="$WORK/targets.txt"
# uid по умолчанию (0x7FFFFFFF) в этом пространстве не отображён, поэтому берём обычный
export ZAPRET_NFQWS_EXTRA="${SANDBOX_NFQWS_UID:---uid=1000:1000}"
export TEST_CURL_TIMEOUT=3
export HOME="$WORK/home"
mkdir -p "$HOME"
export ZAPRET_CURL_OPTS="-k"
mkdir -p "$ZAPRET_RUN"

# публичный диапазон: частные адреса есть в lists/ipset-exclude.txt, и стратегии их не трогают
SERVER_IP=198.51.100.2
CLIENT_IP=198.51.100.1
FAILED=0
PASSED=0

pass() { PASSED=$((PASSED + 1)); echo "  ok    $*"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL  $*"; }
check()
{
	# check "описание" команда...
	local title="$1"
	shift
	if "$@" >/dev/null 2>&1; then pass "$title"; else fail "$title"; fi
}

# --- окружение

ip link set lo up

cat > "$WORK/hosts" <<EOF
127.0.0.1 localhost
$SERVER_IP discord.com gateway.discord.gg www.youtube.com www.google.com dpi.test reload.example.org
EOF
mount --bind "$WORK/hosts" /etc/hosts

cat > "$WORK/server.py" <<'EOF'
import http.server, socketserver, ssl, sys, threading
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _reply(self):
        n = int(self.headers.get("Content-Length") or 0)
        while n > 0:
            n -= len(self.rfile.read(min(n, 65536)))
        body = b"ok" if self.command != "HEAD" else b""
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(body)
    do_GET = do_HEAD = do_POST = _reply
    def log_message(self, *a): pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
workdir = sys.argv[1]
plain = S(("0.0.0.0", 80), H)
game = S(("0.0.0.0", 5555), H)
threading.Thread(target=game.serve_forever, daemon=True).start()
tls = S(("0.0.0.0", 443), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(workdir + "/cert.pem", workdir + "/key.pem")
tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
threading.Thread(target=plain.serve_forever, daemon=True).start()
tls.serve_forever()
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 2 -subj /CN=test >/dev/null 2>&1

# сервер живёт в отдельном сетевом пространстве и дожидается своего конца кабеля
unshare --net bash -c '
	until ip link show veth1 >/dev/null 2>&1; do sleep 0.05; done
	ip link set lo up
	ip addr add '"$SERVER_IP"'/24 dev veth1
	ip addr add 1.1.1.1/32 dev lo
	ip link set veth1 up
	exec python3 '"$WORK"'/server.py '"$WORK"'
' >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
sleep 0.3
ip link add veth0 type veth peer name veth1 netns "$SERVER_PID"
ip addr add "$CLIENT_IP/24" dev veth0
ip link set veth0 up
ip route add default via "$SERVER_IP" dev veth0 2>/dev/null

for _ in $(seq 1 50); do
	curl -sk -m 1 -o /dev/null "https://$SERVER_IP/" && break
	sleep 0.1
done

cat > "$ZAPRET_TARGETS" <<EOF
DiscordMain = "https://discord.com"
DiscordGateway = "https://gateway.discord.gg"
YouTubeWeb = "https://www.youtube.com"
GoogleMain = "https://www.google.com"
ServerPing = "PING:$SERVER_IP"
EOF

# проверка окна приложения: то же окружение, но вместо команд кнопки нажимает tests/gui_test.py
if [ -n "${SANDBOX_GUI:-}" ]; then
	export XDG_RUNTIME_DIR="$WORK/xdg" XDG_DATA_DIRS="$WORK/share:/usr/share"
	mkdir -p "$XDG_RUNTIME_DIR" "$WORK/share/applications"
	chmod 700 "$XDG_RUNTIME_DIR"
	cp "$APP/data/org.zapretcap.ZapretCap.desktop" "$WORK/share/applications/"
	export GDK_BACKEND=broadway BROADWAY_DISPLAY=:7 GSK_RENDERER=cairo GSETTINGS_BACKEND=memory NO_AT_BRIDGE=1
	export ZAPRET_GUI_NON_UNIQUE=1 ZAPRET_HOME="$APP" MONITOR_HOST=dpi.test MONITOR_TIMEOUT=3 PYTHONDONTWRITEBYTECODE=1
	gtk4-broadwayd :7 --port 8087 --address 127.0.0.1 >"$WORK/broadway.log" 2>&1 &
	sleep 1
	python3 "$REPO/tests/gui_test.py" "$SANDBOX_GUI"
	exit $?
fi

"$Z" list >/dev/null
SELECTION=all
TOTAL="$("$Z" list | grep -cE '^ . +[0-9]+\.')"
TESTED="$TOTAL"
if [ $# -gt 0 ]; then
	SELECTION=""
	for name in "$@"; do
		number="$("$Z" list | grep -E "general \($name\)( |$)" | sed -nE 's/^ . +([0-9]+)\..*/\1/p' | head -n1)"
		SELECTION="$SELECTION${SELECTION:+,}$number"
	done
	TESTED=$#
fi

# показать пакеты стратегии на проводе вместо проверок: SANDBOX_WIRE="ALT13" tests/sandbox-test.sh
if [ -n "${SANDBOX_WIRE:-}" ]; then
	[ -n "${WIRE_DEBUG:-}" ] && export ZAPRET_NFQWS_EXTRA="--uid=0:0 --debug=@$WORK/debug.log"
	[ -n "${WIRE_SETUP:-}" ] && eval "$WIRE_SETUP"
	for name in $SANDBOX_WIRE; do
		echo
		echo "=== $name ==="
		"$Z" use "$name" 2>&1 | head -n1
		python3 "$APP/tests/wire.py" veth0 "${WIRE_SECONDS:-2}" ${WIRE_PORTS:-} > "$WORK/wire.out" &
		DUMP=$!
		until grep -q ready "$WORK/wire.out" 2>/dev/null; do sleep 0.05; done
		if [ -n "${WIRE_CMD:-}" ]; then
			eval "$WIRE_CMD"
		else
			curl -sk -m 2 -o /dev/null -w 'curl: code=%{http_code}\n' ${WIRE_CURL_OPTS:-} "${WIRE_URL:-https://discord.com}"
		fi
		wait "$DUMP"
		tail -n +2 "$WORK/wire.out" | cut -c1-150
		[ -n "${WIRE_DEBUG:-}" ] && { echo "--- nfqws2:"; grep -E "${WIRE_DEBUG}" "$WORK/debug.log" | cut -c1-220 | head -n "${WIRE_DEBUG_LINES:-60}"; : > "$WORK/debug.log"; }
	done
	"$Z" stop >/dev/null 2>&1
	kill "$SERVER_PID" 2>/dev/null
	exit 0
fi

# --- 1. главное: тест стратегий через утилиту

echo
echo "=== Тест стратегий: $TESTED шт. ==="
OUT="$WORK/test.out"
"$Z" test standard "$SELECTION" --apply-best </dev/null >"$OUT" 2>&1
RC=$?
sed -E 's/\x1b\[[0-9;]*m//g' "$OUT" | grep -E 'ERROR|SSL|не запустилась|HTTP OK|Лучшая|сохранены' | cut -c1-120

check "утилита завершилась без ошибки" test "$RC" = 0
RESULT_FILE="$(ls -1 "$APP/utils/test results/"test_results_*.txt 2>/dev/null | tail -n1)"
check "файл результатов создан" test -s "$RESULT_FILE"
check "итоги есть для каждой стратегии" test "$(grep -c 'HTTP OK:' "$RESULT_FILE")" = "$TESTED"
check "ни одна стратегия не упала при запуске" test "$(grep -c 'не запустилась' "$RESULT_FILE")" = 0
# 4 сайта по 3 проверки. HTTPS отвечает, поэтому все 12 должны пройти на любой стратегии
BROKEN="$(grep 'HTTP OK:' "$RESULT_FILE" | grep -vE 'HTTP OK: +12, ERR: +0, UNSUP: +0, Ping OK: +5' | cut -d: -f1)"
check "все стратегии пропускают соединения" test -z "$BROKEN"
[ -n "$BROKEN" ] && printf '        сломались: %s\n' "$BROKEN"
check "лучшая стратегия указана" grep -q '^Best strategy: general' "$RESULT_FILE"
check "лучшая стратегия включена" "$Z" status
CURRENT="$(cat "$ZAPRET_STATE/current" 2>/dev/null)"
check "процесс nfqws2 работает на выбранной стратегии" test "$(cat "$ZAPRET_STATE/running_strategy" 2>/dev/null)" = "$CURRENT"
check "правила nftables установлены" nft list table inet zapret_cap
check "через обход открывается сайт" curl -sk -m 3 -o /dev/null https://www.youtube.com

# --- 2. смена стратегий

echo
echo "=== Смена стратегии ==="
ENGINE_PID="$(cat "$ZAPRET_RUN/nfqws2.pid" 2>/dev/null)"
"$Z" stop >/dev/null 2>&1
check "после выключения правил нет" sh -c '! nft list table inet zapret_cap >/dev/null 2>&1'
check "после выключения процесса нет" test ! -d "/proc/$ENGINE_PID"

check "use по короткому имени" "$Z" use ALT5
check "стратегия ALT5 запущена" test "$(cat "$ZAPRET_STATE/running_strategy" 2>/dev/null)" = "general (ALT5)"
"$Z" next >/dev/null 2>&1
check "next переключает на другую" test "$(cat "$ZAPRET_STATE/running_strategy" 2>/dev/null)" != "general (ALT5)"
check "после next обход работает" test -n "$(cat "$ZAPRET_STATE/running_strategy" 2>/dev/null)"
check "сайт доступен после next" curl -sk -m 3 -o /dev/null https://discord.com
"$Z" auto >"$WORK/auto.out" 2>&1
check "auto не меняет рабочую стратегию" grep -q 'Менять нечего' "$WORK/auto.out"
check "неверная стратегия отвергается" sh -c "! '$Z' use NOSUCH >/dev/null 2>&1"

# порог, который никто не пройдёт: auto должен перебрать всё и оставить лучшую, а не выключенный обход
ZAPRET_AUTO_THRESHOLD=101 "$Z" auto >"$WORK/auto2.out" 2>&1
check "auto при недостижимом пороге всё равно включает лучшую" grep -q 'Включена лучшая' "$WORK/auto2.out"
check "после перебора обход снова работает" test -n "$(cat "$ZAPRET_STATE/running_strategy" 2>/dev/null)"

# --- 3. домены

echo
echo "=== Домены ==="
LIST="$APP/lists/list-general.txt"
"$Z" add 'https://WWW.Example-Site.com:8443/path?x=1' >/dev/null
check "ссылка приведена к домену" grep -qx 'example-site.com' "$LIST"
BEFORE="$(wc -l < "$LIST")"
"$Z" add example-site.com sub.example-site.com >/dev/null
check "дубликат и поддомен не добавляются" test "$(wc -l < "$LIST")" = "$BEFORE"
"$Z" add 'not a domain' 1.2.3.4 'нет' >/dev/null 2>&1
check "мусор и IP не добавляются" test "$(wc -l < "$LIST")" = "$BEFORE"
"$Z" add 'пример.рф' >/dev/null 2>&1
check "кириллический домен в punycode" grep -qx 'xn--e1afmkfd.xn--p1ai' "$LIST"
"$Z" remove example-site.com пример.рф >/dev/null
check "домены удаляются" sh -c "! grep -qE 'example-site.com|xn--e1afmkfd' '$LIST'"

# домен должен заработать без перезапуска. У general запрос к домену из списка начинается с seqovl:
# сегмента с номером 568 байт до начала данных, то есть относительный seq не помещается в 32 бита
domain_is_split()
{
	python3 "$APP/tests/wire.py" veth0 1.5 > "$WORK/reload.out" &
	local dump=$!
	until grep -q ready "$WORK/reload.out" 2>/dev/null; do sleep 0.05; done
	curl -sk -m 1 -o /dev/null https://reload.example.org
	wait "$dump"
	grep -q 'rel=42949' "$WORK/reload.out"
}
"$Z" use general >/dev/null 2>&1
if domain_is_split; then fail "домен вне списка не должен обрабатываться"; else pass "домен вне списка не обрабатывается"; fi
"$Z" add reload.example.org >/dev/null
sleep 0.2
check "новый домен работает без перезапуска" domain_is_split
"$Z" remove reload.example.org >/dev/null
sleep 0.2
if domain_is_split; then fail "удалённый домен не должен обрабатываться"; else pass "удалённый домен больше не обрабатывается"; fi

# --- 4. настройки

echo
echo "=== Настройки ==="
"$Z" game all </dev/null >/dev/null 2>&1
"$Z" use ALT5 >/dev/null 2>&1
check "фильтр игр: порты в правилах" sh -c "nft list table inet zapret_cap | grep -q '1024-65535'"
check "фильтр игр: порты в профиле nfqws2" sh -c "tr '\0' ' ' < /proc/\$(cat '$ZAPRET_RUN/nfqws2.pid')/cmdline | grep -q -- '--filter-tcp=1024-65535'"
check "соединения работают с фильтром игр" curl -sk -m 3 -o /dev/null https://discord.com
"$Z" game off </dev/null >/dev/null 2>&1
"$Z" game-ports tcp '70000' </dev/null >/dev/null 2>&1
check "неверные порты отвергаются" sh -c "! grep -q 70000 '$APP/utils/game_filter.enabled'"

IPSET="$APP/lists/ipset-all.txt"
IPSET_ORIG="$(sha256sum < "$IPSET")"
"$Z" ipset loaded >/dev/null
check "ipset: loaded" test "$(grep -c . "$IPSET")" -gt 1000
"$Z" ipset none >/dev/null
check "ipset: none" grep -qx '203.0.113.113/32' "$IPSET"
"$Z" ipset any >/dev/null
check "ipset: any" test ! -s "$IPSET"
"$Z" ipset none >/dev/null
check "ipset: исходное состояние вернулось" test "$(sha256sum < "$IPSET")" = "$IPSET_ORIG"

# --- iptables вместо nftables

echo
echo "=== iptables ==="
if command -v iptables >/dev/null 2>&1; then
	"$Z" stop >/dev/null 2>&1
	export ZAPRET_FW=iptables
	check "обход запускается" "$Z" use general
	check "правила iptables установлены" iptables -t mangle -S zapret_cap_post
	check "соединения работают" curl -sk -m 3 -o /dev/null https://discord.com
	check "syndata работает" "$Z" use ALT5
	check "соединения работают с syndata" curl -sk -m 3 -o /dev/null https://discord.com
	"$Z" stop >/dev/null 2>&1
	check "правила iptables убраны" sh -c '! iptables -t mangle -S zapret_cap_post >/dev/null 2>&1'
	unset ZAPRET_FW
fi

# --- 5. DPI-тест

echo
echo "=== DPI-тест ==="
MONITOR_HOST=dpi.test MONITOR_TIMEOUT=3 "$Z" test dpi 1 </dev/null >"$WORK/dpi.out" 2>&1
check "DPI-тест отработал" grep -q 'BLOCKED:' "$WORK/dpi.out"
check "DPI-тест: ipset возвращён" test "$(sha256sum < "$IPSET")" = "$IPSET_ORIG"
check "DPI-тест: временных файлов нет" test ! -e "$APP/lists/ipset-all.test-backup.txt"

# --- 6. прерывание

echo
echo "=== Прерывание теста ==="
"$Z" use general >/dev/null 2>&1
rm -f "$ZAPRET_STATE/last-test.tsv"
"$Z" test standard all </dev/null >/dev/null 2>&1 &
TEST_PID=$!
sleep 2
# TERM, а не INT: фоновым задачам скрипта оболочка отключает SIGINT
STARTED=$SECONDS
kill -TERM "$TEST_PID" 2>/dev/null
wait "$TEST_PID" 2>/dev/null
check "тест останавливается сразу" test $((SECONDS - STARTED)) -lt 8
check "прерванный тест не записал итог" test ! -e "$ZAPRET_STATE/last-test.tsv"
check "после прерывания стратегия пользователя восстановлена" test "$(cat "$ZAPRET_STATE/running_strategy" 2>/dev/null)" = "general"
"$Z" stop >/dev/null 2>&1
check "после выключения всё чисто" sh -c '! nft list table inet zapret_cap >/dev/null 2>&1'

# --- 7. меню и диагностика

echo
echo "=== Меню и диагностика ==="
# меню и подсказки ведут себя иначе в настоящем терминале
python3 "$APP/tests/pty_run.py" "$Z" "$WORK/menu.out" 6 '' 10 '' 12 '' 12 '' 12 '' 7 '' 7 '' 14 '' 14 '' 11 0 4 2 '' 6 '' 5 '' 0
check "меню завершается по пункту 0" test $? = 0
check "меню открывается и закрывается" grep -q 'Выберите пункт' "$WORK/menu.out"
check "пункты меню работают без ошибок" sh -c "! grep -E 'unbound variable|command not found|syntax error|ambiguous redirect' '$WORK/menu.out'"
check "выбор стратегии из меню" grep -q 'Включена стратегия' "$WORK/menu.out"
"$Z" diag </dev/null >"$WORK/diag.out" 2>&1
check "диагностика отработала" grep -q 'Путь установки' "$WORK/diag.out"
check "в диагностике нет ошибок оболочки" sh -c "! grep -E 'unbound variable|command not found|syntax error' '$WORK/diag.out'"
"$Z" stop >/dev/null 2>&1

# --- 8. установка

echo
echo "=== Установка ==="
unset ZAPRET_STATE
mkdir -p "$WORK/opt" "$WORK/localbin" "$WORK/apps" "$WORK/stub"
mount --bind "$WORK/opt" /opt
mount --bind "$WORK/localbin" /usr/local/bin
mount --bind "$WORK/apps" /usr/share/applications
# настоящий systemd недоступен и не должен быть затронут
printf '#!/bin/sh\nexit 1\n' > "$WORK/stub/systemctl"
chmod +x "$WORK/stub/systemctl"
rm -f "$APP/core/nfq2/nfqws2"
PATH="$WORK/stub:$PATH" ZAPRET_SKIP_PACKAGES=1 "$APP/install.sh" </dev/null >"$WORK/install.out" 2>&1
check "установка прошла" grep -q 'Готово' "$WORK/install.out"
check "движок собран" test -x /opt/zapret-cap/core/nfq2/nfqws2
check "команда zapret доступна" test -x /usr/local/bin/zapret
check "ярлык создан" test -f /usr/share/applications/zapret-cap.desktop
check "файлы доступны всем на чтение" sh -c "! find /opt/zapret-cap \( -type d ! -perm -005 -o -type f ! -perm -004 \) | grep -q ."
check "работает из нового места" /usr/local/bin/zapret use ALT5
check "сайт открывается" curl -sk -m 3 -o /dev/null https://discord.com
/usr/local/bin/zapret add keep.example.org >/dev/null
printf 'PORTS_TCP=443\nPORTS_UDP=443\n--filter-tcp=443 --lua-desync=multisplit\n' > /opt/zapret-cap/strategies/mine.conf
PATH="$WORK/stub:$PATH" ZAPRET_SKIP_PACKAGES=1 "$APP/install.sh" </dev/null >"$WORK/install2.out" 2>&1
check "обновление сохраняет домены" grep -qx keep.example.org /opt/zapret-cap/lists/list-general.txt
check "обновление сохраняет свои стратегии" test -f /opt/zapret-cap/strategies/mine.conf
check "обновление возвращает работавший обход" test "$(cat /opt/zapret-cap/state/running_strategy 2>/dev/null)" = "general (ALT5)"
check "своя стратегия запускается" /usr/local/bin/zapret use mine
/usr/local/bin/zapret stop >/dev/null 2>&1

if [ -n "${SANDBOX_SHOW:-}" ]; then
	sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r$//' "$OUT" | head -n 40
	sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r$//' "$WORK/menu.out" | head -n 46
	sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$WORK/diag.out"
	"$Z" list | head -n 6
fi

echo
echo "Пройдено: $PASSED, ошибок: $FAILED"
kill "$SERVER_PID" 2>/dev/null
[ "$FAILED" = 0 ]
