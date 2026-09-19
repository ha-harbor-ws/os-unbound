# os-unbound

Порт [dns/unbound](https://github.com/opnsense/ports/tree/master/dns/unbound) для **OPNsense 26.7** (FreeBSD 15.1 / amd64) с включённым **DNSTAP**.

Официальный пакет OPNsense собирается с `DNSTAP=off`. Этот пакет — drop-in замена `unbound-1.26.1` с теми же опциями (включая PYTHON для DNSBL) плюс `--enable-dnstap`.

## Установка

Постоянные ссылки на последний релиз:

- страница: https://github.com/ha-harbor-ws/os-unbound/releases/latest
- пакет: https://github.com/ha-harbor-ws/os-unbound/releases/latest/download/unbound-latest.pkg

На OPNsense:

```sh
pkg add -f https://github.com/ha-harbor-ws/os-unbound/releases/latest/download/unbound-latest.pkg
pkg lock unbound
unbound -V | grep -i dnstap
```

`pkg lock` нужен, чтобы обновление прошивки не вернуло стоковый unbound без DNSTAP.

Зависимости DNSTAP (`fstrm`, `protobuf-c`) ставятся из репозитория OPNsense.

## Включение dnstap для dnstap-bgp

1. Скопируйте sample:

```sh
cp /usr/local/etc/unbound.opnsense.d/dnstap.conf.sample \
   /usr/local/etc/unbound.opnsense.d/dnstap.conf
mkdir -p /var/unbound/var/run/dnstap-bgp
chown unbound:unbound /var/unbound/var/run/dnstap-bgp
```

2. В `dnstap-bgp.conf` слушайте сокет **на хосте внутри chroot**:

```
[dnstap]
listen = "/var/unbound/var/run/dnstap-bgp/dnstap.sock"
perm = "0666"
```

3. Не вставляйте блок `dnstap:` в GUI Custom options — он попадёт внутрь `server:` и конфиг сломается.

4. Apply в Services → Unbound.

## Сборка

На FreeBSD 15.1 / amd64:

```sh
sh scripts/build-opnsense-pkg.sh
```

Либо GitHub Actions (`vmactions/freebsd-vm`, FreeBSD 15.1): workflow **unbound-dnstap**.
