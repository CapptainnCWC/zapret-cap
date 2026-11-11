# Смена стратегий: список, выбор, следующая, автоподбор

# доля успешных проверок, при которой стратегия считается рабочей
AUTO_THRESHOLD=${ZAPRET_AUTO_THRESHOLD:-90}

# general идёт первой: с неё проще всего начать
strategy_names()
{
	local file
	for file in "$STRATEGIES_DIR"/*.conf; do
		[ -f "$file" ] || continue
		file="${file##*/}"
		printf '%s\n' "${file%.conf}"
	done | LC_ALL=C sort -V | awk '$0 == "general" { print; next } { rest[n++] = $0 } END { for (i = 0; i < n; i++) print rest[i] }'
}

# номер, полное имя или короткое: 3, "general (ALT11)", ALT11
strategy_resolve()
{
	local input="$1" names name
	mapfile -t names < <(strategy_names)
	if [[ "$input" =~ ^[0-9]+$ ]]; then
		[ "$input" -ge 1 ] && [ "$input" -le ${#names[@]} ] && { printf '%s' "${names[$((input - 1))]}"; return 0; }
		return 1
	fi
	for name in "${names[@]}"; do
		if [ "${name,,}" = "${input,,}" ] || [ "${name,,}" = "general (${input,,})" ]; then
			printf '%s' "$name"
			return 0
		fi
	done
	return 1
}

list_strategies()
{
	local names i current running mark result
	mapfile -t names < <(strategy_names)
	current="$(state_get current)"
	running="$(state_get running_strategy)"
	local -A results=()
	local line
	while IFS= read -r line; do
		results["${line%%$'\t'*}"]="${line#*$'\t'}"
	done < <(strategy_summaries)
	for i in "${!names[@]}"; do
		mark=" "
		[ "${names[$i]}" = "$current" ] && mark="*"
		result="${results[${names[$i]}]:-}"
		printf ' %s %2d. %s%s\n' "$mark" "$((i + 1))" "${names[$i]}" "${result:+   ${C_GRAY}[$result]$C_OFF}"
	done
	[ -n "$current" ] && printf '\n * текущая стратегия%s\n' "$([ -n "$running" ] && echo ", работает")"
	printf ' Замирание - сколько передач остановилось на 16-20 КБ. Чем меньше, тем лучше.\n'
}

switch_use()
{
	local input="${1:-}" name
	if [ -z "$input" ]; then
		list_strategies
		echo
		read -r -p "Номер стратегии (0 - отмена): " input || return 0
		[ -z "$input" ] || [ "$input" = 0 ] && return 0
	fi
	if ! name="$(strategy_resolve "$input")"; then
		err "Нет такой стратегии: $input. Список: zapret list"
		return 1
	fi
	warn_foreign
	service_apply "$name" || return 1
	ok "Включена стратегия \"$name\"."
	echo "Проверьте сайты в браузере. Если не работает: zapret next"
}

switch_start()
{
	local name
	name="$(state_get current)"
	if [ -z "$name" ]; then
		warn "Стратегия ещё не выбрана."
		switch_use
		return
	fi
	warn_foreign
	service_apply "$name" && ok "Включена стратегия \"$name\"."
}

warn_foreign()
{
	local foreign
	foreign="$(foreign_bypass)"
	if [ -n "$foreign" ]; then
		warn "Работает другое средство обхода. Вместе они могут мешать друг другу:"
		printf '  %s\n' "$foreign"
		warn "Остановить его можно в разделе диагностики: zapret diag"
	fi
}

# порядок перебора: сначала проверенные от лучшей к худшей (см. strategy_rank), потом остальные
strategy_order()
{
	strategy_table | strategy_rank
}

switch_next()
{
	local order current i next
	mapfile -t order < <(strategy_order)
	current="$(state_get current)"
	next="${order[0]}"
	for i in "${!order[@]}"; do
		if [ "${order[$i]}" = "$current" ]; then
			next="${order[$(( (i + 1) % ${#order[@]} ))]}"
			break
		fi
	done
	service_apply "$next" || return 1
	ok "Включена стратегия \"$next\" (раньше: ${current:-нет})."
	echo "Проверьте сайты. Если снова не работает: zapret next или zapret auto"
}

# если нет интернета вообще, перебирать стратегии бессмысленно
network_alive()
{
	local host
	for host in 1.1.1.1 8.8.8.8 9.9.9.9; do
		ping -c 1 -W 1 "$host" >/dev/null 2>&1 && return 0
	done
	return 1
}

# проценты успешных проверок из последнего run_standard
health_percent()
{
	local total=$((STD_OK + STD_ERR))
	[ "$total" -gt 0 ] || { echo 0; return; }
	echo $(( STD_OK * 100 / total ))
}

# Перебирает стратегии, пока одна не пройдёт порог. Если порог не прошёл никто, включает лучшую из найденных
switch_auto()
{
	local current order name percent best="" best_percent=-1 tried=0
	[ "${1:-}" = --machine ] && TEST_MACHINE=1
	tests_defaults
	targets_load >/dev/null
	REPORT_BODY=""
	current="$(state_get current)"

	if ! network_alive; then
		err "Интернета нет: не отвечает ни один публичный DNS. Стратегии здесь ни при чём."
		return 1
	fi

	if [ -n "$current" ] && engine_running; then
		info "Проверяю текущую стратегию \"$current\"..."
		run_standard quiet
		percent="$(health_percent)"
		if [ "$percent" -ge "$AUTO_THRESHOLD" ]; then
			ok "Текущая стратегия работает: успешно $percent% проверок. Менять нечего."
			return 0
		fi
		warn "Успешно только $percent% проверок - ищу другую."
		best="$current"
		best_percent="$percent"
	fi

	TESTS_ACTIVE=1
	trap tests_interrupted INT TERM HUP PIPE
	printf '%s\n' "$$" > "$RUN_DIR/test.pid"
	service_pause
	mapfile -t order < <(strategy_order)
	for name in "${order[@]}"; do
		[ "$name" = "$current" ] && [ "$best" = "$current" ] && continue
		tried=$((tried + 1))
		machine_say progress "$tried" "${#order[@]}" "$name"
		printf '  [%d] %s: ' "$tried" "$name"
		if ! engine_start "$name" >/dev/null 2>&1; then
			err "не запустилась"
			continue
		fi
		run_standard quiet
		engine_stop
		percent="$(health_percent)"
		echo "$percent%"
		if [ "$percent" -gt "$best_percent" ]; then
			best="$name"
			best_percent="$percent"
		fi
		[ "$percent" -ge "$AUTO_THRESHOLD" ] && break
	done
	TESTS_ACTIVE=0
	trap - INT TERM HUP PIPE
	rm -f "$RUN_DIR/test.pid"

	if [ -z "$best" ]; then
		err "Ни одна стратегия не запустилась."
		service_resume
		return 1
	fi
	service_apply "$best" || return 1
	if [ "$best_percent" -ge "$AUTO_THRESHOLD" ]; then
		ok "Включена стратегия \"$best\": успешно $best_percent% проверок."
	else
		warn "Стратегий с результатом от $AUTO_THRESHOLD% нет. Включена лучшая: \"$best\" ($best_percent%)."
		warn "Попробуйте zapret diag или полный тест: zapret test standard all"
	fi
}
