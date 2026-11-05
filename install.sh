#!/usr/bin/env bash
# Установка zapret cap: зависимости, сборка движка, копирование в /opt/zapret-cap
set -u
umask 022

SRC="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
DST=/opt/zapret-cap
APP_ID=org.zapretcap.ZapretCap

if [ "$(id -u)" != 0 ]; then
	echo "Нужны права администратора. Сейчас система может спросить ваш пароль"
	echo "(при вводе символы не отображаются - это нормально)."
	if command -v sudo >/dev/null 2>&1; then
		exec sudo "$SRC/install.sh" "$@"
	elif command -v doas >/dev/null 2>&1; then
		exec doas "$SRC/install.sh" "$@"
	fi
	echo "Не найдены sudo и doas. Запустите установку от имени root." >&2
	exit 1
fi

die()
{
	echo >&2
	echo "ОШИБКА: $*" >&2
	exit 1
}

install_packages()
{
	[ -n "${ZAPRET_SKIP_PACKAGES:-}" ] && return 0
	if command -v apt-get >/dev/null 2>&1; then
		apt-get update && apt-get install -y make gcc pkg-config zlib1g-dev libcap-dev libnetfilter-queue-dev libmnl-dev libnfnetlink-dev libluajit-5.1-dev curl nftables iputils-ping
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y make gcc pkgconf-pkg-config zlib-devel libcap-devel libnetfilter_queue-devel libmnl-devel libnfnetlink-devel luajit-devel curl nftables iputils
	elif command -v pacman >/dev/null 2>&1; then
		pacman -S --needed --noconfirm make gcc pkgconf zlib libcap libnetfilter_queue libmnl libnfnetlink luajit curl nftables iputils
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive install make gcc pkg-config zlib-devel libcap-devel libnetfilter_queue-devel libmnl-devel libnfnetlink-devel luajit-devel curl nftables iputils
	elif command -v apk >/dev/null 2>&1; then
		apk add make gcc musl-dev pkgconf zlib-dev libcap-dev libnetfilter_queue-dev libmnl-dev libnfnetlink-dev luajit-dev curl nftables iputils bash
	else
		echo "Менеджер пакетов не распознан. Установите вручную: make, gcc, pkg-config, zlib, libcap,"
		echo "libnetfilter_queue, libmnl, libnfnetlink, luajit (с заголовками для разработки), curl, nftables."
		return 0
	fi
}

# Без графических библиотек обход работает, просто останется только меню в терминале.
# pkexec в новых версиях Debian и Ubuntu - отдельный пакет, а в старых он входит в policykit-1
install_gui_packages()
{
	[ -n "${ZAPRET_SKIP_PACKAGES:-}" ] && return 0
	if command -v apt-get >/dev/null 2>&1; then
		apt-get install -y python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 && { apt-get install -y pkexec || apt-get install -y policykit-1; }
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y python3-gobject gtk4 libadwaita polkit
	elif command -v pacman >/dev/null 2>&1; then
		pacman -S --needed --noconfirm python-gobject gtk4 libadwaita polkit
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive install python3-gobject typelib-1_0-Gtk-4_0 typelib-1_0-Adw-1 polkit
	elif command -v apk >/dev/null 2>&1; then
		apk add py3-gobject3 gtk4.0 libadwaita polkit
	else
		return 1
	fi
}

# значок, пункт в меню приложений, окно пароля и карточка для центра приложений
install_desktop_files()
{
	local data="$DST/data"
	install -Dm644 "$data/$APP_ID.svg" "/usr/share/icons/hicolor/scalable/apps/$APP_ID.svg"
	install -Dm644 "$data/$APP_ID.desktop" "/usr/share/applications/$APP_ID.desktop"
	install -Dm644 "$data/$APP_ID.policy" "/usr/share/polkit-1/actions/$APP_ID.policy"
	install -Dm644 "$data/$APP_ID.metainfo.xml" "/usr/share/metainfo/$APP_ID.metainfo.xml"
	# запись от прошлой версии, которая открывала терминал
	rm -f /usr/share/applications/zapret-cap.desktop
	command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications
	command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor
	return 0
}

# ярлык на рабочем столе человека, запустившего установку
install_shortcut()
{
	local user="${SUDO_USER:-${DOAS_USER:-}}" desktop target uid
	[ -n "$user" ] && [ "$user" != root ] || return 0
	desktop="$(su -s /bin/bash "$user" -c 'xdg-user-dir DESKTOP' 2>/dev/null)"
	[ -n "$desktop" ] || desktop="$(getent passwd "$user" | cut -d: -f6)/Desktop"
	[ -d "$desktop" ] || return 0
	target="$desktop/$APP_ID.desktop"
	install -o "$user" -m 755 "$DST/data/$APP_ID.desktop" "$target" || return 0
	uid="$(id -u "$user")"
	# без этой отметки GNOME считает ярлык недоверенным и не запускает его
	su -s /bin/bash "$user" -c "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus gio set $(printf %q "$target") metadata::trusted true" >/dev/null 2>&1
	return 0
}

echo "=== 1/4. Установка необходимых пакетов ==="
install_packages || die "Не удалось установить пакеты. Проверьте интернет и повторите запуск."
GUI_PACKAGES=1
install_gui_packages || GUI_PACKAGES=0

echo
echo "=== 2/4. Копирование в $DST ==="
if command -v systemctl >/dev/null 2>&1; then
	systemctl stop zapret-cap.service >/dev/null 2>&1
fi
[ -x "$DST/zapret" ] && "$DST/zapret" daemon-stop >/dev/null 2>&1

if [ "$SRC" != "$DST" ]; then
	# настройки и домены пользователя при обновлении сохраняются
	KEEP="$(mktemp -d)"
	if [ -d "$DST" ]; then
		for item in lists state utils strategies; do
			[ -d "$DST/$item" ] && cp -a "$DST/$item" "$KEEP/"
		done
		mkdir -p "$KEEP/fake"
		cp -a "$DST"/fake/ACTIVE_* "$KEEP/fake/" 2>/dev/null
		rm -rf "$DST"
	fi
	mkdir -p "$DST"
	( cd "$SRC" && tar cf - --exclude=./.git --exclude=./state --exclude='./utils/test results' . ) | tar xf - -C "$DST" || die "Не удалось скопировать файлы."
	if [ -d "$KEEP/lists" ]; then
		cp -a "$KEEP/lists/." "$DST/lists/"
		cp -a "$KEEP/state" "$DST/" 2>/dev/null
		cp -a "$KEEP/utils/." "$DST/utils/"
		cp -a "$KEEP/fake/." "$DST/fake/" 2>/dev/null
		# свои стратегии пользователя: присланные с обновлением файлы не перезаписываем
		cp -an "$KEEP/strategies/." "$DST/strategies/" 2>/dev/null
	fi
	rm -rf "$KEEP"
fi
# nfqws2 работает под непривилегированным пользователем и должен читать эти файлы
chown -R root:root "$DST"
chmod -R a+rX "$DST"
chmod +x "$DST/zapret" "$DST/zapret-gui" "$DST/install.sh" "$DST/uninstall.sh"

echo
echo "=== 3/4. Сборка движка ==="
make -C "$DST/core/nfq2" clean >/dev/null 2>&1
if ! make -C "$DST/core/nfq2" -j"$(nproc 2>/dev/null || echo 2)"; then
	die "Сборка не удалась. Обычно это значит, что не хватает пакетов из шага 1."
fi
[ -x "$DST/core/nfq2/nfqws2" ] || die "Сборка завершилась, но файла nfqws2 нет."
chmod -R a+rX "$DST"

mkdir -p /usr/local/bin
ln -sf "$DST/zapret" /usr/local/bin/zapret

echo
echo "=== 4/4. Добавление в меню приложений ==="
install_desktop_files
install_shortcut

# при обновлении вернуть обход, который работал до него
if [ "$(cat "$DST/state/enabled" 2>/dev/null)" = 1 ]; then
	"$DST/zapret" start
fi

echo
echo "Готово. Откройте приложение Zapret Cap: оно появилось в меню приложений и на рабочем столе."
echo "На главной вкладке нажмите большую кнопку, и приложение подберёт рабочую стратегию."
if [ "$GUI_PACKAGES" = 0 ] || ! python3 -c "import gi; gi.require_version('Gtk', '4.0'); gi.require_version('Adw', '1')" 2>/dev/null; then
	echo
	echo "ВНИМАНИЕ: не удалось установить Python, GTK 4 или libadwaita, поэтому окно приложения не откроется."
	echo "Обход работает и без него: откройте меню командой zapret."
fi

OTHER="$(pgrep -a 'nfqws|nfqws2|tpws' 2>/dev/null | grep -v "$DST" | cut -c1-80)"
if [ -n "$OTHER" ]; then
	echo
	echo "ВНИМАНИЕ: уже работает другое средство обхода, оно будет мешать:"
	echo "$OTHER"
	echo "Отключить его можно на вкладке \"Помощь\" в окне приложения."
fi
