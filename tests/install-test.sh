#!/usr/bin/env bash
# Проверка установки и удаления: install.sh, uninstall.sh и пакет .deb через настоящий dpkg.
# Системные папки подменены наложением в отдельном пространстве имён, поэтому компьютер не меняется,
# а systemctl заменён заглушкой, чтобы проверка не могла обратиться к настоящим службам.
# Прав администратора не требует.
#
#   tests/install-test.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID=org.zapretcap.ZapretCap

if [ "${INSTALL_STAGE:-}" != inside ]; then
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/zapret-cap-install.XXXXXX")"
	chmod 755 "$WORK"
	echo "Сборка пакета..."
	"$REPO/packaging/build-deb.sh" >/dev/null || exit 1
	INSTALL_STAGE=inside WORK="$WORK" unshare --user --map-auto --map-root-user --net --mount --pid --fork --mount-proc --kill-child bash "${BASH_SOURCE[0]}" "$@"
	code=$?
	find "$WORK" -mindepth 1 -delete 2>/dev/null
	rmdir "$WORK" 2>/dev/null
	exit $code
fi

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  ok    $*"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL  $*"; }
check()
{
	local title="$1"
	shift
	if "$@" >/dev/null 2>&1; then pass "$title"; else fail "$title"; fi
}
check_not()
{
	local title="$1"
	shift
	if "$@" >/dev/null 2>&1; then fail "$title"; else pass "$title"; fi
}

overlay()
{
	local name="${1//\//_}"
	mkdir -p "$WORK/ovl/$name/up" "$WORK/ovl/$name/work"
	mount -t overlay overlay -o "lowerdir=$1,upperdir=$WORK/ovl/$name/up,workdir=$WORK/ovl/$name/work" "$1" || exit 1
}

mount -t tmpfs tmpfs /opt
mount -t tmpfs tmpfs /usr/local/bin
# Наложение нельзя дописать в подпапку, принадлежащую настоящему root: в этом пространстве такого пользователя нет.
# Поэтому каждая папка, куда что-то пишется, подменяется отдельно
for dir in /usr/share/applications /usr/share/icons/hicolor /usr/share/icons/hicolor/scalable/apps /usr/share/metainfo \
	/usr/share/polkit-1/actions /var/lib /usr/bin /etc/systemd/system; do
	[ -d "$dir" ] && overlay "$dir"
done
# своя копия базы dpkg: настоящую нельзя и не нужно менять, а списки файлов нужны, чтобы dpkg видел чужие папки
export DPKG_ADMINDIR="$WORK/dpkg"
mkdir -p "$DPKG_ADMINDIR/info" "$DPKG_ADMINDIR/updates" "$DPKG_ADMINDIR/triggers"
# если приложение уже стоит на этом компьютере из пакета, копия базы не должна об этом знать
awk -v RS= -v ORS='\n\n' '!/^Package: zapret-cap\n/' /var/lib/dpkg/status > "$DPKG_ADMINDIR/status"
for list in /var/lib/dpkg/info/*.list; do
	case "${list##*/}" in zapret-cap.*|zapret-cap:*) continue ;; esac
	cp "$list" "$DPKG_ADMINDIR/info/"
done

mkdir -p "$WORK/bin" "$WORK/home/Desktop" "$WORK/run" "$WORK/xdg"
chmod 700 "$WORK/xdg"
cat > "$WORK/bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$SYSTEMCTL_LOG"
exit 0
EOF
# su здесь не работает: настоящий переход на другого пользователя невозможен в этом пространстве
cat > "$WORK/bin/su" <<'EOF'
#!/bin/bash
exec bash -c "$5"
EOF
chmod +x "$WORK/bin/systemctl" "$WORK/bin/su"
export PATH="$WORK/bin:$PATH" SYSTEMCTL_LOG="$WORK/systemctl.log"
export HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/xdg"
export ZAPRET_SKIP_PACKAGES=1 ZAPRET_NO_SYSTEMD=1 ZAPRET_RUN="$WORK/run"
: > "$SYSTEMCTL_LOG"

installed()
{
	check "команда zapret работает" zapret version
	check "иконка на месте" test -f "/usr/share/icons/hicolor/scalable/apps/$APP_ID.svg"
	check "запись в меню приложений на месте" test -f "/usr/share/applications/$APP_ID.desktop"
	check "запись прошла проверку" desktop-file-validate "/usr/share/applications/$APP_ID.desktop"
	check "правило окна пароля на месте" test -f "/usr/share/polkit-1/actions/$APP_ID.policy"
	check "карточка для центра приложений на месте" test -f "/usr/share/metainfo/$APP_ID.metainfo.xml"
	check "движок собран" test -x /opt/zapret-cap/core/nfq2/nfqws2
	local exec_path
	exec_path="$(sed -n 's/^Exec=//p' "/usr/share/applications/$APP_ID.desktop" | head -n1)"
	check "ярлык ведёт на существующую программу" test -x "$exec_path"
	check "обычный пользователь может читать файлы" find /opt/zapret-cap/gui -type f -perm -a+r -name main.py -print -quit
	# окно должно открыться именно так, как его запустит меню приложений
	GDK_BACKEND=broadway BROADWAY_DISPLAY=:9 GSETTINGS_BACKEND=memory GSK_RENDERER=cairo NO_AT_BRIDGE=1 ZAPRET_GUI_NON_UNIQUE=1 \
		timeout 6 "$exec_path" >"$WORK/gui.log" 2>&1
	if [ $? -eq 124 ]; then pass "окно открывается из установленной папки"; else fail "окно открывается из установленной папки: $(tail -n 2 "$WORK/gui.log")"; fi
}

removed()
{
	check_not "папки программы нет" test -e /opt/zapret-cap
	check_not "записи в меню нет" test -e "/usr/share/applications/$APP_ID.desktop"
	check_not "иконки нет" test -e "/usr/share/icons/hicolor/scalable/apps/$APP_ID.svg"
	check_not "правила пароля нет" test -e "/usr/share/polkit-1/actions/$APP_ID.policy"
	check_not "карточки нет" test -e "/usr/share/metainfo/$APP_ID.metainfo.xml"
}

gtk4-broadwayd :9 --port 8089 --address 127.0.0.1 >"$WORK/broadway.log" 2>&1 &
sleep 1

echo "install.sh"
SUDO_USER=daemon bash "$REPO/install.sh" >"$WORK/install.log" 2>&1
if [ $? -eq 0 ]; then pass "установка завершилась"; else fail "установка завершилась: $(tail -n 3 "$WORK/install.log")"; fi
installed
check "ярлык появился на рабочем столе" test -x "$HOME/Desktop/$APP_ID.desktop"

echo "обновление через install.sh сохраняет настройки"
zapret add keep-me.example >/dev/null 2>&1
zapret game tcp >/dev/null 2>&1
bash "$REPO/install.sh" >"$WORK/install2.log" 2>&1
check "добавленный сайт сохранился" grep -qx keep-me.example /opt/zapret-cap/lists/list-general.txt
check "фильтр игр сохранился" sh -c 'zapret state | grep -qx game_mode=tcp'

echo "uninstall.sh"
PKEXEC_UID=2 SUDO_USER=daemon /opt/zapret-cap/uninstall.sh --yes >"$WORK/uninstall.log" 2>&1
if [ $? -eq 0 ]; then pass "удаление завершилось"; else fail "удаление завершилось: $(tail -n 3 "$WORK/uninstall.log")"; fi
removed
check_not "команды zapret нет" test -e /usr/local/bin/zapret
check_not "ярлык убран с рабочего стола" test -e "$HOME/Desktop/$APP_ID.desktop"

echo "пакет .deb"
# bash помнит путь к команде из прошлой установки, а теперь она лежит в другой папке
hash -r
DEB="$(ls "$REPO"/dist/zapret-cap_*_all.deb | tail -n 1)"
dpkg_run() { dpkg --force-depends --no-triggers --log=/dev/null "$@"; }
dpkg_run -i "$DEB" >"$WORK/dpkg1.log" 2>&1
if [ $? -eq 0 ]; then pass "dpkg устанавливает пакет"; else fail "dpkg устанавливает пакет: $(tail -n 4 "$WORK/dpkg1.log")"; fi
check "dpkg считает пакет установленным" sh -c "dpkg-query -W -f='\${Status}' zapret-cap | grep -q 'install ok installed'"
installed

echo "обновление пакета сохраняет настройки"
zapret add keep-me.example >/dev/null 2>&1
zapret game udp >/dev/null 2>&1
zapret use general >/dev/null 2>&1
dpkg_run -i "$DEB" >"$WORK/dpkg2.log" 2>&1
if [ $? -eq 0 ]; then pass "dpkg обновляет пакет"; else fail "dpkg обновляет пакет: $(tail -n 4 "$WORK/dpkg2.log")"; fi
check "добавленный сайт сохранился" grep -qx keep-me.example /opt/zapret-cap/lists/list-general.txt
check "фильтр игр сохранился" sh -c 'zapret state | grep -qx game_mode=udp'
check "выбранная стратегия сохранилась" sh -c 'zapret state | grep -qx current=general'
check "временная копия настроек убрана" sh -c '! test -e /var/lib/zapret-cap'
zapret stop >/dev/null 2>&1

echo "удаление пакета кнопкой приложения"
zapret uninstall --yes >"$WORK/dpkg3.log" 2>&1
if [ $? -eq 0 ]; then pass "кнопка удаления завершилась"; else fail "кнопка удаления завершилась: $(tail -n 3 "$WORK/dpkg3.log")"; fi
check_not "dpkg больше не видит пакет" sh -c "dpkg-query -W -f='\${Status}' zapret-cap 2>/dev/null | grep -q 'install ok installed'"
removed
check_not "команды zapret нет" test -e /usr/bin/zapret

echo "службы компьютера"
if grep -vE 'zapret-cap\.service|daemon-reload' "$SYSTEMCTL_LOG" | grep -q .; then
	fail "обращения только к своей службе: $(grep -vE 'zapret-cap\.service|daemon-reload' "$SYSTEMCTL_LOG" | head -n 2)"
else
	pass "обращения только к своей службе"
fi

echo
echo "Пройдено: $PASSED, ошибок: $FAILED"
[ "$FAILED" -eq 0 ]
