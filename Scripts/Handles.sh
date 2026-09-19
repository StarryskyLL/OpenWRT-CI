#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

PKG_PATH="$GITHUB_WORKSPACE/wrt/package"

#预置HomeProxy数据，隔离临时变量和清理信号，避免影响后续修复
hp_preset_resources() (
	local HP_DIR="$1"
	RESOURCES_DIR="$HP_DIR/root/etc/homeproxy/resources"
	DASHBOARD_DIR="$HP_DIR/root/etc/homeproxy/dashboard"

	GEOIP_SOURCE="${GEOIP_SOURCE:-https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs}"
	GEOIP_VERSION_URL="${GEOIP_VERSION_URL:-https://github.com/SagerNet/sing-geoip/releases/latest}"
	GEOSITE_SOURCE="${GEOSITE_SOURCE:-https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set-unstable/geosite-cn.srs}"
	GEOSITE_VERSION_URL="${GEOSITE_VERSION_URL:-https://github.com/SagerNet/sing-geosite/releases/latest}"
	DASHBOARD_SOURCE="${DASHBOARD_SOURCE:-https://codeload.github.com/SagerNet/sing-box-dashboard/zip/refs/heads/gh-pages}"
	DASHBOARD_VERSION_URL="${DASHBOARD_VERSION_URL:-https://github.com/SagerNet/sing-box-dashboard/commits/gh-pages.atom}"
	USER_AGENT="${USER_AGENT:-HomeProxy resource preset}"

	TMP_DIR="$(mktemp -d)" || {
		echo "Failed to prepare temporary resource directory." >&2
		return 1
	}
	DASHBOARD_STAGE="${DASHBOARD_DIR}.new.$$"
	trap 'rm -rf -- "$TMP_DIR" "$DASHBOARD_STAGE" "$RESOURCES_DIR/.update.$$.tmp"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	warn() {
		echo "WARNING: $*" >&2
	}

	fetch_release_version() {
		local effective_url version
		effective_url="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 --connect-timeout 10 --max-time 30 \
			-A "$USER_AGENT" -o /dev/null -w '%{url_effective}' "$1")" || return 1
		version="${effective_url##*/}"
		case "$version" in
			''|*[!0-9]*) return 1 ;;
		esac
		printf '%s\n' "$version"
	}

	fetch_dashboard_version() {
		local feed version
		feed="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 --connect-timeout 10 --max-time 30 \
			-A "$USER_AGENT" "$DASHBOARD_VERSION_URL")" || return 1
		version="$(printf '%s\n' "$feed" | awk -F '[<>]' '
			/<updated>/ {
				version = $3
				gsub(/[-:TZ]/, "", version)
				print version
				exit
			}
		')"
		case "$version" in
			??????????????) case "$version" in *[!0-9]*) return 1 ;; esac ;;
			*) return 1 ;;
		esac
		printf '%s\n' "$version"
	}

	download() {
		curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
			--connect-timeout 10 --max-time 60 -A "$USER_AGENT" -o "$2" "$1" &&
			test -s "$2"
	}

	validate_rule_set() {
		# Download checks cover transfer errors; only check the SRS envelope here.
		[[ "$(head -c 3 "$1" 2>/dev/null)" == SRS && $(wc -c < "$1") -gt 4 ]]
	}

	versioned_url() {
		case "$1" in
		http://*|https://*) printf '%s?v=%s' "$1" "$2" ;;
		*) printf '%s' "$1" ;;
		esac
	}

	install_rule_set() {
		local source_file="$1" version="$2" resource="$3"
		local stage_dir="$RESOURCES_DIR/.update.$$.tmp"

		mkdir -p "$stage_dir" &&
			cp "$source_file" "$stage_dir/$resource.srs" &&
			printf '%s\n' "$version" > "$stage_dir/$resource.ver" &&
			chmod 0644 "$stage_dir/$resource.srs" "$stage_dir/$resource.ver" &&
			mv -f "$stage_dir/$resource.srs" "$RESOURCES_DIR/$resource.srs" &&
			mv -f "$stage_dir/$resource.ver" "$RESOURCES_DIR/$resource.ver"
	}

	update_rule_set() {
		local resource="$1" source_url="$2" version_url="$3"
		local version old_version

		version="$(fetch_release_version "$version_url")" || return 1
		old_version="$(cat "$RESOURCES_DIR/$resource.ver" 2>/dev/null)"
		if [ "$old_version" = "$version" ] && validate_rule_set "$RESOURCES_DIR/$resource.srs"; then
			echo "HomeProxy resources: $resource $version (current)"
			return 0
		fi
		download "$(versioned_url "$source_url" "$version")" "$TMP_DIR/$resource.srs" &&
			validate_rule_set "$TMP_DIR/$resource.srs" &&
			install_rule_set "$TMP_DIR/$resource.srs" "$version" "$resource" || return 1
		echo "HomeProxy resources: $resource $version"
	}

	update_dashboard() {
		local version old_version index source_dir=""
		local backup_dir="${DASHBOARD_DIR}.old.$$"

		version="$(fetch_dashboard_version)" || return 1
		old_version="$(cat "$DASHBOARD_DIR/dashboard.ver" 2>/dev/null)"
		if [ "$old_version" = "$version" ] && [ -s "$DASHBOARD_DIR/index.html" ]; then
			echo "HomeProxy dashboard: $version (current)"
			return 0
		fi
		download "$(versioned_url "$DASHBOARD_SOURCE" "$version")" "$TMP_DIR/dashboard.zip" &&
			unzip -q "$TMP_DIR/dashboard.zip" -d "$TMP_DIR/dashboard" || return 1
		for index in "$TMP_DIR/dashboard/index.html" "$TMP_DIR"/dashboard/*/index.html; do
			if [ -s "$index" ]; then
				source_dir="${index%/index.html}"
				break
			fi
		done
		[ -n "$source_dir" ] || return 1
		mkdir -p "$DASHBOARD_STAGE" &&
			cp -a "$source_dir/." "$DASHBOARD_STAGE/" &&
			rm -f "$DASHBOARD_STAGE/.etag" &&
			printf '%s\n' "$version" > "$DASHBOARD_STAGE/dashboard.ver" &&
			chmod -R a+rX "$DASHBOARD_STAGE" || return 1
		mv "$DASHBOARD_DIR" "$backup_dir" || return 1
		if ! mv "$DASHBOARD_STAGE" "$DASHBOARD_DIR"; then
			mv "$backup_dir" "$DASHBOARD_DIR" || warn "Unable to restore the dashboard; backup retained at $backup_dir."
			return 1
		fi
		rm -rf "$backup_dir"
		echo "HomeProxy dashboard: $version"
	}

	mkdir -p "$RESOURCES_DIR" "$DASHBOARD_DIR" || return 1
	update_failed=0
	if ! update_rule_set geoip_cn "$GEOIP_SOURCE" "$GEOIP_VERSION_URL"; then
		warn "Failed to update HomeProxy geoip resource; continuing."
		update_failed=1
	fi
	if ! update_rule_set geosite_cn "$GEOSITE_SOURCE" "$GEOSITE_VERSION_URL"; then
		warn "Failed to update HomeProxy geosite; continuing."
		update_failed=1
	fi
	if ! update_dashboard; then
		warn "Failed to update HomeProxy dashboard; continuing."
		update_failed=1
	fi

	return "$update_failed"
)

HP_DIR="$(find "$PKG_PATH" -maxdepth 3 -type d -iname '*homeproxy*' -print -quit 2>/dev/null)"
if [ -n "$HP_DIR" ]; then
	echo " "
	if hp_preset_resources "$HP_DIR"; then
		echo "homeproxy data has been updated!"
	else
		echo "homeproxy resource preset completed with errors; continuing!"
	fi
fi

#修改argon主题字体和颜色
if [ -d "$PKG_PATH/luci-theme-argon" ]; then
	echo " "
	if sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" \
		"$PKG_PATH/luci-theme-argon/luci-app-argon-config/root/etc/config/argon"; then
		echo "theme-argon has been fixed!"
	else
		echo "theme-argon fix failed; continuing!"
	fi
fi

#修改aurora菜单式样
if [ -d "$PKG_PATH/luci-app-aurora-config" ]; then
	echo " "
	if find "$PKG_PATH/luci-app-aurora-config/root/usr/share/aurora/" -type f -name '*.template' -exec \
		sed -i "s/nav_type '.*'/nav_type 'dropdown'/g; s/struct_radius_base '.*'/struct_radius_base '0.125rem'/g" {} +; then
		echo "theme-aurora has been fixed!"
	else
		echo "theme-aurora fix failed; continuing!"
	fi
fi

#修改mini-diskmanager菜单位置
if [ -d "$PKG_PATH/luci-app-mini-diskmanager" ]; then
	echo " "
	if sed -i "s/services/system/g" \
		"$PKG_PATH/luci-app-mini-diskmanager/luci-app-mini-diskmanager/root/usr/share/luci/menu.d/luci-app-mini-diskmanager.json"; then
		echo "mini-diskmanager has been fixed!"
	else
		echo "mini-diskmanager fix failed; continuing!"
	fi
fi

#修复QModem普通QMI驱动的NSS误判，以及翻译包强制选中新版界面
#Packages.sh将FUjr/QModem克隆为package/QModem；支持上游已合入与重复执行。
qmodem_apply_fixes() (
	local qmodem_dir="$1" patch_dir patch_file
	patch_dir="$(mktemp -d)" || return 1
	trap 'rm -rf -- "$patch_dir"' EXIT

	cat > "$patch_dir/driver.patch" <<'QMODEM_DRIVER_PATCH'
diff --git a/driver/quectel_QMI_WWAN/Makefile b/driver/quectel_QMI_WWAN/Makefile
index 723e7c6..20425ef 100644
--- a/driver/quectel_QMI_WWAN/Makefile
+++ b/driver/quectel_QMI_WWAN/Makefile
@@ -12 +12 @@ PKG_VERSION:=1.5
-PKG_RELEASE:=1
+PKG_RELEASE:=2
diff --git a/driver/quectel_QMI_WWAN/src/qmi_wwan_q.c b/driver/quectel_QMI_WWAN/src/qmi_wwan_q.c
index 859dea8..b156134 100644
--- a/driver/quectel_QMI_WWAN/src/qmi_wwan_q.c
+++ b/driver/quectel_QMI_WWAN/src/qmi_wwan_q.c
@@ -60,5 +59,0 @@
-#ifdef CONFIG_PINCTRL_IPQ807x
-#define CONFIG_QCA_NSS_DRV
-//#define CONFIG_QCA_NSS_PACKET_FILTER
-#endif
-
@@ -73,7 +68,2 @@ static struct rmnet_nss_cb __read_mostly *nss_cb = NULL;
-#if defined(CONFIG_PINCTRL_IPQ807x) || defined(CONFIG_PINCTRL_IPQ5018) || defined(CONFIG_PINCTRL_IPQ8074)
-//#ifdef CONFIG_RMNET_DATA //spf12.x none, not effect for spf11.x
-#define CONFIG_QCA_NSS_DRV
-/* define at qsdk/qca/src/linux-4.4/net/rmnet_data/rmnet_data_main.c */ //for spf11.x
-/* define at qsdk/qca/src/datarmnet/core/rmnet_config.c */ //for spf12.x
-/* set at qsdk/qca/src/data-kernel/drivers/rmnet-nss/rmnet_nss.c */
-/* need add DEPENDS:= kmod-rmnet-core in feeds/makefile */
+#ifdef CONFIG_QCA_NSS_DRV
+/* NSS builds must explicitly enable this and provide the callback symbol. */
@@ -81 +70,0 @@ extern struct rmnet_nss_cb *rmnet_nss_callbacks __rcu __read_mostly;
-//#endif
QMODEM_DRIVER_PATCH

	cat > "$patch_dir/luci.patch" <<'QMODEM_LUCI_PATCH'
diff --git a/luci/luci-app-qmodem-next/Makefile b/luci/luci-app-qmodem-next/Makefile
index 90a6347..d5479b1 100644
--- a/luci/luci-app-qmodem-next/Makefile
+++ b/luci/luci-app-qmodem-next/Makefile
@@ -11 +11 @@ PKGARCH:=all
-PKG_RELEASE:=3
+PKG_RELEASE:=4
@@ -25 +25 @@ define Package/$(PKG_NAME)
-  DEPENDS:=@!PACKAGE_luci-app-qmodem $(PKG_DEPENDS) +luci-base
+  DEPENDS:=$(PKG_DEPENDS) +luci-base
@@ -53 +53 @@ define Package/luci-i18n-qmodem-next-zh-cn
-	DEPENDS:=+luci-app-qmodem-next
+	DEPENDS:=luci-app-qmodem-next
diff --git a/luci/luci-app-qmodem/Makefile b/luci/luci-app-qmodem/Makefile
index c6b1001..01edf02 100644
--- a/luci/luci-app-qmodem/Makefile
+++ b/luci/luci-app-qmodem/Makefile
@@ -18,2 +18 @@ PKG_PROVIDES:=qmodem-luci-ui
-LUCI_DEPENDS:=@!PACKAGE_luci-app-qmodem-next \
-		+luci-compat \
+LUCI_DEPENDS:=+luci-compat \
QMODEM_LUCI_PATCH

	#先检查全部补丁，避免源码变化时只应用一部分修复。
	for patch_file in "$patch_dir"/*.patch; do
		if git -C "$qmodem_dir" apply --unidiff-zero --reverse --check "$patch_file" >/dev/null 2>&1; then
			continue
		fi
		git -C "$qmodem_dir" apply --unidiff-zero --check "$patch_file" || return 1
	done
	for patch_file in "$patch_dir"/*.patch; do
		if git -C "$qmodem_dir" apply --unidiff-zero --reverse --check "$patch_file" >/dev/null 2>&1; then
			continue
		fi
		git -C "$qmodem_dir" apply --unidiff-zero "$patch_file" || return 1
	done
)

if [ -d "$PKG_PATH/QModem" ]; then
	if qmodem_apply_fixes "$PKG_PATH/QModem"; then
		echo "QModem driver and LuCI selection has been fixed!"
	else
		echo "QModem driver and LuCI selection fix failed; continuing!"
	fi
fi

#修复TailScale配置文件冲突
FEEDS_PACKAGES="$PKG_PATH/../feeds/packages"
TS_FILE="$(find "$FEEDS_PACKAGES" -maxdepth 3 -type f -wholename '*/tailscale/Makefile' -print -quit 2>/dev/null)"
if [ -f "$TS_FILE" ]; then
	echo " "

	if sed -i '/\/files/d' "$TS_FILE"; then
		echo "tailscale has been fixed!"
	else
		echo "tailscale fix failed; continuing!"
	fi
fi

#修复Rust编译失败
RUST_FILE="$(find "$FEEDS_PACKAGES" -maxdepth 3 -type f -wholename '*/rust/Makefile' -print -quit 2>/dev/null)"
if [ -f "$RUST_FILE" ]; then
	echo " "

	if sed -i 's/ci-llvm=true/ci-llvm=false/g' "$RUST_FILE"; then
		echo "rust has been fixed!"
	else
		echo "rust fix failed; continuing!"
	fi
fi
