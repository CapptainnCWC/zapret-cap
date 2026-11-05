#!/usr/bin/env bash
# Полное удаление zapret cap. С --yes не спрашивает: кнопка в окне приложения уже спросила
set -u

DST=/opt/zapret-cap
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

if [ "$(id -u)" != 0 ]; then
	if command -v sudo >/dev/null 2>&1; then
		exec sudo "$SELF" "$@"
	elif command -v doas >/dev/null 2>&1; then
		exec doas "$SELF" "$@"
	fi
	echo "Запустите от имени root." >&2
	exit 1
fi

if [ "${1:-}" != --yes ]; then
	read -r -p "Удалить zapret cap вместе с добавленными доменами и настройками? [y/N] " answer
	case "$answer" in
		y|Y|д|Д) ;;
		*) echo "Отменено."; exit 0 ;;
	esac
fi

# установлено из пакета: удалять должен менеджер пакетов, иначе он будет считать программу установленной
if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' zapret-cap 2>/dev/null | grep -q 'install ok installed'; then
	dpkg --purge zapret-cap
	exit $?
fi

if command -v systemctl >/dev/null 2>&1; then
	systemctl disable --now zapret-cap.service >/dev/null 2>&1
	rm -f /etc/systemd/system/zapret-cap.service
	systemctl daemon-reload
fi
[ -x "$DST/zapret" ] && "$DST/zapret" daemon-stop >/dev/null 2>&1

# блок, который мог записать пункт "Обновить файл hosts"
if grep -q '^# BEGIN zapret-cap$' /etc/hosts 2>/dev/null; then
	sed -i '/^# BEGIN zapret-cap$/,/^# END zapret-cap$/d' /etc/hosts
fi

# ярлык на рабочем столе человека, который удаляет приложение
user="${SUDO_USER:-${DOAS_USER:-}}"
[ -z "$user" ] && [ -n "${PKEXEC_UID:-}" ] && user="$(id -nu "$PKEXEC_UID" 2>/dev/null)"
if [ -n "$user" ] && [ "$user" != root ]; then
	desktop="$(su -s /bin/bash "$user" -c 'xdg-user-dir DESKTOP' 2>/dev/null)"
	[ -n "$desktop" ] && rm -f -- "$desktop/org.zapretcap.ZapretCap.desktop"
fi

rm -f /usr/local/bin/zapret /usr/share/applications/zapret-cap.desktop
rm -f /usr/share/applications/org.zapretcap.ZapretCap.desktop
rm -f /usr/share/icons/hicolor/scalable/apps/org.zapretcap.ZapretCap.svg
rm -f /usr/share/polkit-1/actions/org.zapretcap.ZapretCap.policy
rm -f /usr/share/metainfo/org.zapretcap.ZapretCap.metainfo.xml
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor
rm -rf /opt/zapret-cap
echo "Удалено."
