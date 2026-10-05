#!/bin/sh
set -eu

# Run in the image's SDK directory; mounting the project here would hide the SDK.
source_dir=/my/openwrt
output_dir=/my/output
jobs=${BUILD_JOBS:-2}

if [ ! -x scripts/feeds ]; then
    /bin/bash ./setup.sh
fi
if [ ! -w "$output_dir" ]; then
    echo "The SDK user cannot write to /my/output. Choose a writable BUILD_OUTPUT directory." >&2
    exit 1
fi

package_dir=package/luci-app-vpn-nftset
mkdir -p "$package_dir"
cp "$source_dir/Makefile" "$source_dir/LICENSE" "$package_dir/"
cp -R "$source_dir/files" "$source_dir/tools" "$package_dir/"

# The SDK's older feed updater fetches full history for commit pins. Fetch
# exact release commits ourselves, then use the SDK updater only for indexing.
feeds_config=feeds.conf.default
[ ! -f feeds.conf ] || feeds_config=feeds.conf
sed -i \
    -e 's|https://github.com/openwrt/packages\.git|https://git.openwrt.org/feed/packages.git|' \
    -e 's|https://github.com/openwrt/luci\.git|https://git.openwrt.org/project/luci.git|' \
    "$feeds_config"
sed -i '/^src-.*[[:space:]]base[[:space:]]/c\src-git base https://git.openwrt.org/openwrt/openwrt.git^28cf53e6bd9bb68958aae7958e7950d967f02b46' "$feeds_config"

fetch_feed() {
    feed=$1
    revision=$2
    repository=$3
    # These feed directories belong to this disposable SDK container.
    if [ -d "feeds/$feed/.git" ] && \
        [ "$(git -C "feeds/$feed" rev-parse HEAD)" = "$revision" ] && \
        [ "$(git -C "feeds/$feed" rev-parse --is-shallow-repository)" = true ]; then
        git -C "feeds/$feed" reset --hard "$revision"
        git -C "feeds/$feed" clean -fdx
    else
        rm -rf "feeds/$feed"
        git init --quiet "feeds/$feed"
        git -C "feeds/$feed" remote add origin "$repository"
        git -c http.version=HTTP/1.1 -C "feeds/$feed" fetch --depth=1 origin "$revision"
        git -c advice.detachedHead=false -C "feeds/$feed" checkout --detach FETCH_HEAD
    fi
    if [ "$(git -C "feeds/$feed" rev-parse HEAD)" != "$revision" ]; then
        echo "The $feed feed does not match OpenWrt 23.05.5." >&2
        exit 1
    fi
    ./scripts/feeds update -i "$feed"
}

mkdir -p feeds
fetch_feed base 28cf53e6bd9bb68958aae7958e7950d967f02b46 https://git.openwrt.org/openwrt/openwrt.git
fetch_feed packages b5ed85f6e94aa08de1433272dc007550f4a28201 https://git.openwrt.org/feed/packages.git
fetch_feed luci 63ba3cba5b7bfb803a875d4d8f01248634687fd5 https://git.openwrt.org/project/luci.git
./scripts/feeds install \
    luci-compat lua dnsmasq-full nftables ip-full coreutils-base64 \
    wget-ssl ca-bundle ca-certificates libustream-mbedtls

cat > .config <<'EOF'
# CONFIG_ALL is not set
# CONFIG_ALL_NONSHARED is not set
# CONFIG_ALL_KMODS is not set
# coreutils-base64 requires its parent menu before dependency selection.
CONFIG_PACKAGE_coreutils=m
CONFIG_PACKAGE_luci-app-vpn-nftset=m
EOF
make defconfig
if ! grep -Eq '^CONFIG_PACKAGE_luci-app-vpn-nftset=[ym]$' .config || \
    ! grep -Eq '^CONFIG_PACKAGE_luci-compat=[ym]$' .config; then
    echo "The SDK did not select luci-app-vpn-nftset and its LuCI compatibility dependency." >&2
    exit 1
fi

# The package's translation recipe uses a host tool, never a target executable.
mkdir -p staging_dir/host/bin
cc "$package_dir/tools/po2lmo/src/po2lmo.c" \
    "$package_dir/tools/po2lmo/src/template_lmo.c" \
    -o staging_dir/host/bin/po2lmo
export PATH="$PWD/staging_dir/host/bin:$PATH"
# This package installs files and uses the host po2lmo above. Its declared
# runtime dependencies come from the router's opkg feeds at installation.
make "-j$jobs" package/luci-app-vpn-nftset/compile NO_DEPS=1 V=s

python3 "$source_dir/scripts/validate-ipk.py" bin "$output_dir"
