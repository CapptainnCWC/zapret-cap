# Общие функции: пути, вывод, вопросы пользователю, состояние

STRATEGIES_DIR="$Z_HOME/strategies"
LISTS_DIR="$Z_HOME/lists"
FAKE_DIR="$Z_HOME/fake"
UTILS_DIR="$Z_HOME/utils"
STATE_DIR="${ZAPRET_STATE:-$Z_HOME/state}"
RUN_DIR="${ZAPRET_RUN:-/run/zapret-cap}"
RESULTS_DIR="$UTILS_DIR/test results"

NFQWS="$Z_HOME/core/nfq2/nfqws2"

GITHUB_FLOWSEAL_RAW="https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service"
GITHUB_FLOWSEAL_RELEASES="https://github.com/Flowseal/zapret-discord-youtube/releases/latest"

if [ -t 1 ]; then
	C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m' C_GRAY=$'\e[90m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
else
	C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_GRAY='' C_BOLD='' C_OFF=''
fi

ok() { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF"; }
err() { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF" >&2; }
info() { printf '%s%s%s\n' "$C_CYAN" "$*" "$C_OFF"; }

cap_version()
{
	sed -n 's/^ZAPRET_CAP=//p' "$Z_HOME/VERSION"
}
flowseal_version()
{
	sed -n 's/^FLOWSEAL=//p' "$Z_HOME/VERSION"
}

need_root()
{
	[ "$(id -u)" = 0 ] && return 0
	local self="$Z_HOME/zapret"
	echo "Нужны права администратора. Сейчас система может спросить ваш пароль"
	echo "(при вводе символы не отображаются - это нормально)."
	if command -v sudo >/dev/null 2>&1; then
		exec sudo "$self" "$@"
	elif command -v doas >/dev/null 2>&1; then
		exec doas "$self" "$@"
	elif command -v pkexec >/dev/null 2>&1; then
		exec pkexec "$self" "$@"
	fi
	err "Не найдены sudo, doas и pkexec. Запустите от имени root."
	exit 1
}

prepare_dirs()
{
	mkdir -p "$STATE_DIR" "$RUN_DIR" "$RESULTS_DIR" 2>/dev/null
}

pause()
{
	[ -t 0 ] || return 0
	# тесты идут минутами: случайно нажатые за это время клавиши не должны закрывать экран
	while read -r -t 0.01 -n 256 _; do :; done
	read -r -p "Нажмите Enter, чтобы продолжить..." _ || true
}

# confirm "Вопрос" y|n : ответ по умолчанию во втором аргументе
confirm()
{
	local prompt="$1" def="${2:-n}" answer hint="[y/N]"
	# вопрос уже задан в окне приложения
	[ "${ASSUME_YES:-0}" = 1 ] && return 0
	[ "$def" = y ] && hint="[Y/n]"
	if [ ! -t 0 ]; then
		[ "$def" = y ]
		return
	fi
	read -r -p "$prompt $hint " answer || answer=""
	answer="${answer:-$def}"
	case "$answer" in
		y|Y|д|Д|yes|да|Да) return 0 ;;
		*) return 1 ;;
	esac
}

state_get()
{
	# $1 - name, $2 - default
	local value
	value="$(cat "$STATE_DIR/$1" 2>/dev/null)" && [ -n "$value" ] && { printf '%s' "$value"; return; }
	printf '%s' "${2:-}"
}
state_set()
{
	printf '%s\n' "$2" > "$STATE_DIR/$1"
}

# домашний каталог человека, запустившего sudo
real_user()
{
	if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
		printf '%s' "$SUDO_USER"
	elif [ -n "${DOAS_USER:-}" ]; then
		printf '%s' "$DOAS_USER"
	elif [ -n "${PKEXEC_UID:-}" ]; then
		id -nu "$PKEXEC_UID" 2>/dev/null
	fi
}
real_home()
{
	local user
	user="$(real_user)"
	if [ -n "$user" ]; then
		getent passwd "$user" | cut -d: -f6
	else
		printf '%s' "$HOME"
	fi
}

# Путь к программе процесса. Без root ссылка exe чужого процесса не читается (nfqws2 работает под своим
# пользователем), а readlink -f при этом возвращает сам путь в /proc. Командная строка доступна всегда
proc_exe()
{
	local exe
	exe="$(readlink -f "/proc/$1/exe" 2>/dev/null)"
	case "$exe" in
		''|/proc/*) tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | head -n1 ;;
		*) printf '%s' "$exe" ;;
	esac
}

# чужие средства обхода. Их параллельная работа ломает и результаты тестов, и сам обход
foreign_bypass()
{
	local pid exe name
	for pid in $(pgrep -f 'nfqws|tpws|dvtws|ciadpi|byedpi|spoofdpi|dpitunnel|goodbyedpi|zapret2' 2>/dev/null); do
		[ "$pid" = "$$" ] && continue
		exe="$(proc_exe "$pid")"
		[ -n "$exe" ] || continue
		case "$exe" in
			"$NFQWS") continue ;;
		esac
		name="$(basename "$exe")"
		case "$name" in
			nfqws|nfqws2|tpws|tpws2|dvtws|dvtws2|ciadpi|byedpi|spoofdpi|dpitunnel*|goodbyedpi) printf '%s (%s)\n' "$exe" "$pid" ;;
		esac
	done
}
