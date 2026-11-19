# Тесты стратегий: перенос utils/test zapret.ps1 из Windows-версии

DPI_SUITE_URL="https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.v2.json"

tests_defaults()
{
	local cpus default_parallel
	cpus="$(nproc 2>/dev/null || echo 4)"
	default_parallel=$(( cpus * 2 ))
	[ "$default_parallel" -lt 8 ] && default_parallel=8
	[ "$default_parallel" -gt 16 ] && default_parallel=16
	# те же переменные окружения, что и в Windows-версии
	DPI_TIMEOUT=${MONITOR_TIMEOUT:-5}
	DPI_RANGE=${MONITOR_RANGE:-65536}
	DPI_PARALLEL=${MONITOR_MAX_PARALLEL:-$default_parallel}
	CURL_TIMEOUT=${TEST_CURL_TIMEOUT:-4}
	TEST_PARALLEL=${TEST_MAX_PARALLEL:-$default_parallel}
	TARGETS_FILE=${ZAPRET_TARGETS:-$UTILS_DIR/targets.txt}
	# дополнительные опции curl, например --interface
	read -r -a CURL_EXTRA <<< "${ZAPRET_CURL_OPTS:-}"
	# загрузка видео: ролик Blender Foundation, аудиодорожка 140 весит 10,3 МБ
	VIDEO_URL=${ZAPRET_VIDEO_URL:-https://www.youtube.com/watch?v=aqz-KE-bpKQ}
	VIDEO_FORMAT=${ZAPRET_VIDEO_FORMAT:-140/251/ba}
	# сколько секунд даётся на загрузку и сколько секунд без данных считается зависанием
	VIDEO_TIMEOUT=${TEST_VIDEO_TIMEOUT:-20}
	VIDEO_STALL=${TEST_VIDEO_STALL:-5}
	read -r -a VIDEO_EXTRA <<< "${ZAPRET_YTDLP_OPTS:-}"
}

# --- сохранённые итоги тестов

# имя, ok, ошибки, не поддерживается, ping ok, ping нет
RESULTS_STD="$STATE_DIR/last-test.tsv"
# имя, ok, ошибки, не поддерживается, замирания
RESULTS_DPI="$STATE_DIR/last-dpi.tsv"
# имя, скачано целиком (1/0), зависло (1/0), байт, миллисекунд, размер файла
RESULTS_VID="$STATE_DIR/last-video.tsv"

# Новые строки заменяют прежние итоги тех же стратегий, итоги остальных сохраняются
results_merge()
{
	local file="$1" new="$2" tmp
	[ -f "$file" ] || : > "$file"
	tmp="$(mktemp "$file.XXXXXX")"
	awk -F'\t' 'NR == FNR { fresh[$1] = 1; next } !($1 in fresh)' "$new" "$file" > "$tmp"
	cat "$new" >> "$tmp"
	chmod 644 "$tmp"
	mv -f "$tmp" "$file"
}

# К именам со входа дописывает итоги из трёх файлов: 5 полей теста сайтов, 4 поля DPI-теста, 5 полей теста видео.
# Пустое поле - тест не запускался
results_join()
{
	awk -F'\t' -v OFS='\t' -v std="$1" -v dpi="$2" -v vid="$3" '
		function load(file, count, into,   line, f, i, v) {
			while ((getline line < file) > 0) {
				split(line, f, "\t")
				v = f[2]
				for (i = 3; i <= count + 1; i++) v = v "\t" f[i]
				into[f[1]] = v
			}
			close(file)
		}
		function blank(count,   v, i) {
			v = ""
			for (i = 1; i < count; i++) v = v "\t"
			return v
		}
		BEGIN { load(std, 5, s); load(dpi, 4, d); load(vid, 5, w) }
		{ print $0, (($0 in s) ? s[$0] : blank(5)), (($0 in d) ? d[$0] : blank(4)), (($0 in w) ? w[$0] : blank(5)) }'
}

# Все стратегии с сохранёнными итогами: имя и 14 полей, см. results_join
strategy_table()
{
	strategy_names | results_join "$RESULTS_STD" "$RESULTS_DPI" "$RESULTS_VID"
}

# Порядок от лучшей к худшей: сначала доля открытых сайтов, при равенстве - меньшая доля замираний,
# затем загрузка видео (скачалось, медленно, зависло, не скачалось; внутри - скорость с точностью до двух раз),
# затем больше ответов на ping. Открытие сайтов главное: стратегия, которая их не открывает, бесполезна.
# Читает строки strategy_table, печатает имена. Стратегии без итогов идут последними в обычном порядке
strategy_rank()
{
	awk -F'\t' -v OFS='\t' '{
		n++
		tested = ($2 != "" || $7 != "" || $11 != "")
		site = ($2 != "" && $2 + $3 > 0) ? int($2 * 1000 / ($2 + $3)) : -1
		freeze = ($7 != "" && $7 + $8 + $10 > 0) ? int($10 * 1000 / ($7 + $8 + $10)) : 1001
		if ($11 == "") {
			video = 9999
		} else {
			kind = ($11 == 1) ? 0 : (($12 == 1) ? 2 : (($13 > 0) ? 1 : 3))
			speed = ($14 > 0) ? $13 / $14 : 0
			video = kind * 100 + 60 - ((speed >= 1) ? int(log(speed) / log(2)) : 0)
		}
		ping = ($5 != "") ? $5 : -1
		print (tested ? 0 : 1), 1000 - site, freeze, video, 1000 - ping, n, $1
	}' | sort -t $'\t' -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n -k6,6n | cut -f7
}

# awk-функция для итога загрузки видео: "8,3 МБ/с", "120 КБ/с, не докачалось", "зависло на 18 КБ", "не скачалось".
# Дробная часть через запятую и без printf: он зависит от локали
AWK_VIDEO_TEXT='
	function dec(x,   t) { t = int(x * 10 + 0.5); return int(t / 10) "," (t % 10) }
	function vsize(b) { return (b >= 1000000) ? dec(b / 1000000) " МБ" : int(b / 1000) " КБ" }
	function vspeed(b, ms,   s) { s = (ms > 0) ? b / ms : 0; return (s >= 1000) ? dec(s / 1000) " МБ/с" : int(s) " КБ/с" }
	function video_text(ok, stall, b, ms) {
		if (ok == 1) return vspeed(b, ms)
		if (stall == 1) return "зависло на " vsize(b)
		if (b > 0) return vspeed(b, ms) ", не докачалось"
		return "не скачалось"
	}'

video_text()
{
	awk -v ok="$1" -v stall="$2" -v b="$3" -v ms="$4" "$AWK_VIDEO_TEXT"' BEGIN { print video_text(ok, stall, b, ms) }'
}

video_size()
{
	awk -v b="$1" "$AWK_VIDEO_TEXT"' BEGIN { print vsize(b) }'
}

# Итоги для человека: имя и текст через табуляцию. read здесь не годится: идущие подряд табуляции он склеивает
strategy_summaries()
{
	strategy_table | awk -F'\t' -v OFS='\t' "$AWK_VIDEO_TEXT"'
	$2 != "" || $7 != "" || $11 != "" {
		text = ($2 != "") ? "сайты " $2 "/" ($2 + $3) : "сайты не проверены"
		text = text (($7 != "") ? ", замирание " $10 "/" ($7 + $8 + $10) : ", замирание не проверено")
		text = text (($11 != "") ? ", видео " video_text($11, $12, $13, $14) : ", видео не проверено")
		print $1, text
	}'
}

# --- ipset на время DPI-теста

ipset_test_any()
{
	local list="$LISTS_DIR/ipset-all.txt"
	cp -f "$list" "$LISTS_DIR/ipset-all.test-backup.txt" 2>/dev/null || : > "$LISTS_DIR/ipset-all.test-backup.txt"
	: > "$list"
	: > "$STATE_DIR/ipset_switched.flag"
}

ipset_test_restore()
{
	if [ -f "$STATE_DIR/ipset_switched.flag" ]; then
		[ -f "$LISTS_DIR/ipset-all.test-backup.txt" ] && mv -f "$LISTS_DIR/ipset-all.test-backup.txt" "$LISTS_DIR/ipset-all.txt"
		rm -f "$STATE_DIR/ipset_switched.flag"
	fi
}

# --- цели

# читает targets.txt в массивы TARGET_NAMES и TARGET_VALUES
targets_load()
{
	local line
	TARGET_NAMES=()
	TARGET_VALUES=()
	if [ -f "$TARGETS_FILE" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*\"(.+)\"[[:space:]]*$ ]]; then
				TARGET_NAMES+=("${BASH_REMATCH[1]}")
				TARGET_VALUES+=("${BASH_REMATCH[2]}")
			fi
		done < "$TARGETS_FILE"
	fi
	if [ ${#TARGET_NAMES[@]} -eq 0 ]; then
		echo "targets.txt пуст или отсутствует - использую цели по умолчанию."
		TARGET_NAMES=(DiscordMain DiscordGateway DiscordCDN DiscordUpdates YouTubeWeb YouTubeShort YouTubeImage YouTubeVideoRedirect GoogleMain GoogleGstatic CloudflareWeb CloudflareCDN CloudflareDNS1111 CloudflareDNS1001 GoogleDNS8888 GoogleDNS8844 Quad9DNS9999)
		TARGET_VALUES=(https://discord.com https://gateway.discord.gg https://cdn.discordapp.com https://updates.discord.com https://www.youtube.com https://youtu.be https://i.ytimg.com https://redirector.googlevideo.com https://www.google.com https://www.gstatic.com https://www.cloudflare.com https://cdnjs.cloudflare.com PING:1.1.1.1 PING:1.0.0.1 PING:8.8.8.8 PING:8.8.4.4 PING:9.9.9.9)
	fi
	TARGET_NAME_WIDTH=10
	local name
	for name in "${TARGET_NAMES[@]}"; do
		[ ${#name} -gt "$TARGET_NAME_WIDTH" ] && TARGET_NAME_WIDTH=${#name}
	done
}

# Один запрос. Выводит токен: OK, SSL, UNSUP или ERROR
#
# Windows-скрипт считает любой код 35 признаком UNSUP, потому что так schannel сообщает о неподдерживаемой
# версии TLS. У curl с OpenSSL код 35 - это ещё и обрыв рукопожатия, то есть типичная блокировка DPI.
# Поэтому UNSUP здесь определяется только по тексту ошибки, иначе заблокированные сайты выглядели бы "неподдерживаемыми"
probe_http()
{
	local url="$1" stderr rc
	shift
	stderr="$(curl -I -s --show-error -m "$CURL_TIMEOUT" --connect-timeout "$(( CURL_TIMEOUT < 2 ? CURL_TIMEOUT : 2 ))" \
		-o /dev/null -w '%{http_code}' "${CURL_EXTRA[@]}" "$@" "$url" 2>&1 >/dev/null)"
	rc=$?
	if [ $rc -eq 0 ]; then
		printf 'OK'
	elif [ $rc -eq 6 ] || [ $rc -eq 60 ] || [[ "$stderr" =~ Could\ not\ resolve\ host|certificate|self[-\ ]?signed|unable\ to\ get\ local\ issuer ]]; then
		# DNS подменён или сайт отдаёт чужой сертификат
		printf 'SSL'
	elif [ $rc -eq 1 ] || [ $rc -eq 2 ] || [ $rc -eq 4 ] || [[ "$stderr" =~ does\ not\ support|not\ supported|[Uu]nsupported\ protocol|alert\ protocol\ version|no\ protocols\ available|Unrecognized\ option|Unknown\ option|unsupported\ (option|feature) ]]; then
		printf 'UNSUP'
	else
		printf 'ERROR'
	fi
}

probe_ping()
{
	local out
	if out="$(ping -c 1 -W 1 "$1" 2>/dev/null)"; then
		out="$(printf '%s' "$out" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -n1)"
		[ -n "$out" ] && { printf '%.0f ms' "$out"; return; }
	fi
	printf 'Timeout'
}

# проверяет одну цель, пишет файл вида "токены|пинг|url(1 или 0)"
check_target()
{
	local value="$1" out="$2" url="" ping_target tokens=()
	if [[ "$value" == PING:* ]]; then
		ping_target="${value#PING:}"
		ping_target="${ping_target# }"
	else
		url="$value"
		ping_target="${url#*://}"
		ping_target="${ping_target%%[/:]*}"
	fi
	if [ -n "$url" ]; then
		tokens+=("HTTP:$(probe_http "$url" --http1.1)")
		tokens+=("TLS1.2:$(probe_http "$url" --tlsv1.2 --tls-max 1.2)")
		tokens+=("TLS1.3:$(probe_http "$url" --tlsv1.3 --tls-max 1.3)")
	fi
	printf '%s|%s|%s\n' "${tokens[*]:-}" "$(probe_ping "$ping_target")" "$([ -n "$url" ] && echo 1 || echo 0)" > "$out"
}

# не даёт запустить больше $1 фоновых задач
jobs_throttle()
{
	while [ "$(jobs -rp | wc -l)" -ge "$1" ]; do
		wait -n 2>/dev/null || sleep 0.05
	done
}

token_color()
{
	case "$1" in
		*:OK) printf '%s' "$C_GREEN" ;;
		*:UNSUP) printf '%s' "$C_YELLOW" ;;
		*) printf '%s' "$C_RED" ;;
	esac
}

# Стандартный тест одной стратегии. Заполняет STD_OK, STD_ERR, STD_UNSUP, STD_PING_OK, STD_PING_FAIL
# и дописывает подробности в $REPORT_BODY. $1 = quiet подавляет вывод на экран
run_standard()
{
	local quiet="${1:-}" tmp i token http ping is_url line
	tmp="$(mktemp -d "$RUN_DIR/test.XXXXXX")"
	STD_OK=0 STD_ERR=0 STD_UNSUP=0 STD_PING_OK=0 STD_PING_FAIL=0
	for i in "${!TARGET_NAMES[@]}"; do
		jobs_throttle "$TEST_PARALLEL"
		check_target "${TARGET_VALUES[$i]}" "$tmp/$i" &
	done
	wait
	for i in "${!TARGET_NAMES[@]}"; do
		IFS='|' read -r http ping is_url < "$tmp/$i"
		line=""
		local plain=""
		if [ "$is_url" = 1 ]; then
			for token in $http; do
				case "$token" in
					*:OK) STD_OK=$((STD_OK + 1)) ;;
					*:UNSUP) STD_UNSUP=$((STD_UNSUP + 1)) ;;
					*) STD_ERR=$((STD_ERR + 1)) ;;
				esac
				line+=" $(token_color "$token")$(printf '%-12s' "$token")$C_OFF"
				plain+=" $token"
			done
			line+=" ${C_GRAY}| Ping:${C_OFF} "
			plain+=" |"
			[ "$ping" = Timeout ] && line+="$C_YELLOW$ping$C_OFF" || line+="$C_CYAN$ping$C_OFF"
		else
			line+=" ${C_GRAY}Ping:${C_OFF} "
			[ "$ping" = Timeout ] && line+="$C_RED$ping$C_OFF" || line+="$C_CYAN$ping$C_OFF"
		fi
		if [ "$ping" = Timeout ] || [ "$ping" = n/a ]; then
			STD_PING_FAIL=$((STD_PING_FAIL + 1))
		else
			STD_PING_OK=$((STD_PING_OK + 1))
		fi
		[ "$quiet" = quiet ] || printf '  %-*s   %s\n' "$TARGET_NAME_WIDTH" "${TARGET_NAMES[$i]}" "$line"
		[ -n "${REPORT_BODY:-}" ] && printf '  %s :%s Ping: %s\n' "${TARGET_NAMES[$i]}" "$plain" "$ping" >> "$REPORT_BODY"
	done
	rm -rf "$tmp"
}

# --- DPI

dpi_targets_load()
{
	DPI_IDS=() DPI_PROVIDERS=() DPI_COUNTRIES=() DPI_HOSTS=()
	if [ -n "${MONITOR_HOST:-}" ]; then
		DPI_IDS=(CUSTOM) DPI_PROVIDERS=(Custom) DPI_COUNTRIES=("") DPI_HOSTS=("$MONITOR_HOST")
		return 0
	fi
	local json id provider country host
	json="$(curl -fsS -m "$DPI_TIMEOUT" "${CURL_EXTRA[@]}" "${DPI_SUITE_URL_OVERRIDE:-$DPI_SUITE_URL}" 2>/dev/null)"
	if [ -z "$json" ]; then
		warn "Не удалось скачать список целей DPI-теста."
		return 1
	fi
	while IFS='|' read -r id provider country host; do
		[ -n "$host" ] || continue
		DPI_IDS+=("$id") DPI_PROVIDERS+=("$provider") DPI_COUNTRIES+=("$country") DPI_HOSTS+=("$host")
	done < <(printf '%s' "$json" | tr '{' '\n' | sed -nE 's/.*"id": *"([^"]+)".*"provider": *"([^"]*)".*"country": *"([^"]*)".*"host": *"([^"]+)".*/\1|\2|\3|\4/p')
	[ ${#DPI_HOSTS[@]} -gt 0 ]
}

# один запрос DPI-теста, строка "метка code up down time статус"
dpi_probe()
{
	local label="$1" host="$2" payload="$3" out rc code=NA up=0 down=0 time=-1 status=OK
	shift 3
	out="$(curl --range "0-$((DPI_RANGE - 1))" -m "$DPI_TIMEOUT" --connect-timeout "$(( DPI_TIMEOUT < 3 ? DPI_TIMEOUT : 3 ))" \
		-w '%{http_code} %{size_upload} %{size_download} %{time_total}' -o /dev/null -X POST --data-binary "@$payload" -s \
		"${CURL_EXTRA[@]}" "$@" "https://$host" 2>&1)"
	rc=$?
	if [[ "$out" =~ ^([0-9]{3})\ ([0-9]+)\ ([0-9]+)\ ([0-9.]+)$ ]]; then
		code="${BASH_REMATCH[1]}" up="${BASH_REMATCH[2]}" down="${BASH_REMATCH[3]}" time="${BASH_REMATCH[4]}"
	fi
	if [ $rc -eq 1 ] || [ $rc -eq 2 ] || [ $rc -eq 4 ]; then
		code=UNSUP
		status=UNSUPPORTED
	elif [ $rc -ne 0 ]; then
		status=FAIL
	fi
	# данные ушли, ответа нет, упёрлись в таймаут: это и есть замирание на 16-20 КБ
	if [ "$up" -gt 0 ] && [ "$down" -eq 0 ] && [ $rc -ne 0 ] && awk "BEGIN { exit !($time >= $DPI_TIMEOUT) }"; then
		status=LIKELY_BLOCKED
	fi
	printf '%s %s %s %s %s %s\n' "$label" "$code" "$up" "$down" "$time" "$status"
}

dpi_check_target()
{
	local host="$1" payload="$2" out="$3"
	{
		dpi_probe HTTP "$host" "$payload" --http1.1
		dpi_probe TLS1.2 "$host" "$payload" --tlsv1.2 --tls-max 1.2
		dpi_probe TLS1.3 "$host" "$payload" --tlsv1.3 --tls-max 1.3
	} > "$out"
}

# заполняет DPI_OK, DPI_FAIL, DPI_UNSUP, DPI_BLOCKED
run_dpi()
{
	local tmp i payload label code up down time status warned=0 color target_warn
	tmp="$(mktemp -d "$RUN_DIR/dpi.XXXXXX")"
	payload="$tmp/payload"
	head -c "$DPI_RANGE" /dev/urandom > "$payload"
	DPI_OK=0 DPI_FAIL=0 DPI_UNSUP=0 DPI_BLOCKED=0
	echo "  Целей: ${#DPI_HOSTS[@]}, диапазон: 0-$((DPI_RANGE - 1)) байт, таймаут: ${DPI_TIMEOUT} с, параллельно: $DPI_PARALLEL"
	for i in "${!DPI_HOSTS[@]}"; do
		jobs_throttle "$DPI_PARALLEL"
		dpi_check_target "${DPI_HOSTS[$i]}" "$payload" "$tmp/$i" &
	done
	wait
	for i in "${!DPI_HOSTS[@]}"; do
		target_warn=0
		printf '\n%s=== [%s][%s] %s ===%s\n' "$C_CYAN" "${DPI_COUNTRIES[$i]}" "${DPI_PROVIDERS[$i]}" "${DPI_IDS[$i]}" "$C_OFF"
		[ -n "${REPORT_BODY:-}" ] && printf '  Target: [%s] %s (%s)\n' "${DPI_COUNTRIES[$i]}" "${DPI_IDS[$i]}" "${DPI_PROVIDERS[$i]}" >> "$REPORT_BODY"
		while read -r label code up down time status; do
			case "$status" in
				OK) DPI_OK=$((DPI_OK + 1)); color="$C_GREEN" ;;
				UNSUPPORTED) DPI_UNSUP=$((DPI_UNSUP + 1)); color="$C_YELLOW" ;;
				LIKELY_BLOCKED) DPI_BLOCKED=$((DPI_BLOCKED + 1)); color="$C_YELLOW"; target_warn=1; warned=1 ;;
				*) DPI_FAIL=$((DPI_FAIL + 1)); color="$C_RED" ;;
			esac
			printf '%s[%s] code=%s up=%s bytes down=%s bytes time=%ss status=%s%s\n' "$color" "$label" "$code" "$up" "$down" "$time" "$status" "$C_OFF"
			[ "$status" = LIKELY_BLOCKED ] && warn "  Похоже на замирание на 16-20 КБ: цензор режет эту стратегию."
			[ -n "${REPORT_BODY:-}" ] && printf '    %s: code=%s  up=%s  down=%s  time=%ss  status=%s\n' "$label" "$code" "$up" "$down" "$time" "$status" >> "$REPORT_BODY"
		done < "$tmp/$i"
		[ "$target_warn" = 0 ] && ok "  Замирания на 16-20 КБ нет."
	done
	echo
	if [ "$warned" = 1 ]; then
		err "[ВНИМАНИЕ] Возможна блокировка TCP 16-20 на части целей. Попробуйте другую стратегию."
	else
		ok "[OK] Замирания на 16-20 КБ не обнаружено."
	fi
	rm -rf "$tmp"
}

# --- загрузка видео через yt-dlp
#
# Так YouTube качают музыкальные боты Discord и приложения-загрузчики. Замедление googlevideo.com здесь видно
# сразу, а тест сайтов его не замечает: ему хватает первых байт ответа. Ролик никуда не сохраняется,
# yt-dlp отдаёт его в stdout, а тот направлен в /dev/null. Подробности для других платформ: ytdldownloadtest.md

YTDLP_REPO="yt-dlp/yt-dlp"
YTDLP_DIR="$STATE_DIR/yt-dlp"

# Официальная сборка yt-dlp - один файл для Python 3.10 и новее
ytdlp_python_ok()
{
	command -v python3 >/dev/null 2>&1 && python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null
}

# Своя копия последнего релиза yt-dlp: в дистрибутивах он часто отстаёт, а YouTube меняется каждые несколько недель.
# Файл сверяется с SHA2-256SUMS того же релиза. Без связи с GitHub годится уже скачанная копия
ytdlp_fetch()
{
	local tag have tmp sum base
	have="$(cat "$YTDLP_DIR/version" 2>/dev/null)"
	tag="$(curl -fsSL -m 15 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$YTDLP_REPO/releases/latest" 2>/dev/null |
		python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("tag_name", ""))' 2>/dev/null)"
	if ! [[ "$tag" =~ ^[0-9A-Za-z._-]+$ ]]; then
		[ -s "$YTDLP_DIR/yt-dlp" ] && return 0
		warn "Не удалось узнать последнюю версию yt-dlp: нет связи с GitHub."
		return 1
	fi
	[ "$tag" = "$have" ] && [ -s "$YTDLP_DIR/yt-dlp" ] && return 0
	echo "Скачиваю yt-dlp $tag..."
	base="https://github.com/$YTDLP_REPO/releases/download/$tag"
	tmp="$(mktemp -d "$RUN_DIR/yt-dlp.XXXXXX")"
	if curl -fsSL -m 120 -o "$tmp/yt-dlp" "$base/yt-dlp" && curl -fsSL -m 30 -o "$tmp/sums" "$base/SHA2-256SUMS"; then
		sum="$(awk '$2 == "yt-dlp" { print $1 }' "$tmp/sums")"
		if [ -n "$sum" ] && [ "$(sha256sum "$tmp/yt-dlp" | cut -d' ' -f1)" = "$sum" ]; then
			mkdir -p "$YTDLP_DIR"
			chmod 755 "$YTDLP_DIR"
			chmod 644 "$tmp/yt-dlp"
			mv -f "$tmp/yt-dlp" "$YTDLP_DIR/yt-dlp"
			printf '%s\n' "$tag" > "$YTDLP_DIR/version"
			chmod 644 "$YTDLP_DIR/version"
		else
			warn "Контрольная сумма yt-dlp не сошлась, файл отброшен."
		fi
	else
		warn "Не удалось скачать yt-dlp."
	fi
	rm -rf -- "${tmp:?}"
	[ -s "$YTDLP_DIR/yt-dlp" ]
}

# yt-dlp с общими настройками. $1 - сколько секунд ему дать. Скачанная из интернета программа работает
# от nobody, а не от root, с пустым окружением и без настроек пользователя
ytdlp()
{
	local limit="$1"
	shift
	(cd "$VIDEO_DIR" && exec timeout "$limit" "${VIDEO_AS[@]}" env -i HOME="$VIDEO_DIR" PATH="$PATH" LANG=C.UTF-8 \
		"${VIDEO_CMD[@]}" --ignore-config --no-cache-dir --no-playlist --socket-timeout "$VIDEO_STALL" "${VIDEO_EXTRA[@]}" "$@")
}

# Ссылки на поток действуют несколько часов и привязаны к адресу компьютера, поэтому ролик разбирается один раз,
# а каждая стратегия только качает его. В фоне, чтобы тест можно было сразу остановить
video_extract()
{
	rm -f "$VIDEO_DIR/info.json"
	ytdlp "$1" -J "$VIDEO_URL" > "$VIDEO_DIR/info.part" 2> "$VIDEO_DIR/extract.log" &
	wait $!
	if [ -s "$VIDEO_DIR/info.part" ] && grep -q '"formats"' "$VIDEO_DIR/info.part"; then
		chmod 644 "$VIDEO_DIR/info.part"
		mv -f "$VIDEO_DIR/info.part" "$VIDEO_DIR/info.json"
		return 0
	fi
	rm -f "$VIDEO_DIR/info.part"
	return 1
}

# Находит yt-dlp и разбирает ролик, пока работает обход пользователя. Если разобрать не вышло,
# это сделает первая стратегия, при которой YouTube ответит
video_prepare()
{
	local uid gid
	VIDEO_CMD=() VIDEO_AS=() VIDEO_DIR=""
	if [ -n "${ZAPRET_YTDLP:-}" ]; then
		VIDEO_CMD=("$ZAPRET_YTDLP")
	elif ytdlp_python_ok && ytdlp_fetch; then
		VIDEO_CMD=(python3 -I "$YTDLP_DIR/yt-dlp")
	elif command -v yt-dlp >/dev/null 2>&1; then
		warn "Беру yt-dlp из системы: если он устарел, YouTube может не отдать ролик."
		VIDEO_CMD=(yt-dlp)
	else
		ytdlp_python_ok || warn "Для теста видео нужен Python 3.10 или новее."
		return 1
	fi
	VIDEO_DIR="$(mktemp -d "$RUN_DIR/video.XXXXXX")"
	if [ "$(id -u)" = 0 ] && command -v setpriv >/dev/null 2>&1 && uid="$(id -u nobody 2>/dev/null)" \
		&& gid="$(id -g nobody 2>/dev/null)" && setpriv --reuid="$uid" --regid="$gid" --clear-groups true 2>/dev/null; then
		chown "$uid:$gid" "$VIDEO_DIR"
		VIDEO_AS=(setpriv --reuid="$uid" --regid="$gid" --clear-groups)
	fi
	echo "Получаю ссылку на тестовый ролик..."
	video_extract 60 || warn "YouTube пока не ответил, ссылку получит первая подходящая стратегия."
	return 0
}

video_cleanup()
{
	[ -n "${VIDEO_DIR:-}" ] && rm -rf -- "${VIDEO_DIR:?}"
	VIDEO_DIR=""
}

# Загрузка ролика при одной стратегии. Заполняет VID_OK, VID_STALL, VID_BYTES, VID_MS, VID_TOTAL:
# скачан целиком; данные перестали идти на $VIDEO_STALL с (yt-dlp сам завершается с ошибкой); сколько байт
# и за сколько миллисекунд пришло; размер файла. Если к концу $VIDEO_TIMEOUT с данные ещё идут, это "медленно"
run_video()
{
	local log="$VIDEO_DIR/download.log" rc status got total elapsed error
	VID_OK=0 VID_STALL=0 VID_BYTES=0 VID_MS=0 VID_TOTAL=0
	if [ ! -s "$VIDEO_DIR/info.json" ] && ! video_extract "$VIDEO_TIMEOUT"; then
		err "  YouTube не отдал ссылку на ролик."
		error="$(grep -m1 '^ERROR' "$VIDEO_DIR/extract.log" 2>/dev/null)"
		[ -n "$error" ] && printf '  %s\n' "$error"
		[ -n "${REPORT_BODY:-}" ] && printf '  Video: status=NO_LINK %s\n' "$error" >> "$REPORT_BODY"
		return 0
	fi
	ytdlp "$VIDEO_TIMEOUT" --load-info-json "$VIDEO_DIR/info.json" -f "$VIDEO_FORMAT" -o - \
		--retries 0 --fragment-retries 0 --extractor-retries 0 --newline \
		--progress-template 'download:@video %(progress.status)s %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.elapsed)s' \
		> /dev/null 2> "$log" &
	wait $!
	rc=$?
	read -r _ status got total elapsed < <(grep '^@video ' "$log" | tail -n1)
	[[ "${got:-}" =~ ^[0-9]+$ ]] && VID_BYTES=$got
	[[ "${total:-}" =~ ^[0-9]+$ ]] && VID_TOTAL=$total
	[[ "${elapsed:-}" =~ ^[0-9.]+$ ]] && VID_MS="$(awk -v s="$elapsed" 'BEGIN { print int(s * 1000) }')"
	if [ "${status:-}" = finished ]; then
		VID_OK=1
		ok "  Видео скачано: $(video_size "$VID_BYTES"), $(video_text 1 0 "$VID_BYTES" "$VID_MS")."
	elif [ "$rc" = 124 ] && [ "$VID_BYTES" -gt 0 ]; then
		warn "  Видео качается медленно: $(video_text 1 0 "$VID_BYTES" "$VID_MS"), за $VIDEO_TIMEOUT с пришло $(video_size "$VID_BYTES") из $(video_size "$VID_TOTAL")."
	elif [ "$VID_BYTES" -gt 0 ]; then
		VID_STALL=1
		err "  Видео $(video_text 0 1 "$VID_BYTES" "$VID_MS"): поток остановился, похоже, его режет цензор."
	else
		err "  Видео не скачалось."
	fi
	error="$(grep -m1 '^ERROR' "$log" 2>/dev/null)"
	[ "$VID_OK" = 0 ] && [ -n "$error" ] && printf '  %s\n' "$error"
	[ -n "${REPORT_BODY:-}" ] && printf '  Video: ok=%s stall=%s bytes=%s total=%s time=%sms rc=%s %s\n' \
		"$VID_OK" "$VID_STALL" "$VID_BYTES" "$VID_TOTAL" "$VID_MS" "$rc" "$error" >> "$REPORT_BODY"
	rm -f "$log"
	return 0
}

# --- выбор стратегий

# разбирает "1,3,5-7" в массив индексов SELECTED (с нуля). 0 или all - все
selection_parse()
{
	local input="$1" total="$2" part start end i seen=" "
	SELECTED=()
	if [ "$input" = all ] || [ "$input" = 0 ]; then
		for ((i = 0; i < total; i++)); do SELECTED+=("$i"); done
		return 0
	fi
	for part in ${input//,/ }; do
		if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
			start=${BASH_REMATCH[1]} end=${BASH_REMATCH[2]}
		elif [[ "$part" =~ ^[0-9]+$ ]]; then
			start=$part end=$part
		else
			warn "  Пропускаю \"$part\": нужны номера или диапазоны."
			continue
		fi
		if [ "$start" -gt "$end" ]; then
			warn "  Пропускаю диапазон \"$part\": начало больше конца."
			continue
		fi
		for ((i = start; i <= end; i++)); do
			if [ "$i" -lt 1 ] || [ "$i" -gt "$total" ]; then
				warn "  Номер $i вне списка (1-$total), пропускаю."
			elif [[ "$seen" != *" $i "* ]]; then
				SELECTED+=("$((i - 1))")
				seen+="$i "
			fi
		done
	done
	[ ${#SELECTED[@]} -gt 0 ]
}

# --- весь прогон

TESTS_ACTIVE=0

tests_cleanup()
{
	[ "$TESTS_ACTIVE" = 1 ] || return 0
	TESTS_ACTIVE=0
	rm -f "$RUN_DIR/test.pid"
	engine_stop
	ipset_test_restore
	video_cleanup
	info "Возвращаю обход в исходное состояние..."
	service_resume
}

tests_interrupted()
{
	# окно приложения могло закрыться: писать больше некуда, а обход всё равно нужно вернуть
	trap '' PIPE
	echo 2>/dev/null || exec >/dev/null 2>&1
	echo
	err "Тест прерван."
	# завершаем проверки, запущенные в фоне
	local pids
	pids="$(jobs -rp)"
	[ -n "$pids" ] && kill $pids 2>/dev/null
	tests_cleanup
	exit 130
}

# tests_run full|standard|dpi|video "выбор" apply_best(1/0)
tests_run()
{
	local type="$1" selection="$2" apply_best="${3:-0}"
	local names=() name i n=0 foreign result_file date_str video=0
	mapfile -t names < <(strategy_names)
	if [ ${#names[@]} -eq 0 ]; then
		err "В папке strategies нет ни одной стратегии."
		return 1
	fi
	if ! command -v curl >/dev/null 2>&1; then
		err "Не найден curl. Установите его через менеджер пакетов."
		return 1
	fi
	if [ ! -x "$NFQWS" ]; then
		err "Не собран движок ($NFQWS). Запустите ./install.sh из папки репозитория."
		return 1
	fi
	tests_defaults
	selection_parse "$selection" "${#names[@]}" || { err "Не выбрано ни одной стратегии."; return 1; }

	foreign="$(foreign_bypass)"
	if [ -n "$foreign" ]; then
		warn "Работает другое средство обхода, результаты будут неточными:"
		printf '  %s\n' "$foreign"
		warn "Остановить его можно в разделе диагностики: zapret diag"
		[ "${TEST_FORCE:-0}" = 1 ] || confirm "Всё равно продолжить?" n || return 1
	fi

	# прошлый запуск мог быть убит вместе с окном терминала
	ipset_test_restore

	if [ "$type" = standard ] || [ "$type" = full ]; then
		targets_load
		echo "Целей загружено: ${#TARGET_NAMES[@]}"
	fi
	if [ "$type" = dpi ] || [ "$type" = full ]; then
		dpi_targets_load || return 1
	fi
	# yt-dlp и ссылка на ролик нужны до того, как обход будет отключён
	if [ "$type" = video ] || [ "$type" = full ]; then
		if video_prepare; then
			video=1
		elif [ "$type" = video ]; then
			err "Тест видео недоступен: нет yt-dlp."
			return 1
		else
			warn "Загрузка видео проверяться не будет: нет yt-dlp."
		fi
	fi

	TESTS_ACTIVE=1
	trap tests_interrupted INT TERM HUP PIPE
	printf '%s\n' "$$" > "$RUN_DIR/test.pid"
	service_pause

	if [ "$type" = dpi ] && [ "$(ipset_status)" != any ]; then
		warn "IPSet в режиме \"$(ipset_status)\": на время DPI-теста он переключён в \"any\"."
		ipset_test_any
	fi

	echo
	info "============================================================"
	info "                 ТЕСТ СТРАТЕГИЙ"
	info "                 Режим: $type"
	info "                 Стратегий: ${#SELECTED[@]}"
	info "============================================================"
	warn "Тест может занять несколько минут."

	date_str="$(date +%Y-%m-%d_%H-%M-%S)"
	result_file="$RESULTS_DIR/test_results_$date_str.txt"
	REPORT_BODY="$RUN_DIR/report.$$"
	: > "$REPORT_BODY"
	local analytics="$RUN_DIR/analytics.$$" analytics_dpi="$RUN_DIR/analytics-dpi.$$" analytics_vid="$RUN_DIR/analytics-video.$$"
	local order="$RUN_DIR/order.$$"
	: > "$analytics"
	: > "$analytics_dpi"
	: > "$analytics_vid"
	: > "$order"

	for i in "${SELECTED[@]}"; do
		name="${names[$i]}"
		n=$((n + 1))
		machine_say progress "$n" "${#SELECTED[@]}" "$name"
		echo
		info "------------------------------------------------------------"
		printf '%s  [%d/%d] %s%s\n' "$C_YELLOW" "$n" "${#SELECTED[@]}" "$name" "$C_OFF"
		info "------------------------------------------------------------"
		printf 'Config: %s (Type: %s)\n' "$name" "$type" >> "$REPORT_BODY"
		if ! engine_start "$name"; then
			err "  Стратегия не запустилась, пропускаю."
			printf '  не запустилась\n\n' >> "$REPORT_BODY"
			continue
		fi
		printf '%s\n' "$name" >> "$order"
		case "$type" in
			standard)
				run_standard
				printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$STD_OK" "$STD_ERR" "$STD_UNSUP" "$STD_PING_OK" "$STD_PING_FAIL" >> "$analytics"
				machine_say result "$name" "$STD_OK" "$STD_ERR" "$STD_UNSUP" "$STD_PING_OK" "$STD_PING_FAIL"
				;;
			dpi)
				run_dpi
				printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$DPI_OK" "$DPI_FAIL" "$DPI_UNSUP" "$DPI_BLOCKED" >> "$analytics_dpi"
				machine_say result "$name" "$DPI_OK" "$DPI_FAIL" "$DPI_UNSUP" "$DPI_BLOCKED"
				;;
			video)
				run_video
				printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$VID_OK" "$VID_STALL" "$VID_BYTES" "$VID_MS" "$VID_TOTAL" >> "$analytics_vid"
				machine_say video "$name" "$VID_OK" "$VID_STALL" "$VID_BYTES" "$VID_MS" "$VID_TOTAL"
				;;
			full)
				echo
				info "  Открытие сайтов:"
				run_standard
				# замирание проверяется на всех адресах, как в DPI-тесте, а сайты - в обычном режиме IPSet
				if [ "$(ipset_status)" != any ]; then
					ipset_test_any
					lists_notify
				fi
				echo
				info "  Замирание на 16-20 КБ:"
				run_dpi
				ipset_test_restore
				lists_notify
				printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$STD_OK" "$STD_ERR" "$STD_UNSUP" "$STD_PING_OK" "$STD_PING_FAIL" >> "$analytics"
				printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$DPI_OK" "$DPI_FAIL" "$DPI_UNSUP" "$DPI_BLOCKED" >> "$analytics_dpi"
				machine_say result "$name" "$STD_OK" "$STD_ERR" "$STD_UNSUP" "$STD_PING_OK" "$STD_PING_FAIL" \
					"$DPI_OK" "$DPI_FAIL" "$DPI_UNSUP" "$DPI_BLOCKED"
				if [ "$video" = 1 ]; then
					echo
					info "  Загрузка видео с YouTube:"
					run_video
					printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$VID_OK" "$VID_STALL" "$VID_BYTES" "$VID_MS" "$VID_TOTAL" >> "$analytics_vid"
					machine_say video "$name" "$VID_OK" "$VID_STALL" "$VID_BYTES" "$VID_MS" "$VID_TOTAL"
				fi
				;;
		esac
		printf '\n' >> "$REPORT_BODY"
		engine_stop
	done

	echo
	ok "Все тесты завершены."
	tests_report "$type" "$analytics" "$analytics_dpi" "$analytics_vid" "$order" "$result_file"
	rm -f "$REPORT_BODY" "$analytics" "$analytics_dpi" "$analytics_vid" "$order"
	REPORT_BODY=""

	TESTS_ACTIVE=0
	trap - INT TERM HUP PIPE
	rm -f "$RUN_DIR/test.pid"
	ipset_test_restore
	video_cleanup
	machine_say best "$BEST_CONFIG"
	machine_say report "$result_file"

	if [ -n "$BEST_CONFIG" ]; then
		if [ "$apply_best" = 1 ] || { [ -t 0 ] && confirm "Включить лучшую стратегию \"$BEST_CONFIG\"?" y; }; then
			service_apply "$BEST_CONFIG" && ok "Включена стратегия \"$BEST_CONFIG\"."
			return 0
		fi
	fi
	info "Возвращаю обход в исходное состояние..."
	service_resume
}

tests_report()
{
	local type="$1" analytics="$2" analytics_dpi="$3" analytics_vid="$4" order="$5" result_file="$6"
	local width=0 name a b c d e line best="" summary max_ok=-1 max_ping=-1
	summary="$RUN_DIR/summary.$$"
	: > "$summary"
	while IFS= read -r name; do
		[ ${#name} -gt "$width" ] && width=${#name}
	done < "$order"

	echo
	info "=== ИТОГИ ==="
	case "$type" in
		standard)
			while IFS=$'\t' read -r name a b c d e; do
				line="$(printf '%-*s : HTTP OK: %3d, ERR: %3d, UNSUP: %3d, Ping OK: %3d, Fail: %3d' "$width" "$name" "$a" "$b" "$c" "$d" "$e")"
				# как в оригинале: сначала число успешных проверок, при равенстве - пинг
				if [ "$a" -gt "$max_ok" ] || { [ "$a" -eq "$max_ok" ] && [ "$d" -gt "$max_ping" ]; }; then
					max_ok=$a max_ping=$d best=$name
				fi
				warn "$line"
				printf '%s\n' "$line" >> "$summary"
			done < "$analytics"
			;;
		dpi)
			while IFS=$'\t' read -r name a b c d; do
				line="$(printf '%-*s : OK: %3d, FAIL: %3d, UNSUP: %3d, BLOCKED: %3d' "$width" "$name" "$a" "$b" "$c" "$d")"
				if [ "$a" -gt "$max_ok" ]; then
					max_ok=$a best=$name
				fi
				warn "$line"
				printf '%s\n' "$line" >> "$summary"
			done < "$analytics_dpi"
			;;
		video)
			while IFS=$'\t' read -r name a b c d e; do
				line="$(printf '%-*s : видео %s' "$width" "$name" "$(video_text "$a" "$b" "$c" "$d")")"
				warn "$line"
				printf '%s\n' "$line" >> "$summary"
			done < "$analytics_vid"
			best="$(results_join "$analytics" "$analytics_dpi" "$analytics_vid" < "$order" | strategy_rank | head -n1)"
			echo "Порядок: сначала скачавшие ролик целиком, затем медленные, затем зависшие; внутри - по скорости."
			;;
		full)
			# строки: имя, 5 полей сайтов, 4 поля DPI, 5 полей видео (пустые, если yt-dlp не нашёлся)
			local s1 s2 s3 s4 d1 d2 d3 d4 v1 v2 v3 v4 video_part
			while IFS=$'\t' read -r name a b c d e d1 d2 d3 d4 v1 v2 v3 v4 _; do
				[ -n "$a" ] || continue
				video_part=""
				[ -n "$v1" ] && video_part=" | видео $(video_text "$v1" "$v2" "$v3" "$v4")"
				line="$(printf '%-*s : сайты %3d/%-3d | замирание %3d/%-3d%s | HTTP ERR: %3d, UNSUP: %3d, Ping OK: %3d | DPI FAIL: %3d' \
					"$width" "$name" "$a" "$((a + b))" "$d4" "$((d1 + d2 + d4))" "$video_part" "$b" "$c" "$d" "$d2")"
				warn "$line"
				printf '%s\n' "$line" >> "$summary"
			done < <(results_join "$analytics" "$analytics_dpi" "$analytics_vid" < "$order")
			# лучшая - в том же порядке, что и список: сайты, затем меньше замираний, затем видео, затем пинг
			best="$(results_join "$analytics" "$analytics_dpi" "$analytics_vid" < "$order" | strategy_rank | head -n1)"
			echo "Порядок: сначала больше открытых сайтов, при равенстве меньше замираний на 16-20 КБ, затем загрузка видео."
			;;
	esac

	BEST_CONFIG="$best"
	echo
	if [ -n "$best" ]; then
		ok "Лучшая стратегия: $best"
	else
		err "Ни одна стратегия не запустилась."
	fi
	echo

	{
		cat "$REPORT_BODY"
		echo "=== ANALYTICS ==="
		cat "$summary"
		echo "Best strategy: $best"
	} > "$result_file"
	ok "Результаты сохранены: $result_file"
	rm -f "$summary"

	# итоги для списка стратегий, "zapret next" и "zapret auto". Итоги непроверенных стратегий сохраняются
	[ -s "$analytics" ] && results_merge "$RESULTS_STD" "$analytics"
	[ -s "$analytics_dpi" ] && results_merge "$RESULTS_DPI" "$analytics_dpi"
	[ -s "$analytics_vid" ] && results_merge "$RESULTS_VID" "$analytics_vid"
	return 0
}

tests_cli()
{
	local type selection apply=0 arg words=()
	TEST_MACHINE=0
	TEST_FORCE=0
	for arg in "$@"; do
		case "$arg" in
			--apply-best) apply=1 ;;
			--machine) TEST_MACHINE=1 ;;
			--force) TEST_FORCE=1 ;;
			*) words+=("$arg") ;;
		esac
	done
	type="${words[0]:-}"
	selection="${words[1]:-}"
	if [ -z "$type" ]; then
		tests_dialog
		return
	fi
	case "$type" in
		standard|dpi|full|video) ;;
		*) err "Тип теста: full, standard, dpi или video."; return 1 ;;
	esac
	tests_run "$type" "${selection:-all}" "$apply"
}

tests_dialog()
{
	local choice type selection names i
	while :; do
		echo
		info "Какой тест запустить?"
		echo "  1. Полный: сайты, замирание на 16-20 КБ и загрузка видео - рекомендуется"
		echo "  2. Только сайты: HTTP, TLS 1.2, TLS 1.3, ping"
		echo "  3. Только DPI: замирание TCP на 16-20 КБ"
		echo "  4. Только видео: загрузка ролика с YouTube через yt-dlp"
		echo "  0. Назад"
		read -r -p "Выберите пункт: " choice || return 0
		case "$choice" in
			1) type=full; break ;;
			2) type=standard; break ;;
			3) type=dpi; break ;;
			4) type=video; break ;;
			0) return 0 ;;
			*) warn "Нет такого пункта." ;;
		esac
	done
	while :; do
		echo
		info "Какие стратегии проверить?"
		echo "  1. Все (несколько минут)"
		echo "  2. Выбрать"
		read -r -p "Выберите пункт: " choice || return 0
		case "$choice" in
			1) selection=all; break ;;
			2)
				mapfile -t names < <(strategy_names)
				for i in "${!names[@]}"; do
					printf '  %2d. %s\n' "$((i + 1))" "${names[$i]}"
				done
				read -r -p "Номера или диапазоны, например 1,3,5-7: " selection || return 0
				selection_parse "$selection" "${#names[@]}" && break
				warn "Ничего не выбрано, попробуйте ещё раз."
				;;
			*) warn "Нет такого пункта." ;;
		esac
	done
	tests_run "$type" "$selection" 0
}
