#!/usr/bin/env bash
# Собирает установочный пакет для Debian, Ubuntu, Linux Mint: dist/zapret-cap_ВЕРСИЯ_all.deb
set -eu
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^ZAPRET_CAP=//p' "$REPO/VERSION")"
APP_ID=org.zapretcap.ZapretCap
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE:?}"' EXIT
ROOT="$STAGE/zapret-cap"
OPT="$ROOT/opt/zapret-cap"

mkdir -p "$OPT" "$ROOT/DEBIAN" "$ROOT/usr/bin"
tar cf - -C "$REPO" --exclude=./.git --exclude=./state --exclude=./dist --exclude=./packaging --exclude='./utils/test results' \
	--exclude='./utils/game_filter.enabled' --exclude='./lists/*-user.txt' --exclude='./lists/ipset-all.test-backup.txt' \
	--exclude='./core/nfq2/nfqws2' --exclude='*.o' --exclude='./core/ip2net/ip2net' --exclude='./core/mdig/mdig' \
	--exclude='./core/binaries/my' --exclude=__pycache__ . | tar xf - -C "$OPT"

install -Dm644 "$REPO/data/$APP_ID.svg" "$ROOT/usr/share/icons/hicolor/scalable/apps/$APP_ID.svg"
install -Dm644 "$REPO/data/$APP_ID.desktop" "$ROOT/usr/share/applications/$APP_ID.desktop"
install -Dm644 "$REPO/data/$APP_ID.policy" "$ROOT/usr/share/polkit-1/actions/$APP_ID.policy"
install -Dm644 "$REPO/data/$APP_ID.metainfo.xml" "$ROOT/usr/share/metainfo/$APP_ID.metainfo.xml"
ln -s /opt/zapret-cap/zapret "$ROOT/usr/bin/zapret"

cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: zapret-cap
Version: $VERSION
Architecture: all
Maintainer: Zapret Cap <zapret-cap@users.noreply.github.com>
Section: net
Priority: optional
Installed-Size: $(du -sk "$ROOT" | cut -f1)
Depends: bash, make, gcc, pkg-config, zlib1g-dev, libcap-dev, libnetfilter-queue-dev, libmnl-dev, libnfnetlink-dev, libluajit-5.1-dev, curl, nftables, iputils-ping, python3, python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1, pkexec | policykit-1
Description: Обход блокировок YouTube, Discord и других сайтов
 Возвращает доступ к сайтам и сервисам, которые замедляет или блокирует
 провайдер. Работает прямо на компьютере: это не VPN, сторонние серверы
 не нужны. Приложение само находит рабочую стратегию, позволяет добавлять
 свои сайты и настраивать обход.
CONTROL
for script in preinst postinst prerm postrm; do
	install -m 755 "$REPO/packaging/deb/$script" "$ROOT/DEBIAN/$script"
done

mkdir -p "$REPO/dist"
dpkg-deb --root-owner-group --build "$ROOT" "$REPO/dist/zapret-cap_${VERSION}_all.deb"
