# Команды для графического интерфейса: вывод разбирает программа, поэтому формат строгий.
# Чтение работает без прав администратора, чтобы интерфейс не спрашивал пароль просто так

api_state()
{
	local line
	game_load
	printf 'version=%s\n' "$(cap_version)"
	printf 'flowseal=%s\n' "$(flowseal_version)"
	printf 'home=%s\n' "$Z_HOME"
	printf 'engine_built=%s\n' "$([ -x "$NFQWS" ] && echo 1 || echo 0)"
	printf 'running=%s\n' "$(engine_running && echo 1 || echo 0)"
	printf 'running_strategy=%s\n' "$(state_get running_strategy)"
	printf 'current=%s\n' "$(state_get current)"
	printf 'enabled=%s\n' "$(state_get enabled 0)"
	printf 'autostart=%s\n' "$(state_get autostart 1)"
	printf 'systemd=%s\n' "$(has_systemd && echo 1 || echo 0)"
	printf 'game_mode=%s\n' "$GAME_FILTER_MODE"
	printf 'game_tcp=%s\n' "$GAME_FILTER_TCP_RANGE"
	printf 'game_udp=%s\n' "$GAME_FILTER_UDP_RANGE"
	printf 'ipset=%s\n' "$(ipset_status)"
	printf 'ipset_backup=%s\n' "$([ -f "$LISTS_DIR/ipset-all.txt.backup" ] && echo 1 || echo 0)"
	printf 'update_check=%s\n' "$([ -f "$(update_check_flag)" ] && echo 1 || echo 0)"
	printf 'update_available=%s\n' "$(cat "$RUN_DIR/update-available" 2>/dev/null)"
	printf 'firewall=%s\n' "$(fw_type)"
	printf 'results_dir=%s\n' "$RESULTS_DIR"
	while IFS= read -r line; do
		[ -n "$line" ] && printf 'foreign=%s\n' "$line"
	done < <(foreign_bypass)
	return 0
}

# имя, итоги теста сайтов (ok, ошибки, не поддерживается, ping ok, ping нет),
# итоги DPI-теста (ok, ошибки, не поддерживается, замирания) и общая оценка 0-100. Пустое поле - тест не запускался
api_strategies()
{
	strategy_table
}

api_fakes()
{
	local file
	printf 'discord=%s\n' "$(fake_current_name "$FAKE_DIR/ACTIVE_DISCORD_UDP.bin")"
	printf 'game=%s\n' "$(fake_current_name "$FAKE_DIR/ACTIVE_GAME_UDP.bin")"
	for file in "$FAKE_DIR"/*.bin; do
		case "${file##*/}" in ACTIVE_*) continue ;; esac
		printf 'file=%s\n' "$(basename "$file" .bin)"
	done
}

fakes_set()
{
	local type="$1" name="$2" active
	case "$type" in
		discord) active="$FAKE_DIR/ACTIVE_DISCORD_UDP.bin" ;;
		game) active="$FAKE_DIR/ACTIVE_GAME_UDP.bin" ;;
		*) err "Использование: zapret fakes set discord|game ИМЯ"; return 1 ;;
	esac
	case "$name" in
		''|*/*|ACTIVE_*) err "Неверное имя фейка: \"$name\""; return 1 ;;
	esac
	if [ ! -f "$FAKE_DIR/$name.bin" ]; then
		err "Нет такого фейка: $name"
		return 1
	fi
	cp -f "$FAKE_DIR/$name.bin" "$active" || { err "Не удалось заменить файл."; return 1; }
	ok "Фейк заменён: $name."
	# фейки загружаются при запуске nfqws2
	game_restart_hint
}

# Прогресс для интерфейса: строка "@тип<TAB>поле<TAB>поле"
machine_say()
{
	[ "${TEST_MACHINE:-0}" = 1 ] || return 0
	local IFS=$'\t'
	printf '@%s\n' "$*"
}

# Интерфейс работает от обычного пользователя и не может послать сигнал тесту, запущенному от root
tests_cancel()
{
	local pid
	pid="$(cat "$RUN_DIR/test.pid" 2>/dev/null)"
	if [ -z "$pid" ] || [ ! -d "/proc/$pid" ] || ! grep -qa zapret "/proc/$pid/cmdline" 2>/dev/null; then
		echo "Тест не запущен."
		return 0
	fi
	kill -TERM "$pid"
}
