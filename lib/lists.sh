# Списки и настройки: домены, ipset, фильтр игр, активные фейки

IPSET_PLACEHOLDER="203.0.113.113/32"

# Пустой хостлист nfqws2 считает отсутствием фильтра, поэтому в пользовательских файлах всегда есть заглушка
load_user_lists()
{
	[ -f "$LISTS_DIR/ipset-exclude-user.txt" ] || echo "$IPSET_PLACEHOLDER" > "$LISTS_DIR/ipset-exclude-user.txt"
	[ -f "$LISTS_DIR/list-general-user.txt" ] || printf '# Never leave this file empty\ndomain.example.abc\n' > "$LISTS_DIR/list-general-user.txt"
	[ -f "$LISTS_DIR/list-exclude-user.txt" ] || echo "domain.example.abc" > "$LISTS_DIR/list-exclude-user.txt"
	return 0
}

# --- домены

DOMAIN_LIST="$LISTS_DIR/list-general.txt"

# Приводит ввод человека к домену: "https://WWW.Example.com:8443/путь?x=1" -> example.com
domain_normalize()
{
	local d="$1"
	d="${d//[[:space:]]/}"
	d="${d#*://}"
	d="${d%%[/?#]*}"
	d="${d##*@}"
	d="${d%%:*}"
	d="${d%.}"
	d="${d#\*.}"
	d="${d#.}"
	d="${d,,}"
	# хостлист сам учитывает поддомены, поэтому www. только сужал бы запись
	d="${d#www.}"
	if [[ "$d" == *[![:ascii:]]* ]]; then
		d="$(domain_to_ascii "$d")" || return 1
	fi
	printf '%s' "$d"
}

# кириллические домены в TLS идут в punycode
domain_to_ascii()
{
	if command -v idn2 >/dev/null 2>&1; then
		idn2 "$1" 2>/dev/null
	elif command -v idn >/dev/null 2>&1; then
		idn "$1" 2>/dev/null
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c 'import sys; print(sys.argv[1].encode("idna").decode())' "$1" 2>/dev/null
	else
		return 1
	fi
}

domain_valid()
{
	[[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z][a-z0-9-]*[a-z0-9]$ ]]
}

# находит запись, которая уже покрывает домен: сам домен или родительский
domain_covered_by()
{
	local d="$1" file="$2" part="$1"
	grep -qxF -- "^$d" "$file" 2>/dev/null && { printf '%s' "^$d"; return 0; }
	while :; do
		grep -qxF -- "$part" "$file" 2>/dev/null && { printf '%s' "$part"; return 0; }
		[[ "$part" == *.* ]] || return 1
		part="${part#*.}"
	done
}

lists_notify()
{
	# nfqws2 сам перечитывает изменённые списки. SIGHUP делает это сразу на следующем пакете
	local pid
	pid="$(engine_pid)" && kill -HUP "$pid" 2>/dev/null
	return 0
}

domain_add()
{
	local input d covered added=0 exclude
	if [ $# -eq 0 ]; then
		echo "Введите домены или ссылки через пробел, например: rutracker.org https://example.com/page"
		read -r -a input_list -p "> " || return 0
		set -- "${input_list[@]}"
	fi
	[ $# -gt 0 ] || return 0
	# файл из Windows мог закончиться без перевода строки
	[ -s "$DOMAIN_LIST" ] && [ -n "$(tail -c 1 "$DOMAIN_LIST")" ] && echo >> "$DOMAIN_LIST"
	for input in "$@"; do
		if ! d="$(domain_normalize "$input")"; then
			err "$input: не удалось преобразовать кириллический домен. Установите idn2 или python3."
			continue
		fi
		if [[ "$d" =~ ^[0-9.]+$ ]] || [[ "$input" == *:*:* && "$input" != *://* ]]; then
			err "$input: это IP-адрес. В этот список идут только домены."
			continue
		fi
		if ! domain_valid "$d"; then
			err "$input: не похоже на домен."
			continue
		fi
		if covered="$(domain_covered_by "$d" "$DOMAIN_LIST")"; then
			echo "$d: уже в списке (запись $covered)."
			continue
		fi
		echo "$d" >> "$DOMAIN_LIST"
		ok "$d: добавлен."
		added=$((added + 1))
		for exclude in "$LISTS_DIR/list-exclude.txt" "$LISTS_DIR/list-exclude-user.txt"; do
			if covered="$(domain_covered_by "$d" "$exclude")"; then
				warn "  Внимание: $covered есть в исключениях (${exclude##*/}), обход для него работать не будет."
			fi
		done
	done
	if [ "$added" -gt 0 ]; then
		lists_notify
		echo "Перезапуск не нужен: список применяется сам. Обновите страницу в браузере."
	fi
}

domain_remove()
{
	local input d tmp found
	[ $# -gt 0 ] || { err "Использование: zapret remove ДОМЕН"; return 1; }
	for input in "$@"; do
		d="$(domain_normalize "$input")" || continue
		found=0
		grep -qxF -- "$d" "$DOMAIN_LIST" && found=1
		grep -qxF -- "^$d" "$DOMAIN_LIST" && found=1
		if [ "$found" = 0 ]; then
			warn "$d: такой записи нет."
			continue
		fi
		tmp="$(mktemp "$DOMAIN_LIST.XXXXXX")"
		grep -vxF -e "$d" -e "^$d" "$DOMAIN_LIST" > "$tmp"
		chmod 644 "$tmp"
		mv -f "$tmp" "$DOMAIN_LIST"
		ok "$d: удалён."
	done
	lists_notify
}

domain_list()
{
	grep -vE '^[[:space:]]*(#|$)' "$DOMAIN_LIST"
}

# --- ipset

ipset_status()
{
	local list="$LISTS_DIR/ipset-all.txt"
	if [ ! -f "$list" ] || ! grep -q '[^[:space:]]' "$list"; then
		echo any
	elif grep -qF "$IPSET_PLACEHOLDER" "$list"; then
		echo none
	else
		echo loaded
	fi
}

ipset_set()
{
	local want="$1" list="$LISTS_DIR/ipset-all.txt" backup="$LISTS_DIR/ipset-all.txt.backup" status
	status="$(ipset_status)"
	[ "$status" = "$want" ] && return 0
	case "$want" in
		none)
			[ "$status" = loaded ] && mv -f "$list" "$backup"
			echo "$IPSET_PLACEHOLDER" > "$list"
			;;
		any)
			[ "$status" = loaded ] && mv -f "$list" "$backup"
			: > "$list"
			;;
		loaded)
			if [ ! -f "$backup" ]; then
				err "Нет резервной копии списка. Сначала обновите его: zapret ipset update"
				return 1
			fi
			mv -f "$backup" "$list"
			;;
	esac
	chmod 644 "$list"
	lists_notify
}

ipset_cli()
{
	case "$1" in
		next)
			case "$(ipset_status)" in
				loaded) ipset_set none ;;
				none) ipset_set any ;;
				any) ipset_set loaded ;;
			esac
			echo "IPSet: $(ipset_status)"
			;;
		loaded|none|any) ipset_set "$1" && echo "IPSet: $(ipset_status)" ;;
		update) ipset_update ;;
		*) err "Использование: zapret ipset [next|loaded|none|any|update]"; return 1 ;;
	esac
}

ipset_update()
{
	local tmp list="$LISTS_DIR/ipset-all.txt"
	tmp="$(mktemp "$list.XXXXXX")"
	echo "Обновляю ipset-all..."
	if curl -L -f -sS -m 60 -o "$tmp" "$GITHUB_FLOWSEAL_RAW/ipset-service.txt" && [ -s "$tmp" ]; then
		chmod 644 "$tmp"
		tr -d '\r' < "$tmp" > "$list"
		rm -f "$tmp"
		lists_notify
		ok "Готово. IPSet: $(ipset_status), записей: $(grep -c . "$list")."
	else
		rm -f "$tmp"
		err "Не удалось скачать список. Текущий файл не изменён."
		return 1
	fi
}

# --- фильтр игр

game_flag_file()
{
	printf '%s/game_filter.enabled' "$UTILS_DIR"
}

# Порт 12 - заглушка, как в оригинале: профиль остаётся в стратегии, но под него не попадает трафик
game_load()
{
	local file key value
	file="$(game_flag_file)"
	GAME_FILTER_MODE=disabled
	GAME_FILTER_TCP_RANGE=1024-65535
	GAME_FILTER_UDP_RANGE=1024-65535
	GAME_FILTER_TCP=12
	GAME_FILTER_UDP=12
	GAME_FILTER_STATUS="выключен"
	if [ -f "$file" ]; then
		while IFS='=' read -r key value; do
			case "$key" in
				mode) GAME_FILTER_MODE="$value" ;;
				tcp) game_range_valid "$value" && GAME_FILTER_TCP_RANGE="$value" ;;
				udp) game_range_valid "$value" && GAME_FILTER_UDP_RANGE="$value" ;;
			esac
		done < "$file"
	fi
	case "$GAME_FILTER_MODE" in
		all)
			GAME_FILTER_STATUS="включён (TCP и UDP)"
			GAME_FILTER_TCP="$GAME_FILTER_TCP_RANGE"
			GAME_FILTER_UDP="$GAME_FILTER_UDP_RANGE"
			;;
		tcp)
			GAME_FILTER_STATUS="включён (TCP)"
			GAME_FILTER_TCP="$GAME_FILTER_TCP_RANGE"
			;;
		udp)
			GAME_FILTER_STATUS="включён (UDP)"
			GAME_FILTER_UDP="$GAME_FILTER_UDP_RANGE"
			;;
		*) GAME_FILTER_MODE=disabled ;;
	esac
}

game_range_valid()
{
	local item from to
	[ -n "$1" ] || return 1
	for item in ${1//,/ }; do
		if [[ "$item" =~ ^([1-9][0-9]{0,4})-([1-9][0-9]{0,4})$ ]]; then
			from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]}
		elif [[ "$item" =~ ^[1-9][0-9]{0,4}$ ]]; then
			from=$item to=$item
		else
			return 1
		fi
		[ "$from" -le 65535 ] && [ "$to" -le 65535 ] && [ "$from" -le "$to" ] || return 1
	done
}

game_save()
{
	{
		echo "mode=$GAME_FILTER_MODE"
		echo "tcp=$GAME_FILTER_TCP_RANGE"
		echo "udp=$GAME_FILTER_UDP_RANGE"
	} > "$(game_flag_file)"
	game_load
}

game_restart_hint()
{
	if engine_running; then
		if confirm "Перезапустить обход, чтобы применить изменения?" y; then
			service_apply "$(state_get current)"
		fi
	fi
}

game_set()
{
	game_load
	case "$1" in
		"") game_menu; return ;;
		off|disabled) GAME_FILTER_MODE=disabled ;;
		all|tcp|udp) GAME_FILTER_MODE="$1" ;;
		*) err "Использование: zapret game [off|all|tcp|udp]"; return 1 ;;
	esac
	game_save
	echo "Фильтр игр: $GAME_FILTER_STATUS"
	game_restart_hint
}

game_ports_set()
{
	local proto="$1" range="${2// /}"
	game_load
	if ! game_range_valid "$range"; then
		err "Неверные порты: \"$range\". Пример: 1024-1934,1936-65535"
		return 1
	fi
	case "$proto" in
		tcp) GAME_FILTER_TCP_RANGE="$range" ;;
		udp) GAME_FILTER_UDP_RANGE="$range" ;;
		all) GAME_FILTER_TCP_RANGE="$range"; GAME_FILTER_UDP_RANGE="$range" ;;
		*) err "Использование: zapret game-ports tcp|udp|all ДИАПАЗОН"; return 1 ;;
	esac
	game_save
	echo "Порты TCP: $GAME_FILTER_TCP_RANGE, UDP: $GAME_FILTER_UDP_RANGE"
	game_restart_hint
}

game_menu()
{
	local choice range
	while :; do
		game_load
		echo
		info "Фильтр игр: $GAME_FILTER_STATUS"
		echo "Обрабатывает игровой трафик на портах выше 1023 для адресов из IPSet."
		printf '  1. %s Выключить\n' "$([ "$GAME_FILTER_MODE" = disabled ] && echo '*' || echo ' ')"
		printf '  2. %s TCP и UDP\n' "$([ "$GAME_FILTER_MODE" = all ] && echo '*' || echo ' ')"
		printf '  3. %s TCP\n' "$([ "$GAME_FILTER_MODE" = tcp ] && echo '*' || echo ' ')"
		printf '  4. %s UDP\n' "$([ "$GAME_FILTER_MODE" = udp ] && echo '*' || echo ' ')"
		echo
		echo "  5. Порты TCP (сейчас: $GAME_FILTER_TCP_RANGE)"
		echo "  6. Порты UDP (сейчас: $GAME_FILTER_UDP_RANGE)"
		echo "  7. Порты TCP и UDP"
		echo
		echo "  0. Назад"
		read -r -p "Выберите пункт: " choice || return 0
		case "$choice" in
			1) game_set off ;;
			2) game_set all ;;
			3) game_set tcp ;;
			4) game_set udp ;;
			5|6|7)
				read -r -p "Порты и диапазоны (пример: 1024-1934,1936-65535): " range || continue
				case "$choice" in
					5) game_ports_set tcp "$range" ;;
					6) game_ports_set udp "$range" ;;
					7) game_ports_set all "$range" ;;
				esac
				;;
			0|"") return 0 ;;
			*) warn "Нет такого пункта." ;;
		esac
	done
}

# --- активные фейки

fake_current_name()
{
	# $1 - файл ACTIVE_*. Определяет, с какого фейка он скопирован
	local hash file
	[ -f "$1" ] || { echo "(нет файла)"; return; }
	hash="$(sha256sum "$1" | cut -d' ' -f1)"
	for file in "$FAKE_DIR"/*.bin; do
		case "${file##*/}" in ACTIVE_*) continue ;; esac
		if [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$hash" ]; then
			basename "$file" .bin
			return
		fi
	done
	echo "(не найден)"
}

fakes_menu()
{
	local files=() file i choice type number active changed=0
	for file in "$FAKE_DIR"/*.bin; do
		case "${file##*/}" in ACTIVE_*) continue ;; esac
		files+=("$file")
	done
	while :; do
		echo
		info "Активные фейки"
		echo "  1. Discord UDP     (сейчас: $(fake_current_name "$FAKE_DIR/ACTIVE_DISCORD_UDP.bin"))"
		echo "  2. Фильтр игр UDP  (сейчас: $(fake_current_name "$FAKE_DIR/ACTIVE_GAME_UDP.bin"))"
		echo
		echo "Файлы фейков:"
		for i in "${!files[@]}"; do
			printf '  %2d. %s\n' "$((i + 1))" "$(basename "${files[$i]}" .bin)"
		done
		echo
		echo "Введите тип и номер файла. Например, \"1 4\" заменит Discord UDP на файл номер 4."
		read -r -p "Выбор (Enter - назад): " choice || break
		[ -z "$choice" ] || [ "$choice" = 0 ] && break
		read -r type number <<< "$choice"
		case "$type" in
			1) active="$FAKE_DIR/ACTIVE_DISCORD_UDP.bin" ;;
			2) active="$FAKE_DIR/ACTIVE_GAME_UDP.bin" ;;
			*) warn "Неверный тип фейка."; continue ;;
		esac
		if ! [[ "${number:-}" =~ ^[0-9]+$ ]] || [ "$number" -lt 1 ] || [ "$number" -gt ${#files[@]} ]; then
			warn "Неверный номер файла."
			continue
		fi
		if cp -f "${files[$((number - 1))]}" "$active"; then
			ok "Фейк заменён."
			changed=1
		else
			err "Не удалось заменить файл."
		fi
	done
	# фейки загружаются при запуске nfqws2
	[ "$changed" = 1 ] && game_restart_hint
	return 0
}
