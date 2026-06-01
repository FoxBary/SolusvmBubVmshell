# SolusvmBubVmshell

SolusVM 节点 `svmstack-nginx` / `6767` 端口失联的一键检测与修复脚本。

本仓库用于处理一种已经在多台 SolusVM Node 上复现的问题：服务器被 Rootkit / 恶意动态库劫持后，SolusVM Node Agent 依赖的 `svmstack-nginx` 无法正常启动，主控因此无法连接节点的 `6767` 端口。

## 一句话修复

在出问题的 SolusVM 节点服务器上用 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/FoxBary/SolusvmBubVmshell/main/scripts/solusvm_svmstack_nginx_recover.sh -o /root/solusvm_svmstack_nginx_recover.sh
bash /root/solusvm_svmstack_nginx_recover.sh
```

如果确认就是这个问题，想直接自动修复：

```bash
bash /root/solusvm_svmstack_nginx_recover.sh --yes
```

如果只想检查，不做任何修改：

```bash
bash /root/solusvm_svmstack_nginx_recover.sh --dry-run
```

## 适用场景

适用于以下情况：

- SolusVM 主控提示节点连接失败。
- 主控连不上节点 `6767` 端口。
- 节点上 `svmstack-nginx` 启动失败。
- `systemctl status svmstack-nginx` 显示 failed、killed 或 start failed。
- `nginx -t` 报 `/var/adm/<uuid>/nginx/module.so` 不兼容。
- `/etc/ld.so.preload` 出现异常内容。
- `/var/adm/<uuid>/kernel/libutilkeybd.so` 或 `/var/adm/<uuid>/nginx/module.so` 存在。
- `/etc/udev/rules.d/99-<uuid>.rules` 里出现 `/var/adm/<uuid>/udev/udev.sh`。

典型错误：

```text
nginx: [emerg] module "/var/adm/<uuid>/nginx/module.so" is not binary compatible in command line
nginx: configuration file /usr/local/svmstack/nginx/conf/nginx.conf test failed
```

其中 `<uuid>` 每台机器可能不同，例如：

```text
f2c351cb-303f-44c3-8068-ad92f3b3994a
9f143a8d-dec9-4717-866b-a08968c72cd9
7b47430f-277d-4677-a84a-020607399527
```

不要把别的服务器上的 UUID 直接复制到当前服务器使用，必须以当前服务器实际检查结果为准。

## 问题原因

这类故障不是普通 nginx 配置错误，而是用户态 Rootkit / 恶意动态库劫持。

完整链路如下：

1. 攻击者写入 `/etc/ld.so.preload`。
2. Linux 动态链接器会让新启动的动态链接程序强制加载 preload 文件里指定的 `.so`。
3. 恶意 `.so` 常见名称是 `libutilkeybd.so`，路径类似 `/var/adm/<uuid>/kernel/libutilkeybd.so`。
4. 这个恶意库 hook 了部分 libc 调用，可能导致 `ls` 能看到文件，但 `cat`、`wc`、`echo > file` 等操作被欺骗成 “No such file”。
5. 当 `svmstack-nginx` 启动时，恶意库劫持 nginx，让它加载 `/var/adm/<uuid>/nginx/module.so`。
6. 这个恶意 nginx 模块和 SolusVM 自带 nginx 二进制不兼容，导致 `nginx -t` 失败。
7. `svmstack-nginx` 无法启动，`6767` 端口不监听。
8. 恶意 udev 规则 `/etc/udev/rules.d/99-<uuid>.rules` 会在网卡事件时重新拉起 `/var/adm/<uuid>/udev/udev.sh`，实现复发。

所以修复时必须同时处理三件事：

- 清掉 `/etc/ld.so.preload` 注入链。
- 隔离 `/var/adm/<uuid>` 恶意目录。
- 删除对应 udev 持久化规则。

只重启 nginx 不够，只删除 `/var/adm/<uuid>` 也不够。

## 脚本做了什么

脚本 `scripts/solusvm_svmstack_nginx_recover.sh` 会按顺序执行：

1. 检查当前主机名、内核、`svmstack-nginx` 状态。
2. 执行 `/usr/local/svmstack/nginx/bin/nginx -t -c /usr/local/svmstack/nginx/conf/nginx.conf`。
3. 检查 `6767` 是否监听。
4. 检查 `/etc/ld.so.preload`。
5. 检查 `/etc/udev/rules.d` 里的可疑规则。
6. 检查 `/var/adm` 下的可疑 UUID 目录。
7. 检查当前进程是否加载 `libutilkeybd.so`。
8. 从 nginx 错误、udev 规则、`/var/adm` 目录中自动提取当前服务器的 UUID。
9. 创建隔离目录 `/root/solusvm-rootkit-quarantine-<timestamp>/`。
10. 备份 nginx 二进制、nginx 配置、systemd unit 等证据。
11. 用直接 syscall 方式删除并重建空的 `/etc/ld.so.preload`。
12. 移走恶意 udev 规则。
13. 移走 `/var/adm/<uuid>` 恶意目录。
14. 重载 udev 规则和 systemd。
15. 重新执行 `nginx -t`。
16. 重启 `svmstack-nginx`。
17. 验证 `6767` 是否恢复监听。
18. 验证新 nginx 进程是否还加载 `/var/adm` 或 `libutilkeybd.so`。

脚本默认是“隔离”，不是直接永久删除。隔离目录示例：

```text
/root/solusvm-rootkit-quarantine-20260601-051419/
```

日志文件示例：

```text
/root/solusvm-rootkit-recovery-20260601-051419.log
```

## 脚本参数说明

交互模式，推荐第一次使用：

```bash
bash /root/solusvm_svmstack_nginx_recover.sh
```

脚本会先诊断，然后询问是否继续清理。

自动确认模式：

```bash
bash /root/solusvm_svmstack_nginx_recover.sh --yes
```

适合已经确认是同类问题时快速恢复。

只检查不修改：

```bash
bash /root/solusvm_svmstack_nginx_recover.sh --dry-run
```

适合巡检或不确定是否感染时使用。

修复后给 `/etc/ld.so.preload` 加不可变保护：

```bash
bash /root/solusvm_svmstack_nginx_recover.sh --yes --immutable-preload
```

这会执行类似：

```bash
chattr +i /etc/ld.so.preload
```

如果以后要维护这个文件，需要先解除：

```bash
chattr -i /etc/ld.so.preload
```

## 完整使用教程

### 第 1 步：登录节点

用 root 登录出问题的 SolusVM 节点：

```bash
ssh root@<node-ip>
```

### 第 2 步：下载脚本

```bash
curl -fsSL https://raw.githubusercontent.com/FoxBary/SolusvmBubVmshell/main/scripts/solusvm_svmstack_nginx_recover.sh -o /root/solusvm_svmstack_nginx_recover.sh
```

如果服务器没有 `curl`，可以用：

```bash
wget -O /root/solusvm_svmstack_nginx_recover.sh https://raw.githubusercontent.com/FoxBary/SolusvmBubVmshell/main/scripts/solusvm_svmstack_nginx_recover.sh
```

### 第 3 步：先做诊断

```bash
bash /root/solusvm_svmstack_nginx_recover.sh --dry-run
```

重点看这些输出：

```text
Nginx config test
Port 6767 listeners
Preload file
Suspicious udev rules
Suspicious /var/adm content
Processes with known injected library markers
```

如果看到 `/var/adm/<uuid>/nginx/module.so` 或 `libutilkeybd.so`，基本就是同类感染。

### 第 4 步：执行修复

交互修复：

```bash
bash /root/solusvm_svmstack_nginx_recover.sh
```

看到提示后输入 `y`。

自动修复：

```bash
bash /root/solusvm_svmstack_nginx_recover.sh --yes
```

### 第 5 步：确认恢复

脚本最后应该看到：

```text
nginx: configuration file ... test is successful
active
*:6767 LISTEN
clean
```

也可以手动确认：

```bash
systemctl status svmstack-nginx --no-pager -l
ss -lntp | grep ':6767'
/usr/local/svmstack/nginx/bin/nginx -t -c /usr/local/svmstack/nginx/conf/nginx.conf
```

从外部机器测试：

```bash
nc -vz <node-ip> 6767
```

成功时类似：

```text
Connection to <node-ip> port 6767 succeeded!
```

## 手工修复教程

如果不想用脚本，可以手工执行下面步骤。

### 1. 检查服务

```bash
systemctl status svmstack-nginx --no-pager -l
```

正常应看到：

```text
Active: active (running)
```

异常可能看到：

```text
Active: failed
status=9/KILL
control process exited
```

### 2. 检查 nginx 配置测试

```bash
/usr/local/svmstack/nginx/bin/nginx -t -c /usr/local/svmstack/nginx/conf/nginx.conf
```

如果看到：

```text
nginx: [emerg] module "/var/adm/<uuid>/nginx/module.so" is not binary compatible in command line
```

说明启动过程已经被恶意库劫持。

### 3. 检查 6767 端口

```bash
ss -lntp | grep ':6767'
```

正常应看到 nginx 监听：

```text
LISTEN ... *:6767 ... users:(("nginx",pid=...))
```

### 4. 检查 preload

```bash
ls -l /etc/ld.so.preload
stat /etc/ld.so.preload
wc -c /etc/ld.so.preload
```

如果 `ls` 能看到文件，但 `wc` 或 `cat` 提示不存在，这是 hook 现象，不要误判为文件真的不存在。

### 5. 检查恶意 udev 规则

```bash
grep -R --line-number -E '/var/adm|RING04H|libutilkeybd|module\.so' /etc/udev/rules.d 2>/dev/null
```

典型恶意规则：

```text
ACTION=="add", SUBSYSTEM=="net", KERNEL!="lo", ENV{RING04H}="<uuid>", RUN+="/usr/bin/systemd-run ... /var/adm/$env{RING04H}/udev/udev.sh %k"
```

### 6. 检查恶意目录

```bash
find /var/adm -maxdepth 4 -print 2>/dev/null
```

典型内容：

```text
/var/adm/<uuid>/kernel/libutilkeybd.so
/var/adm/<uuid>/nginx/module.so
/var/adm/<uuid>/udev/udev.sh
/var/adm/<uuid>/suid/bash
/var/adm/<uuid>/office/ring04h_office_bin
```

### 7. 用 syscall 清空 preload

普通 `echo "" > /etc/ld.so.preload` 可能被 hook 干扰，所以建议用直接 syscall：

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

确认：

```bash
ls -l /etc/ld.so.preload
wc -c /etc/ld.so.preload
```

正常应为 `0` 字节。

### 8. 隔离恶意目录和 udev 规则

把 `<uuid>` 换成当前服务器实际 UUID：

```bash
UUID=<uuid>
TS=$(date +%Y%m%d-%H%M%S)
Q=/root/solusvm-rootkit-quarantine-$TS
mkdir -p "$Q"

mv /etc/udev/rules.d/99-$UUID.rules "$Q/" 2>/dev/null || true
mv /var/adm/$UUID "$Q/" 2>/dev/null || true

udevadm control --reload-rules
systemctl daemon-reload
```

建议先隔离，不要马上 `rm -rf`，因为隔离目录可以作为证据。

### 9. 重启 svmstack-nginx

```bash
/usr/local/svmstack/nginx/bin/nginx -t -c /usr/local/svmstack/nginx/conf/nginx.conf
systemctl reset-failed svmstack-nginx
systemctl restart svmstack-nginx
systemctl status svmstack-nginx --no-pager -l
ss -lntp | grep ':6767'
```

### 10. 检查新 nginx 进程是否干净

```bash
for p in $(pgrep -x nginx); do
  echo "-- pid $p"
  grep 'libutilkeybd\|/var/adm' /proc/$p/maps 2>/dev/null || echo clean
done
```

正常输出应该是：

```text
-- pid xxxx
clean
```

## 恢复后必须做的安全动作

这类问题通常代表攻击者至少曾经拿到过 root 或等价权限。恢复 `6767` 只是恢复业务，不代表系统完全可信。

### 1. 修改 root 密码

```bash
passwd root
```

### 2. 检查 SSH 公钥

```bash
cat /root/.ssh/authorized_keys
```

删除不认识的 key。

### 3. 检查登录记录

```bash
last -a | head -50
grep "Accepted" /var/log/secure | tail -100
```

### 4. 限制 SSH

确认你已经有可用 SSH key 后，再考虑修改 `/etc/ssh/sshd_config`：

```text
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
```

然后：

```bash
systemctl restart sshd
```

不要在没有确认 SSH key 能登录前关闭密码登录，否则可能把自己锁在服务器外。

### 5. 可选：锁定 preload 文件

```bash
: > /etc/ld.so.preload
chmod 0644 /etc/ld.so.preload
chown root:root /etc/ld.so.preload
chattr +i /etc/ld.so.preload
```

解除：

```bash
chattr -i /etc/ld.so.preload
```

### 6. 安排维护重启

清理后，新启动的 nginx 是干净的。但 PID 1 或其他老进程可能仍在内存里保留旧恶意库映射。建议业务低峰期安排宿主机重启。

重启后验证：

```bash
systemctl status svmstack-nginx --no-pager -l
ss -lntp | grep ':6767'
wc -c /etc/ld.so.preload
grep -R --line-number -E '/var/adm|RING04H|libutilkeybd|module\.so' /etc/udev/rules.d 2>/dev/null
find /var/adm -maxdepth 4 -print 2>/dev/null
```

## 常见问题

### 脚本会删除业务数据吗？

不会。脚本只针对已观察到的 Rootkit 特征：

- `/etc/ld.so.preload`
- `/etc/udev/rules.d` 中包含 `/var/adm`、`RING04H`、`libutilkeybd` 的规则
- `/var/adm/<uuid>` 下包含 `libutilkeybd.so`、`module.so`、`udev.sh`、`ring04h_office_bin` 的目录

并且默认移动到隔离目录，不直接永久删除。

### 为什么不用 `echo "" > /etc/ld.so.preload`？

因为这次实际遇到过 hook 现象：`ls` 显示 `/etc/ld.so.preload` 存在，但 `cat`、`wc`、shell 重定向提示不存在。说明普通 libc 文件操作可能被恶意库欺骗。

脚本使用 Perl 直接 syscall：

- `unlink(2)` 删除 preload 文件
- `open(2)` 重新创建空文件

这样更容易绕过用户态 hook。

### 修复后为什么还建议重启？

`/etc/ld.so.preload` 只影响新启动的动态链接进程。已经运行中的老进程可能仍然加载过恶意库。脚本会确保新启动的 nginx 干净，但不能替你重启所有宿主机进程。

### 这能保证永不复发吗？

不能。如果攻击者仍然能 SSH 登录 root，或还有其他后门，他可以再次写入文件。必须配合改密码、换 key、检查登录记录、限制 SSH、升级系统或重装。

### CentOS 7 还能继续用吗？

CentOS 7 已经是高风险系统。短期可以用脚本恢复业务，长期建议迁移到 SolusVM 支持的更新系统版本，或者重装干净宿主机后再接回主控。

## 脚本输出文件

每次运行会生成：

```text
/root/solusvm-rootkit-recovery-<timestamp>.log
/root/solusvm-rootkit-quarantine-<timestamp>/
```

日志用于复盘，隔离目录用于保留证据。

## 免责声明

本脚本用于应急恢复和清理已知特征。Rootkit 感染后的系统不能仅凭脚本清理就视为完全可信。生产环境应尽快完成凭据轮换、入侵来源排查、维护重启，必要时重装系统。

## License

MIT
