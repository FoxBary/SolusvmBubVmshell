# SolusvmBubVmshell

SolusVM node emergency recovery helper for the `svmstack-nginx` / port `6767` failure caused by a malicious dynamic library preload chain.

This repository documents and automates the recovery steps used when SolusVM node servers were hit by a rootkit-style userland hook that prevented `svmstack-nginx` from starting.

## Symptom

Typical symptoms:

- SolusVM master cannot connect to the node on port `6767`.
- `svmstack-nginx` is failed or was killed.
- `nginx -t` reports a forced module under `/var/adm/<uuid>/nginx/module.so`.
- `/etc/ld.so.preload` exists and points to a suspicious shared library, often `libutilkeybd.so`.
- `/etc/udev/rules.d/99-<uuid>.rules` recreates persistence through `/var/adm/<uuid>/udev/udev.sh`.

Example nginx error:

```text
nginx: [emerg] module "/var/adm/<uuid>/nginx/module.so" is not binary compatible in command line
nginx: configuration file /usr/local/svmstack/nginx/conf/nginx.conf test failed
```

## What Is Happening

The attack chain observed here is:

1. `/etc/ld.so.preload` forces new dynamically linked processes to load a malicious library.
2. The malicious library, observed as `libutilkeybd.so`, hooks normal file and process behavior.
3. When `svmstack-nginx` starts, the hook forces nginx to load `/var/adm/<uuid>/nginx/module.so`.
4. That module is not compatible with the SolusVM nginx binary, so `nginx -t` fails.
5. `svmstack-nginx` cannot start, so port `6767` is not listening.
6. A udev rule under `/etc/udev/rules.d/99-<uuid>.rules` can relaunch the malware when network devices are added.

The UUID changes on each infected host. Do not hard-code a UUID from another server.

## Quick Use

On the affected SolusVM node:

```bash
curl -fsSL https://raw.githubusercontent.com/FoxBary/SolusvmBubVmshell/main/scripts/solusvm_svmstack_nginx_recover.sh -o /root/solusvm_svmstack_nginx_recover.sh
bash /root/solusvm_svmstack_nginx_recover.sh
```

For non-interactive emergency repair:

```bash
bash /root/solusvm_svmstack_nginx_recover.sh --yes
```

Optional hardening of `/etc/ld.so.preload` after cleanup:

```bash
bash /root/solusvm_svmstack_nginx_recover.sh --yes --immutable-preload
```

Use dry-run mode to inspect only:

```bash
bash /root/solusvm_svmstack_nginx_recover.sh --dry-run
```

## Manual Recovery Steps

Run these on the infected node as root.

### 1. Check service and port

```bash
systemctl status svmstack-nginx --no-pager -l
/usr/local/svmstack/nginx/bin/nginx -t -c /usr/local/svmstack/nginx/conf/nginx.conf
ss -lntp | grep ':6767'
```

### 2. Identify current malicious UUID

Look for paths like:

```text
/var/adm/<uuid>/nginx/module.so
/var/adm/<uuid>/kernel/libutilkeybd.so
/etc/udev/rules.d/99-<uuid>.rules
```

Useful commands:

```bash
grep -R --line-number -E '/var/adm|RING04H|libutilkeybd|module\.so' /etc/udev/rules.d /root 2>/dev/null
find /var/adm -maxdepth 4 -print 2>/dev/null
```

### 3. Clear `/etc/ld.so.preload`

Normal tools may be hooked, so direct syscall cleanup is safer:

```bash
perl -e '
  my $p = "/etc/ld.so.preload\0";
  my $r = syscall(87, $p); print "unlink ret=$r errno=$!\n";
  my $fd = syscall(2, $p, 0101|01000|01, 0644); print "open/create ret=$fd errno=$!\n";
  syscall(3, $fd) if $fd >= 0;
'
chmod 0644 /etc/ld.so.preload
chown root:root /etc/ld.so.preload
```

### 4. Quarantine malicious files

Replace `<uuid>` with the UUID found on that host.

```bash
TS=$(date +%Y%m%d-%H%M%S)
Q=/root/solusvm-rootkit-quarantine-$TS
mkdir -p "$Q"

mv /etc/udev/rules.d/99-<uuid>.rules "$Q/" 2>/dev/null || true
mv /var/adm/<uuid> "$Q/" 2>/dev/null || true

udevadm control --reload-rules
systemctl daemon-reload
```

### 5. Restart and verify

```bash
/usr/local/svmstack/nginx/bin/nginx -t -c /usr/local/svmstack/nginx/conf/nginx.conf
systemctl restart svmstack-nginx
systemctl status svmstack-nginx --no-pager -l
ss -lntp | grep ':6767'
```

Expected:

```text
nginx: configuration file ... test is successful
svmstack-nginx.service active (running)
*:6767 LISTEN
```

## Persistence Prevention

After recovery, rotate credentials and restrict access. Local cleanup alone is not enough if the attacker still has root.

Recommended actions:

```bash
passwd root
cat /root/.ssh/authorized_keys
last -a | head -50
grep "Accepted" /var/log/secure | tail -100
```

If SSH key access is ready, consider disabling password login:

```text
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
```

Then:

```bash
systemctl restart sshd
```

Optional immutable preload protection:

```bash
: > /etc/ld.so.preload
chmod 0644 /etc/ld.so.preload
chown root:root /etc/ld.so.preload
chattr +i /etc/ld.so.preload
```

To edit it later:

```bash
chattr -i /etc/ld.so.preload
```

## Important Limitations

This script restores `svmstack-nginx` and removes the observed persistence chain. It does not prove that the host is fully trustworthy.

If a node was compromised as root:

- Existing long-running processes may still have the old malicious library mapped until restart.
- You should schedule a maintenance reboot.
- You should rotate root passwords and SSH keys.
- You should investigate how the attacker gained access.
- The strongest long-term remediation is reinstalling the node from clean media and restoring SolusVM workloads safely.

## Files Produced by the Script

The script writes:

```text
/root/solusvm-rootkit-recovery-<timestamp>.log
/root/solusvm-rootkit-quarantine-<timestamp>/
```

Quarantine files are intentionally not deleted immediately.

## License

MIT
