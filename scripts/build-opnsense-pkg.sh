#!/bin/sh
# Сборка drop-in пакета unbound для OPNsense 26.7 (FreeBSD 15.1 / amd64)
# с DNSTAP и PYTHON, как у официального пакета + --enable-dnstap.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
DISTVERSION=1.26.0
PKGVERSION=1.26.0_1
OPNSENSE_ABI=26.7
SRC_URL="https://www.nlnetlabs.nl/downloads/unbound/unbound-${DISTVERSION}.tar.gz"
SRC_SHA256="77458a7156e275c0b7b17fabcb357cb12445d95cfcb26fb9bb7d5ecba45e0b63"
NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)

WORK="$ROOT/work"
STAGE="$WORK/stage"
BUILD="$WORK/unbound-${DISTVERSION}"
DIST="$ROOT/dist"
META="$WORK/manifest.json"

rm -rf "$STAGE" "$BUILD"
mkdir -p "$WORK" "$STAGE" "$DIST"

setup_repos() {
	export ASSUME_ALWAYS_YES=yes IGNORE_OSVERSION=yes
	mkdir -p /usr/local/etc/pkg/repos
	cat > /usr/local/etc/pkg/repos/OPNsense.conf <<EOF
OPNsense: {
  url: "https://pkg.opnsense.org/\${ABI}/${OPNSENSE_ABI}/latest",
  mirror_type: "https",
  signature_type: "none",
  enabled: yes
}
EOF
	# swig/flex могут быть только в репозитории FreeBSD
	if [ -f /etc/pkg/FreeBSD.conf ]; then
		cp /etc/pkg/FreeBSD.conf /usr/local/etc/pkg/repos/FreeBSD.conf
	fi
	export IGNORE_OSVERSION=yes
	pkg update -f
}

pkg_from() {
	repo=$1
	shift
	pkg install -y -r "$repo" "$@"
}

install_deps() {
	pkg_from OPNsense \
		openssl35 python313 libevent libsodium expat libnghttp2 \
		fstrm protobuf-c pkgconf gmake autoconf automake libtool \
		bison git ca_root_nss
	pkg install -y -U -r FreeBSD swig flex || pkg install -y swig flex
	command -v python3.13 >/dev/null && ln -sf /usr/local/bin/python3.13 /usr/local/bin/python3 || true
}

fetch_source() {
	tarball="$WORK/unbound-${DISTVERSION}.tar.gz"
	if [ ! -f "$tarball" ]; then
		fetch -o "$tarball" "$SRC_URL"
	fi
	actual=$(sha256 -q "$tarball")
	if [ "$actual" != "$SRC_SHA256" ]; then
		echo "SHA256 mismatch: $actual" >&2
		exit 1
	fi
	tar -C "$WORK" -xf "$tarball"
}

configure_and_build() {
	cd "$BUILD"
	rm -f util/configlexer.c
	export PKG_CONFIG_PATH=/usr/local/libdata/pkgconfig:/usr/local/lib/pkgconfig
	export PYTHON_VERSION=3.13
	swig_bin=$(command -v swig || true)
	python_bin=/usr/local/bin/python3.13
	if [ ! -x "$python_bin" ]; then
		python_bin=/usr/local/bin/python3
	fi
	./configure \
		--prefix=/usr/local \
		--localstatedir=/var \
		--mandir=/usr/local/share/man \
		--infodir=/usr/local/share/info \
		--with-libexpat=/usr/local \
		--with-libnghttp2 \
		--with-ssl=/usr/local \
		--enable-dnscrypt \
		--enable-dnstap \
		--with-dynlibmodule \
		--enable-ecdsa \
		--enable-event-api \
		--enable-gost \
		--with-libevent \
		--with-pythonmodule=yes \
		--with-pyunbound=yes \
		${swig_bin:+ac_cv_path_SWIG="$swig_bin"} \
		PYTHON="$python_bin" \
		LDFLAGS="-L/usr/local/lib" \
		--disable-subnet \
		--disable-tfo-client \
		--disable-tfo-server \
		--with-pthreads
	gmake -j"$NCPU"
	gmake install DESTDIR="$STAGE"
}

install_extra() {
	# rc.d из порта
	rcdir="$STAGE/usr/local/etc/rc.d"
	mkdir -p "$rcdir"
	sed -e 's|%%PREFIX%%|/usr/local|g' "$ROOT/files/unbound.in" > "$rcdir/unbound"
	chmod 755 "$rcdir/unbound"

	# sample dnstap drop-in
	mkdir -p "$STAGE/usr/local/etc/unbound.opnsense.d"
	cp "$ROOT/files/dnstap.conf.sample" \
		"$STAGE/usr/local/etc/unbound.opnsense.d/dnstap.conf.sample"

	# как в порте: sample, не рабочий unbound.conf
	if [ -f "$STAGE/usr/local/etc/unbound/unbound.conf" ]; then
		mv "$STAGE/usr/local/etc/unbound/unbound.conf" \
			"$STAGE/usr/local/etc/unbound/unbound.conf.sample"
	fi

	# FreeBSD pkgconfig живёт в libdata
	if [ -f "$STAGE/usr/local/lib/pkgconfig/libunbound.pc" ]; then
		mkdir -p "$STAGE/usr/local/libdata/pkgconfig"
		mv "$STAGE/usr/local/lib/pkgconfig/libunbound.pc" \
			"$STAGE/usr/local/libdata/pkgconfig/libunbound.pc"
		rmdir "$STAGE/usr/local/lib/pkgconfig" 2>/dev/null || true
	fi

	# libtool leftovers не входят в официальный пакет
	find "$STAGE" -name '*.la' -delete

	# gzip man pages как в официальном pkg
	find "$STAGE/usr/local/share/man" -type f ! -name '*.gz' -exec gzip -f {} +

	# лицензии в стиле порта
	licdir="$STAGE/usr/local/share/licenses/unbound-${PKGVERSION}"
	mkdir -p "$licdir"
	printf '%s\n' 'LICENSE: BSD3CLAUSE' > "$licdir/catalog.mk"
	printf '%s\n' 'BSD3CLAUSE' > "$licdir/BSD3CLAUSE"
	cp "$BUILD/LICENSE" "$licdir/LICENSE"

	# strip
	for bin in \
		"$STAGE/usr/local/sbin/unbound" \
		"$STAGE/usr/local/sbin/unbound-anchor" \
		"$STAGE/usr/local/sbin/unbound-checkconf" \
		"$STAGE/usr/local/sbin/unbound-control" \
		"$STAGE/usr/local/sbin/unbound-host"
	do
		if [ -f "$bin" ] && [ ! -L "$bin" ]; then
			strip "$bin" 2>/dev/null || true
		fi
	done
	find "$STAGE" \( -name 'libunbound.so.8.1.39' -o -name '_unbound.so' \) \
		-type f -exec strip {} + 2>/dev/null || true

	mkdir -p "$STAGE/usr/local/etc/unbound"
}

pkg_query_dep() {
	name=$1
	origin=$(pkg query '%o' "$name")
	version=$(pkg query '%v' "$name")
	printf '{"origin":"%s","version":"%s"}' "$origin" "$version"
}

ldd_shlibs() {
	bin=$1
	ldd -a "$bin" 2>/dev/null | awk '
		$0 ~ /=>/ {
			n=$1
			gsub(/:.*/, "", n)
			if (n ~ /^lib/ && n !~ /libunbound/) print n
		}
	' | sort -u
}

write_manifest() {
	unbound_bin="$STAGE/usr/local/sbin/unbound"
	shlibs=$(ldd_shlibs "$unbound_bin" | awk '{printf "\"%s\",", $0}' | sed 's/,$//')
	python_shlib=$("$STAGE/usr/local/sbin/unbound-host" >/dev/null 2>&1 || true)

	desc=$(sed 's/"/\\"/g' "$ROOT/pkg-descr")
	desc=${desc}
	python3 - "$META" <<PY
import json, subprocess, pathlib, os, sys

meta_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(r"$ROOT")
stage = pathlib.Path(r"$STAGE")
bin_path = stage / "usr/local/sbin/unbound"

def pkg_dep(name):
    origin = subprocess.check_output(["pkg", "query", "%o", name], text=True).strip()
    version = subprocess.check_output(["pkg", "query", "%v", name], text=True).strip()
    return {"origin": origin, "version": version}

def shlibs(path):
    out = subprocess.check_output(["ldd", str(path)], text=True, stderr=subprocess.DEVNULL)
    names = []
    for line in out.splitlines():
        line = line.strip()
        if "=>" not in line:
            continue
        name = line.split("=>", 1)[0].strip().split(":", 1)[0]
        if name.startswith("lib") and "libunbound" not in name:
            names.append(name)
    return sorted(set(names))

deps = {
    "libnghttp2": pkg_dep("libnghttp2"),
    "expat": pkg_dep("expat"),
    "openssl35": pkg_dep("openssl35"),
    "libsodium": pkg_dep("libsodium"),
    "python313": pkg_dep("python313"),
    "libevent": pkg_dep("libevent"),
    "fstrm": pkg_dep("fstrm"),
    "protobuf-c": pkg_dep("protobuf-c"),
}

descr = (root / "pkg-descr").read_text(encoding="utf-8")
scripts = {
    "pre-install": """if [ -n "\${PKG_ROOTDIR}" ] && [ "\${PKG_ROOTDIR}" != "/" ]; then
  PW="/usr/sbin/pw -R \${PKG_ROOTDIR}"
else
  PW=/usr/sbin/pw
fi
echo "===> Creating groups"
if ! \${PW} groupshow unbound >/dev/null 2>&1; then
  echo "Creating group 'unbound' with gid '59'"
  \${PW} groupadd unbound -g 59 || exit \$?
else
  echo "Using existing group 'unbound'"
fi
echo "===> Creating users"
if ! \${PW} usershow unbound >/dev/null 2>&1; then
  echo "Creating user 'unbound' with uid '59'"
  \${PW} useradd unbound -u 59 -g 59  -c "Unbound DNS Resolver" -d /nonexistent -s /usr/sbin/nologin || exit \$?
else
  echo "Using existing user 'unbound'"
fi""",
    "post-install": """if ! /usr/sbin/service ldconfig restart >/dev/null; then
		if [ -z "\${INSTALL_AS_USER}" ]; then
			exit 1
		fi
	fi""",
    "post-deinstall": """if [ -n "\${PKG_ROOTDIR}" ] && [ "\${PKG_ROOTDIR}" != "/" ]; then
  PW="/usr/sbin/pw -R \${PKG_ROOTDIR}"
else
  PW=/usr/sbin/pw
fi
	if ! /usr/sbin/service ldconfig restart >/dev/null; then
		if [ -z "\${INSTALL_AS_USER}" ]; then
			exit 1
		fi
	fi""",
}

manifest = {
    "name": "unbound",
    "origin": "dns/unbound",
    "version": "$PKGVERSION",
    "comment": "Validating, recursive, and caching DNS resolver (DNSTAP)",
    "maintainer": "jaap@NLnetLabs.nl",
    "www": "https://github.com/ha-harbor-ws/os-unbound",
    "abi": "FreeBSD:15:amd64",
    "arch": "freebsd:15:x86:64",
    "prefix": "/usr/local",
    "licenselogic": "single",
    "licenses": ["BSD3CLAUSE"],
    "desc": descr,
    "deps": deps,
    "categories": ["dns"],
    "users": ["unbound"],
    "groups": ["unbound"],
    "shlibs_required": shlibs(bin_path),
    "shlibs_provided": ["libunbound.so.8"],
    "options": {
        "DEP-RSA1024": "off",
        "DNSCRYPT": "on",
        "DNSTAP": "on",
        "DOCS": "off",
        "DYNLIB": "on",
        "ECDSA": "on",
        "EVAPI": "on",
        "FILTER_AAAA": "off",
        "GOST": "on",
        "HIREDIS": "off",
        "LIBEVENT": "on",
        "MUNIN_PLUGIN": "off",
        "PYTHON": "on",
        "SUBNET": "off",
        "TFOCL": "off",
        "TFOSE": "off",
        "THREADS": "on",
    },
    "annotations": {
        "FreeBSD_version": "1501000",
        "cpe": "cpe:2.3:a:nlnetlabs:unbound:1.26.0:::::freebsd15:x64",
        "product_abi": "$OPNSENSE_ABI",
        "product_arch": "amd64",
        "product_id": "unbound",
        "product_name": "unbound-dnstap",
        "product_version": "$PKGVERSION",
        "product_website": "https://github.com/ha-harbor-ws/os-unbound",
    },
    "scripts": scripts,
}
meta_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print("==> manifest", meta_path)
PY
}

verify_dnstap() {
	bin="$STAGE/usr/local/sbin/unbound"
	"$bin" -V || true
	if ! "$bin" -V 2>&1 | grep -qi dnstap; then
		echo "error: unbound was built without dnstap" >&2
		exit 1
	fi
	ldd "$bin"
	if ! ldd "$bin" | grep -q 'libssl.so.17'; then
		echo "error: unbound must link OPNsense openssl35 (libssl.so.17)" >&2
		exit 1
	fi
	if ! ldd "$bin" | grep -q 'libfstrm'; then
		echo "error: unbound must link libfstrm" >&2
		exit 1
	fi
	if ! ldd "$bin" | grep -q 'libprotobuf-c'; then
		echo "error: unbound must link libprotobuf-c" >&2
		exit 1
	fi
}

pack() {
	out="$DIST/unbound-${PKGVERSION}-opnsense${OPNSENSE_ABI}-freebsd15-amd64.pkg"
	python3 "$ROOT/scripts/pack-pkg.py" \
		--stage "$STAGE" \
		--manifest "$META" \
		--output "$out"
	# проверим, что бинарь собран с dnstap
	"$STAGE/usr/local/sbin/unbound" -V
}

setup_repos
install_deps
fetch_source
configure_and_build
install_extra
write_manifest
verify_dnstap
pack
echo "==> done"
