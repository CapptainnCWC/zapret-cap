# Обновление самого приложения из релизов GitHub

GITHUB_CAP_REPO="CapptainnCWC/zapret-cap"

# Сведения о последнем релизе: строки ключ=значение. Проверка идёт без прав администратора
upgrade_info()
{
	local json
	json="$(curl -fsSL -m 20 -H 'Accept: application/vnd.github+json' \
		"https://api.github.com/repos/$GITHUB_CAP_REPO/releases/latest" 2>/dev/null)" || return 1
	# разбор JSON без сторонних утилит: Python уже нужен окну приложения
	printf '%s' "$json" | python3 -I -c '
import json, sys
release = json.load(sys.stdin)
tag = release.get("tag_name", "")
print("tag=" + tag)
print("latest=" + tag.lstrip("v"))
print("page=" + release.get("html_url", ""))
print("source=" + release.get("tarball_url", ""))
for asset in release.get("assets", []):
    if asset.get("name", "").endswith("_all.deb"):
        print("deb=" + asset.get("browser_download_url", ""))
        break
' 2>/dev/null
}

upgrade_from_package()
{
	command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' zapret-cap 2>/dev/null | grep -q 'install ok installed'
}

# версия a новее b
version_newer()
{
	[ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

upgrade_check()
{
	local info latest current method
	current="$(cap_version)"
	if ! info="$(upgrade_info)" || [ -z "$info" ]; then
		echo "Не удалось узнать последнюю версию: нет связи с GitHub."
		return 1
	fi
	latest="$(sed -n 's/^latest=//p' <<< "$info")"
	method=source
	upgrade_from_package && method=deb
	printf 'current=%s\nlatest=%s\nnewer=%s\npage=%s\nmethod=%s\n' "$current" "$latest" \
		"$(version_newer "$latest" "$current" && echo 1 || echo 0)" "$(sed -n 's/^page=//p' <<< "$info")" "$method"
}

# Скачивает последний релиз и ставит его тем же способом, каким приложение было установлено.
# Настройки и добавленные сайты сохраняются: это обеспечивают сами пакет и install.sh
upgrade_run()
{
	local info latest current tmp url code=0
	current="$(cap_version)"
	echo "Проверяю последнюю версию..."
	if ! info="$(upgrade_info)" || [ -z "$info" ]; then
		err "Не удалось узнать последнюю версию: нет связи с GitHub."
		return 1
	fi
	latest="$(sed -n 's/^latest=//p' <<< "$info")"
	if ! version_newer "$latest" "$current"; then
		ok "Установлена последняя версия $current."
		return 0
	fi
	echo "Обновляю $current -> $latest."
	tmp="$(mktemp -d)"
	chmod 755 "$tmp"
	if upgrade_from_package; then
		url="$(sed -n 's/^deb=//p' <<< "$info")"
		if [ -z "$url" ]; then
			err "В релизе $latest нет пакета .deb."
			rm -rf -- "${tmp:?}"
			return 1
		fi
		echo "Скачиваю пакет..."
		if ! curl -fL -m 300 -o "$tmp/zapret-cap.deb" "$url"; then
			err "Не удалось скачать пакет."
			rm -rf -- "${tmp:?}"
			return 1
		fi
		chmod 644 "$tmp/zapret-cap.deb"
		echo "Устанавливаю пакет..."
		if command -v apt-get >/dev/null 2>&1; then
			DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/zapret-cap.deb" || code=$?
		else
			dpkg -i "$tmp/zapret-cap.deb" || code=$?
		fi
	else
		url="$(sed -n 's/^source=//p' <<< "$info")"
		echo "Скачиваю исходный код..."
		if [ -z "$url" ] || ! curl -fL -m 300 -o "$tmp/source.tar.gz" "$url"; then
			err "Не удалось скачать исходный код."
			rm -rf -- "${tmp:?}"
			return 1
		fi
		mkdir "$tmp/src"
		tar xzf "$tmp/source.tar.gz" -C "$tmp/src" --strip-components=1 || code=$?
		if [ "$code" = 0 ]; then
			echo "Запускаю установку..."
			bash "$tmp/src/install.sh" || code=$?
		fi
	fi
	rm -rf -- "${tmp:?}"
	if [ "$code" != 0 ]; then
		err "Обновление не удалось. Прежняя версия осталась на месте."
		return 1
	fi
	ok "Обновлено до версии $latest."
}
