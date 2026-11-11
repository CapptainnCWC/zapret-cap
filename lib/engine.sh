# Движок: чтение стратегии, правила файрвола и запуск nfqws2

QNUM=${ZAPRET_QNUM:-310}
FWMARK=0x40000000
NFT_TABLE=zapret_cap
IPT_CHAIN_POST=zapret_cap_post
IPT_CHAIN_PRE=zapret_cap_pre

# Сколько первых пакетов соединения отдавать nfqws2. winws получает весь поток, а здесь лишние пакеты
# только нагружали бы процессор: стратегии работают с началом соединения и сами ограничены через --out-range.
PKT_OUT_TCP=${ZAPRET_PKT_OUT_TCP:-20}
PKT_IN_TCP=${ZAPRET_PKT_IN_TCP:-10}
PKT_OUT_UDP=${ZAPRET_PKT_OUT_UDP:-12}
PKT_IN_UDP=${ZAPRET_PKT_IN_UDP:-3}

PIDFILE="$RUN_DIR/nfqws2.pid"
ENGINE_LOG="$RUN_DIR/nfqws2.log"
FW_STATE="$RUN_DIR/firewall"
LIBERAL_STATE="$RUN_DIR/conntrack_liberal"

strategy_file()
{
	printf '%s/%s.conf' "$STRATEGIES_DIR" "$1"
}

# Разворачивает стратегию в ENGINE_ARGS, ENGINE_PORTS_TCP и ENGINE_PORTS_UDP.
# Значения подставляются после разбиения на слова, поэтому пробелы в путях безопасны
strategy_load()
{
	local file line token words
	file="$(strategy_file "$1")"
	if [ ! -f "$file" ]; then
		err "Стратегия не найдена: $1"
		return 1
	fi
	game_load
	ENGINE_ARGS=()
	ENGINE_PORTS_TCP=""
	ENGINE_PORTS_UDP=""
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			''|'#'*) continue ;;
			PORTS_TCP=*) strategy_subst "${line#PORTS_TCP=}"; ENGINE_PORTS_TCP="$SUBST"; continue ;;
			PORTS_UDP=*) strategy_subst "${line#PORTS_UDP=}"; ENGINE_PORTS_UDP="$SUBST"; continue ;;
		esac
		read -r -a words <<< "$line"
		for token in "${words[@]}"; do
			strategy_subst "$token"
			ENGINE_ARGS+=("$SUBST")
		done
	done < "$file"
	ENGINE_PORTS_TCP="$(ports_normalize "$ENGINE_PORTS_TCP")"
	ENGINE_PORTS_UDP="$(ports_normalize "$ENGINE_PORTS_UDP")"
}

# результат в SUBST: в стратегии сотни значений, отдельный процесс на каждое заметно замедлил бы тесты
strategy_subst()
{
	SUBST="$1"
	SUBST="${SUBST//%LISTS%/$LISTS_DIR}"
	SUBST="${SUBST//%FAKE%/$FAKE_DIR}"
	SUBST="${SUBST//%GameFilterTCP%/$GAME_FILTER_TCP}"
	SUBST="${SUBST//%GameFilterUDP%/$GAME_FILTER_UDP}"
}

# Сливает пересекающиеся диапазоны портов: 443,1024-65535,8443 -> 443,1024-65535
ports_normalize()
{
	printf '%s' "$1" | tr ',' '\n' | awk -F- '
		NF { lo = $1 + 0; hi = (NF > 1 ? $2 : $1) + 0; print lo, hi }' | sort -n -k1,1 -k2,2 | awk '
		NR == 1 { lo = $1; hi = $2; next }
		$1 <= hi + 1 { if ($2 > hi) hi = $2; next }
		{ printf "%s%s", (n++ ? "," : ""), (lo == hi ? lo : lo "-" hi); lo = $1; hi = $2 }
		END { if (NR) printf "%s%s", (n ? "," : ""), (lo == hi ? lo : lo "-" hi) }'
}

engine_base_args()
{
	ENGINE_BASE=(
		"--qnum=$QNUM"
		"--fwmark=$FWMARK"
		"--lua-init=@$Z_HOME/core/lua/zapret-lib.lua"
		"--lua-init=@$Z_HOME/core/lua/zapret-antidpi.lua"
		# circular и другие оркестраторы: на них стратегия general (BYEDPI AUTO)
		"--lua-init=@$Z_HOME/core/lua/zapret-auto.lua"
		"--lua-init=@$Z_HOME/lua/zapret-cap.lua"
	)
	if [ -n "${ZAPRET_NFQWS_EXTRA:-}" ]; then
		local extra
		read -r -a extra <<< "$ZAPRET_NFQWS_EXTRA"
		ENGINE_BASE+=("${extra[@]}")
	fi
}

# --- файрвол

fw_type()
{
	if [ -n "${ZAPRET_FW:-}" ]; then
		printf '%s' "$ZAPRET_FW"
	elif command -v nft >/dev/null 2>&1; then
		printf 'nftables'
	elif command -v iptables >/dev/null 2>&1; then
		printf 'iptables'
	fi
}

fw_up()
{
	local type
	type="$(fw_type)"
	fw_down
	case "$type" in
		nftables) nft_up ;;
		iptables) ipt_up ;;
		*) err "Не найдены nft и iptables: нечем направлять трафик в nfqws2."; return 1 ;;
	esac || return 1
	printf '%s\n' "$type" > "$FW_STATE"
}

fw_down()
{
	nft_down
	# без нужды не трогаем iptables: на системах с nftables это подгрузило бы лишние модули ядра
	if [ "$(cat "$FW_STATE" 2>/dev/null)" = iptables ] || [ "$(fw_type)" = iptables ]; then
		ipt_down
	fi
	rm -f "$FW_STATE"
}

nft_up()
{
	local tcp="{ ${ENGINE_PORTS_TCP//,/, } }" udp="{ ${ENGINE_PORTS_UDP//,/, } }" queue="queue num $QNUM bypass"
	nft -f - <<EOF
table inet $NFT_TABLE {
	chain postnat {
		type filter hook postrouting priority srcnat + 1;
		oifname "lo" return
		meta mark & $FWMARK != 0 return
		tcp dport $tcp ct original packets 1-$PKT_OUT_TCP $queue
		tcp dport $tcp tcp flags & (fin | rst) != 0 $queue
		udp dport $udp ct original packets 1-$PKT_OUT_UDP $queue
	}
	chain pre {
		type filter hook prerouting priority filter;
		iifname "lo" return
		tcp sport $tcp ct reply packets 1-$PKT_IN_TCP $queue
		tcp sport $tcp tcp flags & (syn | ack) == (syn | ack) $queue
		tcp sport $tcp tcp flags & (fin | rst) != 0 $queue
		udp sport $udp ct reply packets 1-$PKT_IN_UDP $queue
	}
	chain predefrag {
		type filter hook output priority -401;
		# SYN нельзя выводить из conntrack. syndata заменяет исходный SYN своим, и если его не отследить,
		# у соединения не будет записи, счётчик ct original не сработает и дальше nfqws2 ничего не получит
		meta mark & $FWMARK != 0 tcp flags & syn != 0 return
		meta mark & $FWMARK != 0 notrack
	}
}
EOF
}

nft_down()
{
	command -v nft >/dev/null 2>&1 || return 0
	nft delete table inet "$NFT_TABLE" 2>/dev/null
	return 0
}

ipt_up()
{
	local t tcp="${ENGINE_PORTS_TCP//-/:}" udp="${ENGINE_PORTS_UDP//-/:}"
	local jump=(-j NFQUEUE --queue-num "$QNUM" --queue-bypass)
	local nomark=(-m mark ! --mark "$FWMARK/$FWMARK")
	local orig=(-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes)
	local reply=(-m connbytes --connbytes-dir=reply --connbytes-mode=packets --connbytes)
	for t in iptables ip6tables; do
		command -v "$t" >/dev/null 2>&1 || continue
		"$t" -t mangle -N "$IPT_CHAIN_POST" 2>/dev/null
		"$t" -t mangle -N "$IPT_CHAIN_PRE" 2>/dev/null
		"$t" -t mangle -A POSTROUTING -j "$IPT_CHAIN_POST" || return 1
		"$t" -t mangle -A PREROUTING -j "$IPT_CHAIN_PRE" || return 1
		"$t" -t mangle -A "$IPT_CHAIN_POST" -o lo -j RETURN
		"$t" -t mangle -A "$IPT_CHAIN_POST" "${nomark[@]}" -p tcp -m multiport --dports "$tcp" "${orig[@]}" "1:$PKT_OUT_TCP" "${jump[@]}" || return 1
		"$t" -t mangle -A "$IPT_CHAIN_POST" "${nomark[@]}" -p tcp -m multiport --dports "$tcp" --tcp-flags fin fin "${jump[@]}"
		"$t" -t mangle -A "$IPT_CHAIN_POST" "${nomark[@]}" -p tcp -m multiport --dports "$tcp" --tcp-flags rst rst "${jump[@]}"
		"$t" -t mangle -A "$IPT_CHAIN_POST" "${nomark[@]}" -p udp -m multiport --dports "$udp" "${orig[@]}" "1:$PKT_OUT_UDP" "${jump[@]}" || return 1
		"$t" -t mangle -A "$IPT_CHAIN_PRE" -i lo -j RETURN
		"$t" -t mangle -A "$IPT_CHAIN_PRE" -p tcp -m multiport --sports "$tcp" "${reply[@]}" "1:$PKT_IN_TCP" "${jump[@]}"
		"$t" -t mangle -A "$IPT_CHAIN_PRE" -p tcp -m multiport --sports "$tcp" --tcp-flags syn,ack syn,ack "${jump[@]}"
		"$t" -t mangle -A "$IPT_CHAIN_PRE" -p tcp -m multiport --sports "$tcp" --tcp-flags fin fin "${jump[@]}"
		"$t" -t mangle -A "$IPT_CHAIN_PRE" -p tcp -m multiport --sports "$tcp" --tcp-flags rst rst "${jump[@]}"
		"$t" -t mangle -A "$IPT_CHAIN_PRE" -p udp -m multiport --sports "$udp" "${reply[@]}" "1:$PKT_IN_UDP" "${jump[@]}"
		"$t" -t raw -N "$IPT_CHAIN_POST" 2>/dev/null
		"$t" -t raw -A OUTPUT -j "$IPT_CHAIN_POST"
		# см. комментарий про SYN в nft_up
		"$t" -t raw -A "$IPT_CHAIN_POST" -m mark --mark "$FWMARK/$FWMARK" -p tcp --tcp-flags syn syn -j RETURN
		"$t" -t raw -A "$IPT_CHAIN_POST" -m mark --mark "$FWMARK/$FWMARK" -j CT --notrack
	done
}

ipt_down()
{
	local t table chain
	for t in iptables ip6tables; do
		command -v "$t" >/dev/null 2>&1 || continue
		while "$t" -t mangle -D POSTROUTING -j "$IPT_CHAIN_POST" 2>/dev/null; do :; done
		while "$t" -t mangle -D PREROUTING -j "$IPT_CHAIN_PRE" 2>/dev/null; do :; done
		while "$t" -t raw -D OUTPUT -j "$IPT_CHAIN_POST" 2>/dev/null; do :; done
		for table in mangle raw; do
			for chain in "$IPT_CHAIN_POST" "$IPT_CHAIN_PRE"; do
				"$t" -t "$table" -F "$chain" 2>/dev/null
				"$t" -t "$table" -X "$chain" 2>/dev/null
			done
		done
	done
	return 0
}

fw_present()
{
	if command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
		return 0
	fi
	[ "$(cat "$FW_STATE" 2>/dev/null)" = iptables ] && iptables -t mangle -S "$IPT_CHAIN_POST" >/dev/null 2>&1
}

# --- системные настройки

# стратегии с --dpi-desync-fooling=ts не работают без TCP timestamps (аналог :tcp_enable в service.bat)
tcp_timestamps_enable()
{
	local file=/proc/sys/net/ipv4/tcp_timestamps
	[ -r "$file" ] || return 0
	if [ "$(cat "$file")" = 0 ]; then
		warn "TCP timestamps выключены - включаю."
		echo 1 > "$file" 2>/dev/null || warn "Не удалось включить TCP timestamps."
	fi
	return 0
}

# без этого conntrack считает ответы на пакеты с seqovl недействительными
conntrack_liberal_on()
{
	local file=/proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal
	[ -w "$file" ] || return 0
	[ -f "$LIBERAL_STATE" ] || cat "$file" > "$LIBERAL_STATE"
	echo 1 > "$file" 2>/dev/null
	return 0
}
conntrack_liberal_restore()
{
	local file=/proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal
	[ -f "$LIBERAL_STATE" ] || return 0
	[ -w "$file" ] && cat "$LIBERAL_STATE" > "$file" 2>/dev/null
	rm -f "$LIBERAL_STATE"
	return 0
}

# --- процесс

engine_pid()
{
	local pid
	pid="$(cat "$PIDFILE" 2>/dev/null)" || return 1
	[ -n "$pid" ] && [ "$(proc_exe "$pid")" = "$(readlink -f "$NFQWS")" ] || return 1
	printf '%s' "$pid"
}

engine_running()
{
	engine_pid >/dev/null
}

# Запускает стратегию. Ошибка запуска не оставляет за собой правил файрвола:
# иначе трафик шёл бы в пустую очередь
engine_start()
{
	local name="$1" attempt
	if [ ! -x "$NFQWS" ]; then
		err "Не собран движок ($NFQWS). Запустите ./install.sh из папки репозитория."
		return 1
	fi
	engine_stop
	strategy_load "$name" || return 1
	engine_base_args
	tcp_timestamps_enable

	if ! "$NFQWS" --dry-run "${ENGINE_BASE[@]}" "${ENGINE_ARGS[@]}" >"$ENGINE_LOG" 2>&1; then
		err "Стратегия \"$name\" не прошла проверку параметров:"
		tail -n 5 "$ENGINE_LOG" >&2
		return 1
	fi

	fw_up || { err "Не удалось применить правила файрвола."; fw_down; return 1; }
	conntrack_liberal_on

	rm -f "$PIDFILE"
	if ! "$NFQWS" --daemon "--pidfile=$PIDFILE" "${ENGINE_BASE[@]}" "${ENGINE_ARGS[@]}" >"$ENGINE_LOG" 2>&1; then
		err "nfqws2 не запустился:"
		tail -n 5 "$ENGINE_LOG" >&2
		engine_stop
		return 1
	fi
	# как Wait-WinwsReady: дать процессу подняться и убедиться, что он не упал сразу после старта
	for attempt in 1 2 3 4 5 6 7 8 9 10; do
		if engine_running; then
			sleep 0.3
			engine_running && { state_set running_strategy "$name"; return 0; }
			break
		fi
		sleep 0.2
	done
	err "nfqws2 завершился сразу после запуска. Подробности: $ENGINE_LOG"
	engine_stop
	return 1
}

engine_stop()
{
	local pid i
	if pid="$(engine_pid)"; then
		kill "$pid" 2>/dev/null
		for i in 1 2 3 4 5 6 7 8 9 10; do
			[ -d "/proc/$pid" ] || break
			sleep 0.1
		done
		[ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
	fi
	rm -f "$PIDFILE" "$STATE_DIR/running_strategy"
	fw_down
	conntrack_liberal_restore
	return 0
}

engine_start_current()
{
	local name
	name="$(state_get current)"
	[ -n "$name" ] || { err "Стратегия ещё не выбрана."; return 1; }
	engine_start "$name"
}
