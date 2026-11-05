# Диагностика, файл hosts и проверка обновлений

HOSTS_FILE=/etc/hosts
HOSTS_BEGIN="# BEGIN zapret-cap"
HOSTS_END="# END zapret-cap"

diag_sep() { echo; }

diag_engine()
{
	if [ -x "$NFQWS" ]; then
		ok "Движок nfqws2 собран."
	else
		err "[X] Движок не собран. Запустите ./install.sh из папки репозитория."
	fi
	case "$(fw_type)" in
		nftables) ok "Файрвол: nftables." ;;
		iptables) ok "Файрвол: iptables." ;;
		*) err "[X] Нет ни nft, ни iptables. Установите пакет nftables." ;;
	esac
	if ! lsmod 2>/dev/null | grep -q '^nfnetlink_queue'; then
		if modprobe nfnetlink_queue 2>/dev/null; then
			ok "Модуль ядра nfnetlink_queue загружен."
		else
			err "[X] Не удалось загрузить модуль ядра nfnetlink_queue. Без него обход не работает."
		fi
	else
		ok "Модуль ядра nfnetlink_queue загружен."
	fi
	if engine_running; then
		ok "Обход работает: \"$(state_get running_strategy)\"."
	else
		warn "[?] Обход сейчас выключен."
		if fw_present; then
			warn "[?] nfqws2 не запущен, но правила файрвола остались. Убираю их..."
			fw_down
			ok "Правила убраны."
		fi
	fi
}

diag_proxy()
{
	local mode user proxy="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-${all_proxy:-}}}}}"
	user="$(real_user)"
	if [ -n "$user" ] && command -v gsettings >/dev/null 2>&1; then
		mode="$(sudo -u "$user" gsettings get org.gnome.system.proxy mode 2>/dev/null)"
		[ "$mode" = "'manual'" ] && proxy="${proxy:-настройки GNOME}"
	fi
	if [ -n "$proxy" ]; then
		warn "[?] Включён системный прокси: $proxy"
		warn "Убедитесь, что он рабочий, или выключите его, если не пользуетесь."
	else
		ok "Системного прокси нет."
	fi
}

diag_timestamps()
{
	if [ "$(cat /proc/sys/net/ipv4/tcp_timestamps 2>/dev/null)" = 0 ]; then
		warn "[?] TCP timestamps выключены. Включаю..."
		if echo 1 > /proc/sys/net/ipv4/tcp_timestamps 2>/dev/null; then
			ok "TCP timestamps включены."
		else
			err "[X] Не удалось включить TCP timestamps."
		fi
	else
		ok "TCP timestamps включены."
	fi
}

diag_adguard()
{
	if pgrep -if adguard >/dev/null 2>&1; then
		err "[X] Работает AdGuard. Он может мешать работе Discord."
	else
		ok "AdGuard не обнаружен."
	fi
}

diag_path()
{
	if printf '%s' "$Z_HOME" | LC_ALL=C grep -q '[^ -~]'; then
		warn "[?] В пути установки есть не латинские символы: $Z_HOME"
		warn "Если обход не работает, установите его заново через ./install.sh"
	else
		ok "Путь установки в порядке: $Z_HOME"
	fi
}

diag_vpn()
{
	local ifaces
	ifaces="$(ip -o link show up 2>/dev/null | awk -F': ' '{ print $2 }' | sed 's/@.*//' | grep -E '^(tun|tap|wg|ppp|nordlynx|proton|mullvad|tailscale|outline|amn)' | tr '\n' ' ')"
	if [ -n "$ifaces" ]; then
		warn "[?] Найдены VPN-интерфейсы: $ifaces"
		warn "Некоторые VPN конфликтуют с обходом. Убедитесь, что VPN выключен."
	else
		ok "VPN не обнаружен."
	fi
}

diag_dns()
{
	if command -v resolvectl >/dev/null 2>&1 && resolvectl status 2>/dev/null | grep -qE '\+DNSOverTLS|DNSOverTLS=(yes|opportunistic)'; then
		ok "Системный DNS зашифрован (DNS over TLS)."
	else
		warn "[?] Включите защищённый DNS в браузере и выберите поставщика, отличного от установленного по умолчанию."
		warn "Как это сделать, написано в README."
	fi
}

diag_hosts()
{
	if grep -v "^[[:space:]]*#" "$HOSTS_FILE" 2>/dev/null | grep -qiE 'youtube\.com|youtu\.be'; then
		warn "[?] В файле hosts есть записи для youtube.com или youtu.be. Это может мешать работе YouTube."
	fi
}

diag_conflicts()
{
	local foreign units unit
	foreign="$(foreign_bypass)"
	if [ -z "$foreign" ]; then
		ok "Других средств обхода не найдено."
		return 0
	fi
	err "[X] Работают другие средства обхода:"
	printf '  %s\n' "$foreign"
	has_systemd || { warn "Остановите их вручную."; return 0; }
	units="$(systemctl list-units --type=service --state=active --plain --no-legend 2>/dev/null | awk '{ print $1 }' | grep -E '^(zapret|zapret2|nfqws|nfqws2|tpws|byedpi|ciadpi|spoofdpi|dpitunnel|goodbyedpi)[@.]' | grep -v "^$UNIT_NAME\$")"
	if [ -z "$units" ]; then
		warn "Службы для них не найдены. Остановите их вручную."
		return 0
	fi
	echo "Службы: $units"
	if confirm "Остановить и отключить эти службы? Файлы останутся на месте." n; then
		for unit in $units; do
			if systemctl disable --now "$unit" >/dev/null 2>&1; then
				ok "Служба $unit остановлена."
			else
				err "[X] Не удалось остановить $unit."
			fi
		done
	fi
}

clear_discord_cache()
{
	local name="$1" process="$2" dir="$3" sub
	if pgrep -x "$process" >/dev/null 2>&1; then
		echo "$name запущен, закрываю..."
		pkill -x "$process" 2>/dev/null && ok "$name закрыт." || err "Не удалось закрыть $name."
		sleep 1
	fi
	for sub in "Cache" "Code Cache" "GPUCache"; do
		if [ -d "$dir/$sub" ]; then
			if rm -rf "${dir:?}/$sub"; then
				ok "Удалено: $dir/$sub"
			else
				err "Не удалось удалить: $dir/$sub"
			fi
		fi
	done
}

diag_discord()
{
	local home found=0
	home="$(real_home)"
	# закрывает приложение и удаляет файлы, поэтому только по прямому ответу человека
	[ -t 0 ] || [ "${ASSUME_YES:-0}" = 1 ] || return 0
	confirm "Очистить кэш Discord? Он будет закрыт, если запущен." y || return 0
	if [ -d "$home/.config/discord" ]; then found=1; clear_discord_cache "Discord" Discord "$home/.config/discord"; fi
	if [ -d "$home/.config/discordptb" ]; then found=1; clear_discord_cache "Discord PTB" DiscordPTB "$home/.config/discordptb"; fi
	if [ -d "$home/.config/discordcanary" ]; then found=1; clear_discord_cache "Discord Canary" DiscordCanary "$home/.config/discordcanary"; fi
	if [ -d "$home/.config/discorddevelopment" ]; then found=1; clear_discord_cache "Discord Development" DiscordDevelopment "$home/.config/discorddevelopment"; fi
	if [ -d "$home/.var/app/com.discordapp.Discord/config/discord" ]; then found=1; clear_discord_cache "Discord (Flatpak)" Discord "$home/.var/app/com.discordapp.Discord/config/discord"; fi
	[ "$found" = 1 ] || warn "Discord не найден."
}

diagnostics()
{
	echo
	diag_path; diag_sep
	diag_engine; diag_sep
	diag_timestamps; diag_sep
	diag_proxy; diag_sep
	diag_adguard; diag_sep
	diag_vpn; diag_sep
	diag_dns; diag_sep
	diag_hosts
	diag_conflicts; diag_sep
	diag_discord
}

# --- файл hosts

# скачивает эталон во временный файл и печатает его путь
hosts_fetch()
{
	local tmp
	tmp="$(mktemp)"
	if ! curl -L -s -f -m 20 -o "$tmp" "$GITHUB_FLOWSEAL_RAW/hosts?t=$RANDOM$RANDOM"; then
		err "Не удалось скачать файл hosts из репозитория Flowseal."
		rm -f "$tmp"
		return 1
	fi
	sed -i 's/\r$//' "$tmp"
	printf '%s' "$tmp"
}

# Как в оригинале: первая и последняя строки эталона должны быть в hosts
hosts_is_current()
{
	local first last
	first="$(grep -m1 . "$1")"
	last="$(grep . "$1" | tail -n 1)"
	grep -qxF -- "$first" "$HOSTS_FILE" && grep -qxF -- "$last" "$HOSTS_FILE"
}

# для интерфейса: код 0 - актуален, 3 - нужно обновить, 1 - не удалось проверить
hosts_check()
{
	local tmp rc=0
	tmp="$(hosts_fetch)" || return 1
	if hosts_is_current "$tmp"; then
		ok "Файл hosts актуален."
	else
		warn "Файл hosts нужно обновить. Строк к добавлению: $(grep -c . "$tmp")"
		rc=3
	fi
	rm -f "$tmp"
	return $rc
}

hosts_update()
{
	local tmp
	[ "${1:-}" = --yes ] && ASSUME_YES=1
	echo "Проверяю файл hosts..."
	tmp="$(hosts_fetch)" || return 1
	if hosts_is_current "$tmp"; then
		ok "Файл hosts актуален."
		rm -f "$tmp"
		return 0
	fi
	warn "Файл hosts нужно обновить. Строк к добавлению: $(grep -c . "$tmp")"
	if ! confirm "Записать их в $HOSTS_FILE? Копия сохранится в $HOSTS_FILE.zapret-cap.bak" n; then
		echo "Файл для ручного копирования: $GITHUB_FLOWSEAL_RAW/hosts"
		rm -f "$tmp"
		return 0
	fi
	cp -p "$HOSTS_FILE" "$HOSTS_FILE.zapret-cap.bak"
	hosts_strip_block
	{
		echo "$HOSTS_BEGIN"
		cat "$tmp"
		echo "$HOSTS_END"
	} >> "$HOSTS_FILE"
	rm -f "$tmp"
	ok "Файл hosts обновлён."
}

hosts_strip_block()
{
	sed -i "/^$HOSTS_BEGIN\$/,/^$HOSTS_END\$/d" "$HOSTS_FILE"
}

# --- обновления

update_check_flag()
{
	printf '%s/check_updates.enabled' "$UTILS_DIR"
}

update_check_status()
{
	[ -f "$(update_check_flag)" ] && printf 'включена' || printf 'выключена'
}

update_latest_version()
{
	curl -fsS -m 5 -H 'Cache-Control: no-cache' "$GITHUB_FLOWSEAL_RAW/version.txt" 2>/dev/null | tr -d '\r\n '
}

update_check_now()
{
	local latest local_version
	local_version="$(flowseal_version)"
	latest="$(update_latest_version)"
	if [ -z "$latest" ]; then
		warn "Не удалось узнать последнюю версию. На работу обхода это не влияет."
		return 0
	fi
	if [ "$latest" = "$local_version" ]; then
		ok "Стратегии актуальны: Flowseal $local_version."
	else
		warn "Вышла новая версия стратегий Flowseal: $latest (здесь: $local_version)."
		echo "Страница релиза: $GITHUB_FLOWSEAL_RELEASES"
		echo "Новые .bat переводятся в стратегии так: python3 tools/bat2conf.py"
	fi
}

# не задерживает запуск обхода: результат покажет меню при следующем открытии
update_check_background()
{
	[ -f "$(update_check_flag)" ] || return 0
	(
		latest="$(update_latest_version)"
		if [ -n "$latest" ] && [ "$latest" != "$(flowseal_version)" ]; then
			printf '%s\n' "$latest" > "$RUN_DIR/update-available"
		else
			rm -f "$RUN_DIR/update-available"
		fi
	) >/dev/null 2>&1 &
	disown 2>/dev/null
	return 0
}

update_check_cli()
{
	case "$1" in
		on) echo ENABLED > "$(update_check_flag)"; echo "Автопроверка обновлений: $(update_check_status)" ;;
		off) rm -f "$(update_check_flag)"; echo "Автопроверка обновлений: $(update_check_status)" ;;
		"") update_check_now ;;
		*) err "Использование: zapret update-check [on|off]"; return 1 ;;
	esac
}
