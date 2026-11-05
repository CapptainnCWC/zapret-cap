# Служба: автозапуск через systemd. На системах без systemd обход работает до перезагрузки

UNIT_NAME=zapret-cap.service
UNIT_FILE="/etc/systemd/system/$UNIT_NAME"

has_systemd()
{
	[ -z "${ZAPRET_NO_SYSTEMD:-}" ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

unit_write()
{
	cat > "$UNIT_FILE" <<EOF
[Unit]
Description=zapret cap - DPI bypass
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=$PIDFILE
ExecStart="$Z_HOME/zapret" daemon-start
ExecStop="$Z_HOME/zapret" daemon-stop
ExecStopPost="$Z_HOME/zapret" daemon-stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
}

autostart_wanted()
{
	[ "$(state_get autostart 1)" = 1 ]
}

# включить выбранную стратегию (аналог Install Service)
service_apply()
{
	local name="$1"
	state_set current "$name"
	state_set enabled 1
	if has_systemd; then
		unit_write
		if autostart_wanted; then
			systemctl enable "$UNIT_NAME" >/dev/null 2>&1
		else
			systemctl disable "$UNIT_NAME" >/dev/null 2>&1
		fi
		# служба могла не знать о процессе, запущенном вручную
		systemctl stop "$UNIT_NAME" >/dev/null 2>&1
		engine_stop
		if ! systemctl start "$UNIT_NAME"; then
			err "Служба не запустилась. Журнал: journalctl -u $UNIT_NAME"
			return 1
		fi
	else
		engine_start "$name" || return 1
		autostart_wanted && warn "systemd не найден: после перезагрузки выполните sudo zapret start."
	fi
	update_check_background
	return 0
}

# выключить обход и убрать из автозапуска (аналог Remove Services)
service_remove()
{
	state_set enabled 0
	if has_systemd; then
		systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1
	fi
	engine_stop
	ok "Обход выключен и убран из автозапуска."
}

# Тестам нужна свободная очередь. Автозапуск при этом не трогаем
service_pause()
{
	if has_systemd && systemctl is-active --quiet "$UNIT_NAME"; then
		systemctl stop "$UNIT_NAME" >/dev/null 2>&1
	fi
	engine_stop
}

service_resume()
{
	local name
	name="$(state_get current)"
	[ "$(state_get enabled 0)" = 1 ] && [ -n "$name" ] || return 0
	if has_systemd; then
		systemctl start "$UNIT_NAME" >/dev/null 2>&1
	else
		engine_start "$name"
	fi
}

autostart_set()
{
	case "$1" in
		on) state_set autostart 1 ;;
		off) state_set autostart 0 ;;
		*) err "Использование: zapret autostart on|off"; return 1 ;;
	esac
	if ! has_systemd; then
		warn "systemd не найден: автозапуск на этой системе настраивается вручную."
		return 0
	fi
	if [ "$1" = on ] && [ "$(state_get enabled 0)" = 1 ]; then
		unit_write
		systemctl enable "$UNIT_NAME" >/dev/null 2>&1
	elif [ "$1" = off ]; then
		systemctl disable "$UNIT_NAME" >/dev/null 2>&1
	fi
	ok "Автозапуск: $(autostart_status)"
}

autostart_status()
{
	autostart_wanted && printf 'включён' || printf 'выключен'
}

show_status()
{
	local name foreign
	name="$(state_get current)"
	echo "Версия:     $(cap_version) (стратегии Flowseal $(flowseal_version))"
	echo "Установлен: $Z_HOME"
	if engine_running; then
		ok "Обход:      работает, стратегия \"$(state_get running_strategy "$name")\""
	else
		err "Обход:      выключен"
		[ -n "$name" ] && echo "Последняя стратегия: $name"
	fi
	if has_systemd; then
		echo "Автозапуск: $(systemctl is-enabled "$UNIT_NAME" 2>/dev/null | grep -q '^enabled' && echo включён || echo выключен)"
	fi
	echo "Файрвол:    $(fw_present && echo "правила установлены ($(fw_type))" || echo 'правил нет')"
	game_load
	echo "Фильтр игр: $GAME_FILTER_STATUS"
	echo "IPSet:      $(ipset_status)"
	foreign="$(foreign_bypass)"
	if [ -n "$foreign" ]; then
		warn "Работает другое средство обхода - оно мешает этому:"
		printf '  %s\n' "$foreign"
	fi
}
