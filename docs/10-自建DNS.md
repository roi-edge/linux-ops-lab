# 10 自建 DNS（dnsmasq）

> 实验日期：2026-11-06
> 环境：Ubuntu 24.04.5 LTS（`ubuntulearn` / `192.168.9.128`），**dnsmasq 2.91-0ubuntu0.24.04.2**
> 快照：`lab-10-开始`
> 关联：[07 网络命令](07-网络命令.md)（`dig` 四段结构、`resolvectl` 存根）、[09 防火墙](09-防火墙.md)（放行 53）、[11 静态 IP](11-静态IP.md)（把 DNS 配置持久化）

---

## 一、目标与验收

**做：** 装 `dnsmasq`，把 `lab.local` 解析到本机；配置上游 DNS

**验收：** 客户端 `dig www.lab.local` 能出结果；能解释**递归查询**和**转发**

**结论：** 达成，但过程中挖出一个比实验本身更值钱的东西 —— **`.local` 后缀在 Ubuntu 24.04 上会被 systemd-resolved 拦死**（第五节）。最终可用域名是 `www.lab.test`，`www.lab.local` 也能用但需要额外一条 `resolvectl domain`。

---

## 二、最终状态

### 2.1 配置文件（唯一改动点）

```bash
# 身份：madrough @ ubuntulearn（查看）
madrough@ubuntulearn:~$ cat /etc/dnsmasq.d/lab10.conf
```

```conf
# 实验 10 自建 DNS —— 改动后：sudo dnsmasq --test -C /etc/dnsmasq.d/lab10.conf && sudo systemctl restart dnsmasq

# ① 只在 ens33 上提供服务，不绑 0.0.0.0（避开 systemd-resolved 的 127.0.0.53）
interface=ens33
bind-dynamic

# ② lab.local 是本地区，查不到就回 NXDOMAIN，绝不转发
local=/lab.local/

# ③ 本地记录
host-record=www.lab.local,192.168.9.128
host-record=ns.lab.local,192.168.9.128

# ④ 上游：显式指定，且不读 /etc/resolv.conf（它指向 127.0.0.53，会成环）
no-resolv
server=192.168.9.2

# ⑤ 缓存与查询日志
cache-size=1000
log-queries
log-facility=/var/log/dnsmasq.log

# ⑥ 对照后缀：.test 是 RFC 6761 保留的测试域，不会撞 mDNS
local=/lab.test/
host-record=www.lab.test,192.168.9.128

# ⑦ 泛解析：*.wild.lab.test 全部指向同一个地址
address=/wild.lab.test/192.168.9.222
```

**没有动 `/etc/dnsmasq.conf`**（保持全注释的出厂状态）。所有实验配置集中在 `dnsmasq.d` 里，删一个文件就能回滚。

### 2.2 监听地址

```bash
madrough@ubuntulearn:~$ sudo ss -ulnp | grep ':53 '
```

```
UNCONN 0 0  127.0.0.1:53                    dnsmasq pid=5901
UNCONN 0 0  192.168.9.128:53                dnsmasq pid=5901
UNCONN 0 0  [::1]:53                        dnsmasq pid=5901
UNCONN 0 0  [fe80::20c:29ff:febb:aadb]%ens33:53  dnsmasq pid=5901
UNCONN 0 0  127.0.0.54:53                   systemd-resolve pid=863
UNCONN 0 0  127.0.0.53%lo:53                systemd-resolve pid=863
```

| 地址 | 归属 | 谁在用 |
|---|---|---|
| `127.0.0.53:53` | systemd-resolved **存根** | `/etc/resolv.conf` 里那唯一一条 `nameserver` |
| `127.0.0.54:53` | systemd-resolved（第二个监听，systemd 新版引入） | resolved 自己 |
| `127.0.0.1:53` | **dnsmasq** | 被我们把 resolved 的上游指向它 |
| `192.168.9.128:53` | **dnsmasq** | Windows 等外部客户端 |

**两个进程同时占 53 端口而不冲突**，因为绑的是**不同 IP 地址**（不是同一个 `0.0.0.0:53`）。这是本实验第一个关键认知。

### 2.3 完整解析链路（三段式）

```
dig / ping / getent / curl
        │  读 /etc/resolv.conf
        ▼
127.0.0.53:53  ← systemd-resolved 存根（只做转发，不做解析）
        │  上游 = 127.0.0.1（我们用 resolvectl 改的）
        ▼
127.0.0.1:53   ← dnsmasq（缓存 + 本地权威 + 转发器）
        │  lab.local/lab.test → 本地数据直接回答
        │  其他域名 → server=192.168.9.2
        ▼
192.168.9.2:53 ← VMware NAT 网关（真正的递归解析在它或它上游）
        ▼
公网 DNS 根 / 顶级域 / 权威服务器
```

### 2.4 系统层面的两处运行时设置（**重启会丢**）

```bash
# 身份：madrough @ ubuntulearn（查看）
madrough@ubuntulearn:~$ resolvectl dns ens33
madrough@ubuntulearn:~$ resolvectl domain ens33
```

```
Link 2 (ens33): 127.0.0.1
Link 2 (ens33): lab.local
```

| 设置 | 作用 | 命令 |
|---|---|---|
| `dns 127.0.0.1` | 把 ens33 这层的上游改成 dnsmasq | `sudo resolvectl dns ens33 127.0.0.1` |
| `domain lab.local` | 把 `*.lab.local` 强制路由到 ens33 的 DNS（**压过 resolved 的 mDNS 规则**） | `sudo resolvectl domain ens33 lab.local` |

> **这两条都是运行时的，`netplan apply` 或重启后消失。** 持久化留给 [11 静态 IP](11-静态IP.md) 的 netplan 配置。

---

## 三、操作步骤（含一次"故意的失败"）

### 3.1 前置：先看清 53 端口归谁

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ ip -4 addr show ens33 | grep inet
madrough@ubuntulearn:~$ sudo ss -ulnp | grep ':53 '
madrough@ubuntulearn:~$ sudo ss -tlnp | grep ':53 '
madrough@ubuntulearn:~$ ls -l /etc/resolv.conf
madrough@ubuntulearn:~$ resolvectl status | head -25
madrough@ubuntulearn:~$ apt-cache policy dnsmasq
madrough@ubuntulearn:~$ sudo ufw status numbered
```

**实测关键输出：**

```
127.0.0.54:53    systemd-resolve pid=863     ← 两个地址都是同一个进程
127.0.0.53%lo:53 systemd-resolve pid=863
/etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
resolv.conf mode: stub
Current DNS Server: 192.168.9.2
dnsmasq: Installed: (none)  Candidate: 2.91-0ubuntu0.24.04.2
```

**为什么先看**：53 已经被占，直接装大概率起不来。**先知道敌人是谁，再动手**。

### 3.2 装 dnsmasq，让它失败一次

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo apt install -y dnsmasq
madrough@ubuntulearn:~$ systemctl status dnsmasq --no-pager -l | head -20
madrough@ubuntulearn:~$ sudo journalctl -u dnsmasq -n 20 --no-pager
```

**实测（必然失败，因为默认配置全注释）：**

```
× dnsmasq.service - dnsmasq - A lightweight DHCP and caching DNS server
     Active: failed (Result: exit-code)
   Process: 3954 ExecStart=/usr/share/dnsmasq/systemd-helper exec (code=exited, status=2)
dnsmasq: failed to create listening socket for port 53: Address already in use
dnsmasq: FAILED to start up
```

**根因**：`grep -vE '^\s*#|^\s*$' /etc/dnsmasq.conf` **输出为空** —— 默认配置里**一条生效的都没有**，于是 dnsmasq 用内建默认值 `0.0.0.0:53`，与 resolved 的 `127.0.0.53:53` 撞车。

| dnsmasq 内建默认 | 值 | 在本机的后果 |
|---|---|---|
| 监听地址 | `0.0.0.0:53`（所有地址） | **EADDRINUSE**，起不来 |
| 上游 | 读 `/etc/resolv.conf` | 读到 `127.0.0.53` → **环路** |
| 缓存条数 | 150 | 偏小 |

### 3.3 看清 unit 和"真实命令行"

```bash
# 身份：madrough @ ubuntulearn
madrough@ubuntulearn:~$ systemctl cat dnsmasq | head -40
madrough@ubuntulearn:~$ grep -nE 'dnsmasq|conf-file|conf-dir|-7 ' /usr/share/dnsmasq/systemd-helper | head -30
madrough@ubuntulearn:~$ ps -ef | grep [d]nsmasq
```

**Ubuntu 的 unit 不直接调 `/usr/sbin/dnsmasq`，中间套了 `/usr/share/dnsmasq/systemd-helper`。** 启动成功后 `ps` 里能看到它最终传进去的完整命令行：

```
/usr/sbin/dnsmasq -x /run/dnsmasq/dnsmasq.pid -u dnsmasq -r /run/dnsmasq/resolv.conf \
  -7 /etc/dnsmasq.d,.dpkg-dist,.dpkg-old,.dpkg-new --local-service \
  --trust-anchor=.,20326,8,2,E06D... --trust-anchor=.,38696,8,2,683D...
```

**逐个参数的作用：**

| 参数 | 含义 | 对实验的影响 |
|---|---|---|
| `-x /run/dnsmasq/dnsmasq.pid` | PID 文件位置 | 配合 unit 的 `Type=forking` + `PIDFile=`，systemd 靠它找主进程 |
| `-u dnsmasq` | 绑定端口后**降权**到 `dnsmasq` 用户 | 所以日志文件/租约文件的权限要考虑 |
| `-r /run/dnsmasq/resolv.conf` | 指定"上游清单文件" | **被我们的 `no-resolv` 覆盖掉了**（见下） |
| `-7 /etc/dnsmasq.d,...` | `--conf-dir`，读 `dnsmasq.d` 下的 `.conf`，**忽略** `.dpkg-dist/.dpkg-old/.dpkg-new` 后缀 | **我们的配置就是靠它被加载的** |
| `--local-service` | 只回答本机所在子网的查询，并**强制在回环接口监听** | ① Windows 能问、换网段不能问；② **白送 `127.0.0.1:53`** |
| `--trust-anchor=...` | ICANN 根区 KSK 公钥 | 但**命令行里没有 `--dnssec`**，所以**DNSSEC 校验没开**。有 trust-anchor ≠ 开了校验 |

**方法论**：想知道"配置到底有没有被加载"，**读脚本不如看进程的 `ps` 真实命令行**。脚本只是"可能传什么"，cmdline 是"实际传了什么"。

### 3.4 写配置（用 `sudo tee`，不是 `sudo echo >`）

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权写入）
madrough@ubuntulearn:~$ sudo tee /etc/dnsmasq.d/lab10.conf > /dev/null <<'EOF'
interface=ens33
bind-dynamic
local=/lab.local/
host-record=www.lab.local,192.168.9.128
host-record=ns.lab.local,192.168.9.128
no-resolv
server=192.168.9.2
cache-size=1000
log-queries
log-facility=/var/log/dnsmasq.log
local=/lab.test/
host-record=www.lab.test,192.168.9.128
address=/wild.lab.test/192.168.9.222
EOF
```

### 3.5 语法校验的正确姿势

```bash
# 身份：madrough @ ubuntulearn
madrough@ubuntulearn:~$ sudo dnsmasq --test -C /etc/dnsmasq.d/lab10.conf
```

```
dnsmasq: syntax check OK.
```

**`-C` 不能省**：裸 `dnsmasq --test` 只检查 `/etc/dnsmasq.conf`（那个全注释的空文件），**根本不会看 `dnsmasq.d/` 里的东西**，等于什么都没验。

### 3.6 启动并确认

```bash
# 身份：madrough @ ubuntulearn
madrough@ubuntulearn:~$ sudo systemctl restart dnsmasq
madrough@ubuntulearn:~$ systemctl status dnsmasq --no-pager -l | head -12
madrough@ubuntulearn:~$ sudo ss -ulnp | grep ':53 '
```

**启动日志（`/var/log/dnsmasq.log`）逐行解读：**

```
started, version 2.91 cachesize 1000                              ← 配置生效
compile time options: ... DNSSEC ... loop-detect ...              ← 编译期能力，非运行开关
warning: ignoring resolv-file flag because no-resolv is set        ← ★ no-resolv 赢了 -r
using nameserver 192.168.9.2#53                                    ← ★ 真正的上游
using only locally-known addresses for lab.local                   ← ★ local= 生效
read /etc/hosts - 10 names                                         ← 默认也读 hosts 文件
```

**`warning: ignoring resolv-file flag because no-resolv is set` 是本次最有价值的一行**：Ubuntu 的 unit 传了 `-r`，我们的配置写了 `no-resolv`，**配置文件里的 `no-resolv` 优先级更高**，dnsmasq 明确告知它忽略了 `-r`。没有这条警告，我们只能猜。

### 3.7 让整机真正走自建 DNS

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo resolvectl dns ens33 127.0.0.1
madrough@ubuntulearn:~$ resolvectl status | head -14
madrough@ubuntulearn:~$ dig www.lab.test +short
madrough@ubuntulearn:~$ dig www.lab.local +short          # ← 这一步失败了，见第五节
madrough@ubuntulearn:~$ sudo resolvectl domain ens33 lab.local
madrough@ubuntulearn:~$ dig www.lab.local +short          # ← 加上面那条才通
```

**注意这时的 `dig` 都已经没有 `@服务器`** —— 它读 `/etc/resolv.conf`，走的是"系统默认解析器"这条路，这才是"客户端能不能用域名"的真实测试。

---

## 四、原理

### 4.1 递归查询 vs 转发

| 概念 | 谁做的 | 长什么样 |
|---|---|---|
| **转发（forwarding）** | **dnsmasq**（本实验的角色） | 客户端问它，它把**同一个问题**原样扔给上游 `192.168.9.2`，拿到答案后存进缓存再返回。它**不知道根服务器在哪、不会自己逐级问** |
| **递归（recursion）** | 上游那台（本机是 VMware 网关，公网侧是运营商 DNS 或 8.8.8.8 之类） | 替客户端**跑完全程**：问根 → 问 `.com` 顶级域 → 问权威服务器 → 返回最终答案。客户端只发一次请求 |
| **迭代（iteration）** | 递归服务器**自己**用的手法 | 根说"去问 `.com`"，`.com` 说"去问 ns1.example.com"，一步一步接力 |

**一句话记住三者关系：**

> **客户端要的是"递归"（一次问到底）；递归服务器干活的方式是"迭代"（逐级接力）；dnsmasq 两样都不做，它只做"转发 + 缓存"。**

日志里的证据：`forwarded www.qq.com to 192.168.9.2` —— `forwarded` 这个词就是"转发"的直译。

**dnsmasq 能力的真实边界：**

| 它是 | 它不是 |
|---|---|
| DNS **转发器**（forwarder） | DNS **递归服务器**（那是 unbound / bind 的活） |
| DNS **缓存**（cache-size=1000） | 权威 DNS 服务器（没有 zone 文件、不支持 `AXFR` 主从同步） |
| **本地域名**的小型权威（`host-record` / `address`） | 支持 DNSSEC 签名的服务器（能校验但本机没开） |
| 顺带能做 DHCP / TFTP | — |

### 4.2 三种应答的日志形态

| 日志行 | 含义 | 出网了吗 |
|---|---|---|
| `config www.lab.local is 192.168.9.128` | 来自**本地配置**（`host-record`/`address`/`/etc/hosts`） | 没有 |
| `config notexist.lab.local is NXDOMAIN` | 本地权威**明确否认**（`local=` 挡住，不转发） | 没有 |
| `cached www.example.com is ...` | **缓存命中** | 没有 |
| `forwarded www.example.com to 192.168.9.2` + `reply ...` | **转发**给上游 | 有 |

### 4.3 `local=` 到底防住了什么

没有 `local=/lab.local/` 时，查一个不存在的 `foo.lab.local`，dnsmasq 会**转发给上游**，上游返回 NXDOMAIN。表面结果一样，但：
- 每次查错域名都**出网一趟**（慢、且泄露内网命名习惯）；
- 如果上游配了**泛解析**（很多运营商 DNS 干这事），你会拿到一个**假 IP** 而不是 NXDOMAIN —— **拼错的域名"成功"了**，比失败更难查。

### 4.4 TTL 与缓存

| 记录来源 | 默认 TTL | 后果 |
|---|---|---|
| `host-record` / `address` / `/etc/hosts`（本地记录） | **0** | **客户端不许缓存**，改配置立刻生效（可用 `local-ttl=` 改） |
| 上游转发来的 | 上游给的（本机实测被压到 **5 秒**） | 5 秒内重复查走缓存，超过就必须再出网 |

**本环境的特殊情况**：`dig @192.168.9.2 www.example.com` 返回的 TTL **也是 5**（`example.com` 真实 TTL 是 86400），说明**压 TTL 的是上游或更上面的设备**（VMware NAT 的 DNS 代理，或运营商侧的透明设备 —— 07 里维基百科拿到污染应答，说明这条链路上确实有 DNS 干预）。**后果：本机几乎做不了"缓存命中率"类实验**，15 项故障演练里"DNS 改了不生效 → 查缓存"那一关要另想办法。

### 4.5 `aa` 标志：dnsmasq 冒充权威

```
dig @192.168.9.128 www.lab.local     → flags: qr aa rd ra     ← 有 aa
dig @192.168.9.128 notexist.lab.local → flags: qr rd ra        ← 没有 aa
```

**dnsmasq 对本地数据的肯定应答会置 `aa`（authoritative answer），否定应答（NXDOMAIN）不置。** 所以更准确的说法是：

> dnsmasq **不是**权威服务器（没有 zone、不能主从同步、不能 `AXFR`），但它对本地配置的数据**冒充**权威 —— 肯定应答带 `aa`，否定应答不带。

### 4.6 为什么本地记录和 `dig` 能通、`ping` 不通（`.local` 专章见第五节）

`dig` **直接读 `/etc/resolv.conf`**，绕过 `nsswitch`；`ping`/`curl`/`ssh` 走 `getent` → `nsswitch` → `mdns4_minimal` → `dns`。**两条路径不同**，所以在某些配置下会出现"`dig` 通、`ping` 不通"。

---

## 五、`.local` 专章：本项最大的发现

### 5.1 现象

| 命令 | 结果 |
|---|---|
| `dig @192.168.9.128 www.lab.local` | ✅ `192.168.9.128`（dnsmasq 本身没问题） |
| Windows `Resolve-DnsName www.lab.local -Server 192.168.9.128` | ✅ `192.168.9.128`（外部客户端也没问题） |
| `dig www.lab.local`（走系统解析器） | ❌ **空** |
| `getent hosts www.lab.local` | ❌ 空 |
| `ping www.lab.local` | ❌ `Temporary failure in name resolution` |
| `resolvectl query www.lab.local` | ❌ `No appropriate name servers or networks for name found` |
| 同样操作换 `www.lab.test` | ✅ **全通**（dig / getent / ping） |

### 5.2 根因：systemd-resolved 把 `.local` 划给 mDNS

`resolvectl query` 那句报错是关键：它不是说"查不到"，而是说**"这个名字我没有可以问的地方"**。因为：

- `.local` 是 **mDNS（Bonjour/avahi）的保留后缀**（RFC 6762）；
- **systemd-resolved 硬编码把 `.local` 归到 mDNS 范围**，而本机 `Protocols: -LLMNR -mDNS`（mDNS 关闭）→ **连转发都不给转**，请求根本到不了 dnsmasq。

**所以 dnsmasq 再正确也没用 —— 这是 systemd-resolved 的决定，不是 DNS 的决定。**

### 5.3 修法：给 resolved 插一条"路由域"

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo resolvectl domain ens33 lab.local
madrough@ubuntulearn:~$ resolvectl domain ens33
Link 2 (ens33): lab.local
madrough@ubuntulearn:~$ dig www.lab.local +short
192.168.9.128
madrough@ubuntulearn:~$ resolvectl query www.lab.local
www.lab.local: 192.168.9.128
-- Information acquired via protocol DNS in 1.6ms.
-- Data was acquired via local or encrypted transport: no
-- Data from: network
```

**`resolvectl domain ens33 lab.local` 的作用**：在 resolved 的**路由表**里插一条"凡是 `*.lab.local`，交给 ens33 这条链路的 DNS（`127.0.0.1`）"。**路由域的优先级高于 `.local`→mDNS 的默认规则**，于是通了。

**注意 `-- Data from: network`** —— 证明是真的走网络问到了 dnsmasq，不是从缓存糊出来的。

### 5.4 关于 `nsswitch` 那条 `mdns4_minimal`（一个被证伪的猜想）

`/etc/nsswitch.conf` 里的默认行是：

```
hosts:          files mdns4_minimal [NOTFOUND=return] dns
```

看起来 `[NOTFOUND=return]` 会在 mDNS 说"没有"时**掐断**，让 `dns` 永远轮不到。**实测下来没有掐断**：

```bash
madrough@ubuntulearn:~$ dpkg -l libnss-mdns | tail -1
ii  libnss-mdns:amd64 0.15.1-4build1   NSS module for Multicast DNS name resolution
madrough@ubuntulearn:~$ systemctl is-active avahi-daemon
active
madrough@ubuntulearn:~$ getent hosts www.lab.local
192.168.9.128   www.lab.local          ← 模块装了、avahi 也在跑，照样通
```

原因：**`mdns4_minimal` 不是"有/没有"两种返回值，而是三种。**

| 它的返回值 | `[NOTFOUND=return]` 是否触发 | glibc 的行为 |
|---|---|---|
| `SUCCESS` + 结果 | — | 直接用（mDNS 真答出来了） |
| **`NOTFOUND`**（mDNS 明确答"不存在"） | **触发** | **停止**，不再问 `dns` ← 这才是坑 |
| **`UNAVAIL` + `EAGAIN`**（模块不处理这个名字 / mDNS 无应答超时） | **不触发**（规则只匹配 NOTFOUND） | **继续**往下问 `dns` ← 本机就是这种 |

本机 avahi 在跑但**没有任何设备应答** `www.lab.local`，模块返回 `UNAVAIL/EAGAIN` → 规则不匹配 → 落到 `dns` → 成功。

**副产品：这解释了 `ping` 那条 `EAI_AGAIN`（Temporary failure in name resolution）。** 当时那是 `UNAVAIL/EAGAIN` 映射出来的"临时失败"，而它后面接的 `dns` 也失败（因为 resolved 那道关还没拆），两层都失败，所以看起来像"mDNS 截胡"。

### 5.5 生产建议

| 后缀 | 能不能用 | 说明 |
|---|---|---|
| `.local` | ❌ **别用** | mDNS 保留，resolved 直接拦，nss 层还埋着 `[NOTFOUND=return]` 的雷（换个 avahi 应答正常的网络就真会炸） |
| `.test` | ✅ **推荐做实验** | RFC 6761 保留的测试域，公网永远解析不到，不会撞任何机制 |
| `.internal` | ✅ 可以 | ICANN 2024 年专门保留给私有网络 |
| `lab.corp.example.com` | ✅ 生产标准做法 | 挂在自己域名的子域下，不占任何保留位 |

---

## 六、防火墙：53 必须 UDP + TCP 各放一条

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo ufw allow 53/udp
madrough@ubuntulearn:~$ sudo ufw allow 53/tcp
madrough@ubuntulearn:~$ sudo ufw status numbered
madrough@ubuntulearn:~$ sudo iptables -S ufw-user-input
```

**实测 ufw 输出：**

```
[ 4] 53/udp                     ALLOW IN    Anywhere
[ 5] 53/tcp                     ALLOW IN    Anywhere
[ 9] 53/udp (v6)                ALLOW IN    Anywhere (v6)
[10] 53/tcp (v6)                ALLOW IN    Anywhere (v6)
```

**`iptables -S` 里的真实形态：**

```
-A ufw-user-input -p udp -m udp --dport 53 -j ACCEPT
-A ufw-user-input -p tcp -m tcp --dport 53 -j ACCEPT
```

（v6 那两条是 ufw 自动配的，因为 dnsmasq 确实在 `[::1]:53` 和 `fe80::...%ens33:53` 上听着。）

### 6.1 为什么 TCP 53 也要放

| 协议 | 用途 | 不放的症状 |
|---|---|---|
| **UDP 53** | 常规查询（一问一答一个包） | **所有 DNS 全挂** |
| **TCP 53** | ① 应答超过 UDP 报文上限（EDNS0 协商的 `udp: 1232`）→ 服务器回 `TC`（截断）标志 → 客户端**改用 TCP 重问**；② 区域传送 `AXFR`；③ UDP 被中间设备丢弃时的回退 | **最阴的故障**：普通域名能查，"答案很长"的域名查不了（多级 CNAME、多 IP、DNSSEC 记录） |

### 6.2 放行前后的对照实验（因果证据）

| 时刻 | 命令（Windows） | 结果 |
|---|---|---|
| 放行前 | `Resolve-DnsName www.lab.local -Server 192.168.9.128 -DnsOnly -QuickTimeout` | ❌ `ERROR_TIMEOUT`（`OperationTimeout`） |
| 放行后 | 同一条命令，一个字没改 | ✅ `www.lab.local  A  0  Answer  192.168.9.128` |

**dnsmasq 日志侧的同时证据：**

```
query[A] www.lab.local from 192.168.9.1      ← 192.168.9.1 = Windows 在 VMnet8 上的地址
config www.lab.local is 192.168.9.128
```

**这一行同时证明三件事**：① 防火墙真的放行了；② 请求走的是**网络**不是本机回环（之前所有查询的 `from` 都是 `192.168.9.128`）；③ `--local-service` 接受了同网段（`192.168.9.0/24`）的查询。

> **注意 `--local-service` 的隐形门槛**：换一个网段的客户端来问，dnsmasq 会**静默不答**，日志里可能连 `query` 行都没有。以后遇到"外网 DNS 查不到"要想到这条。

---

## 七、缓存验证实验（第一次是失败的）

### 7.1 第一次：设计错误，必然失败

```bash
madrough@ubuntulearn:~$ dig @192.168.9.128 www.qq.com +noall +answer
madrough@ubuntulearn:~$ dig @192.168.9.128 www.qq.com +noall +answer
```

两条 TTL 都是 **5**，而两次操作间隔 **12 秒** → TTL 早过期 → 第二次照样 `forwarded`。

**错在哪**：验证缓存必须满足 **两次采样间隔 < TTL**。`qq.com` 的 TTL 只有 5 秒，**人工敲两条命令根本控制不住间隔**。

**附带发现**：`qq.com` / `www.example.com` / `www.ubuntu.com` 的 TTL **全是 5**，而 `example.com` 的真实 TTL 是 86400 → 压 TTL 的是上游链路，不是我们这层。CDN 域名本来就爱设短 TTL（故障切换/就近调度能秒级生效），代价是缓存基本没用。

### 7.2 第二次：把两次查询塞进同一条命令行

```bash
madrough@ubuntulearn:~$ dig @192.168.9.128 www.example.com +noall +answer; dig @192.168.9.128 www.example.com +noall +answer
madrough@ubuntulearn:~$ sudo tail -8 /var/log/dnsmasq.log
```

**日志（教科书级）：**

```
03:39:18 query[A] www.example.com from 192.168.9.128
03:39:18 forwarded www.example.com to 192.168.9.2      ← 第一次：出网问上游
03:39:18 reply www.example.com is 104.20.23.154
03:39:18 reply www.example.com is 172.66.147.243
03:39:18 query[A] www.example.com from 192.168.9.128
03:39:18 cached www.example.com is 104.20.23.154       ← ★ 第二次：缓存命中，没出网
03:39:18 cached www.example.com is 172.66.147.243
```

**判据：`forwarded` 只出现一次、第二次是 `cached`。** 这比看 `dig` 的 `Query time` 可靠得多（毫秒级差异容易被噪声淹没）。

### 7.3 本地记录为什么看不出缓存效果

`host-record` 的 TTL 是 **0**，客户端**不许缓存**，所以 `www.lab.local` 无论问几次都是"本地直接答"，没有"缓存命中"这个概念。

---

## 八、单点故障演练（自建 DNS 变成 SPOF）

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo systemctl stop dnsmasq
madrough@ubuntulearn:~$ dig www.baidu.com +short; echo "dig 退出码=$?"
madrough@ubuntulearn:~$ ping -c1 -W2 192.168.9.2
madrough@ubuntulearn:~$ sudo systemctl start dnsmasq
madrough@ubuntulearn:~$ dig www.baidu.com +short
```

**实测：**

| 操作 | 结果 | 说明 |
|---|---|---|
| `dig www.baidu.com +short`（dnsmasq 已停） | **空输出**，但 `退出码=0` | ⚠️ **`dig` 的退出码不可靠**：只要收到"应答包"（哪怕是 SERVFAIL）就返回 0。**判断成败要看输出，不能看 `$?`** |
| `ping 192.168.9.2` | ✅ 通，`time=0.183 ms` | **网络层完好**，坏的只是 DNS |
| `ssh 192.168.9.128` | ✅ 不受影响 | SSH 用 IP，不查 DNS |

**三条结论：**

1. **自建 DNS 是新的单点故障**：它一停，全机域名解析全挂（`apt` / `curl 域名` / `ping 域名` 全废），但**按 IP 访问一切正常**。
2. **"域名解析不了" ≠ "网络不通"**：`ping 192.168.9.2` 通 = 网络好的；`ping www.baidu.com` 失败 = DNS 或解析链的问题。
3. 生产上 mitigations：配两台 DNS（主备）、上游列表里**同时**写 `127.0.0.1` 和 `192.168.9.2`（resolved 会在前一个失败时用后一个）。

---

## 九、踩坑清单

| # | 坑 | 说明 / 正确做法 |
|---|---|---|
| 1 | 装完直接 `systemctl start dnsmasq` | 默认配置**一条生效的都没有**，绑 `0.0.0.0:53` 必撞 resolved 的 `127.0.0.53` → `Address already in use`。**先看 `ss -ulnp \| grep :53`，再写 `interface=`/`bind-dynamic`** |
| 2 | `sudo echo "..." > /etc/xxx` | 重定向是**当前 shell（普通用户）**执行的，`sudo` 只提权了 `echo` → `Permission denied`。用 `sudo tee` |
| 3 | `dnsmasq --test` 就算校验过了 | 裸 `--test` 只读 `/etc/dnsmasq.conf`，**不看 `dnsmasq.d/`**。必须 `--test -C 文件` |
| 4 | 以为 `-r` 会覆盖 `no-resolv` | 反过来：**`no-resolv` 优先**，日志明确警告 `ignoring resolv-file flag`。不改的话会去读 `127.0.0.53` → **环路** |
| 5 | 以为 `--trust-anchor` = 开了 DNSSEC | 只是"信任锚"，要 `--dnssec` 才真的校验。本机没开 |
| 6 | 忘放行 53 / 只放 UDP | UDP 挂全挂；**只放 UDP 会出现"大响应查不到"**。ufw 里 `53/udp` 和 `53/tcp` **两条都要** |
| 7 | 用 `.local` 做实验域名 | **两道雷**：resolved 把 `.local` 划给 mDNS（连转发都不给），`nsswitch` 里还埋着 `[NOTFOUND=return]`。**用 `.test` / `.internal` / 自有子域** |
| 8 | `getent -s dns` 通就以为客户端能用 | `-s dns` 只强制"用 dns 这个数据源"，但 dns 数据源读的是 `127.0.0.53` → 走 resolved。**dnsmasq 不在系统解析链上时，它照样失败** |
| 9 | 用 `dig` 的退出码判断成功 | `dig` 收到 SERVFAIL 应答也返回 0。**看输出，不看 `$?`** |
| 10 | 人工敲两条 `dig` 验证缓存 | 间隔不可控，TTL 5 秒时必失败。**两条命令塞进同一个 shell 行（`;` 分隔）** |
| 11 | `log-facility=` 写文件不管它 | dnsmasq 以 root 打开日志后降权，文件能建；但**没有 logrotate，会无限增长**。本项遗留（留给 13 备份/日志轮转） |
| 12 | 停掉 dnsmasq 后以为"网络坏了" | `ping IP` 通、`ping 域名` 不通 = **纯 DNS 问题**。自建 DNS 本身就是新的单点 |
| 13 | 以为 `127.0.0.53` 和 `127.0.0.54` 是两个服务 | 都是 `systemd-resolve` 同一个 pid。`127.0.0.53` 是给应用的**存根**，`127.0.0.54` 是 resolved 自己用的第二个监听 |

---

## 十、命令详解（本项首次出现）

### 10.1 `dnsmasq` 及其配置项

| 命令 / 参数 | 是什么 → 干什么 → 为什么这里用 |
|---|---|
| `apt install -y dnsmasq` | `dnsmasq` 是元包，会拉 `dnsmasq-base` + systemd unit + `/etc/dnsmasq.conf`。`-y` 免交互确认 → 为什么用：非交互环境批量装 |
| `systemctl cat <unit>` | 打印 unit 文件**全文**（含 drop-in 覆盖）。比 `systemctl status` 强在能看到 `ExecStart=` 的完整参数 → 为什么用：搞清"包装脚本到底传了什么" |
| `/usr/share/dnsmasq/systemd-helper` | Ubuntu 的**包装脚本**，单位文件不是直接调 dnsmasq 而是调它。它负责 `checkconfig`（语法校验）、拼 `-7` 等参数、`exec` 真正的 dnsmasq、以及启动后 `start-resolvconf` → 为什么用：不看它就不知道 `-r` / `--local-service` 从哪来 |
| `dnsmasq --test -C <文件>` | `--test` 只做**语法校验**后退出（不启动、不监听）；`-C`（`--conf-file=`）**替代**默认的 `/etc/dnsmasq.conf` 去读 → 为什么用：裸 `--test` 读不到 `dnsmasq.d/`，等于没测 |
| `interface=ens33` | 只在这块网卡**及其地址**上提供服务 → 为什么用：避免绑 `0.0.0.0:53` 撞 resolved |
| `bind-dynamic` | 只绑"当前存在且匹配 `interface=` 的地址"，并且**地址变化时自动重绑** → 为什么用：比 `bind-interfaces`（启动时绑一次，IP 变了就废）更适合会改 IP 的机器，**为实验 11 埋伏笔** |
| `listen-address=<IP>` | 精确指定监听地址（本实验**没用**，因为会把 IP 硬编码） → 什么时候用：地址固定的服务器上更直观 |
| `local=/lab.local/` | 把 `lab.local` 声明为**本地区**：只在本地数据里找，**查不到直接回 NXDOMAIN，绝不转发** → 为什么用：防止每次查错域名都出网，也防止上游泛解析污染 |
| `host-record=名字,IP` | 加一条**精确**的 A 记录（并生成反向 PTR），TTL 默认 0 → 为什么用：固定主机的静态记录 |
| `address=/wild.lab.test/1.2.3.4` | **泛解析**：匹配 `wild.lab.test` 及其**所有子域**，统一返回该 IP。同时隐含 `local=` 语义 → 为什么用：批量把一群子域指到一台内网机；**代价是 NXDOMAIN 消失，拼错域名也"成功"** |
| `no-resolv` | **不读** `/etc/resolv.conf` 作为上游来源 → 为什么用：那份文件里是 `127.0.0.53`，读了就成环 |
| `server=192.168.9.2` | 指定上游 DNS（可写 `server=/域名/上游` 做分流） → 为什么用：显式声明唯一上游，可预测、可审计 |
| `cache-size=1000` | 缓存条数（默认 150） → 为什么用：内网几百台机器时默认值偏小 |
| `log-queries` | 把**每一次查询**写进日志 → 为什么用：排查"到底出网了没有""命中缓存没有"的唯一手段 |
| `log-facility=/var/log/dnsmasq.log` | 日志写文件而不是 syslog → 为什么用：单独文件好 `tail -f`、好按时间切；**副作用：要自己配 logrotate** |
| `--local-service`（unit 塞的，非我们配） | ① 只回答**本机所在子网**的查询；② **强制在回环监听** → 后果：白送 `127.0.0.1:53`，但换网段就静默不答 |

### 10.2 `dig` 新用到的参数

| 参数 | 是什么 → 干什么 → 为什么这里用 |
|---|---|
| `dig @服务器 名字` | `@` 指定**直接问哪台 DNS**，绕过 `/etc/resolv.conf` → 为什么用：区分"dnsmasq 本身对不对"和"系统解析链通不通" |
| `+short` | 只输出答案值，砍掉全部协议细节 → 为什么用：脚本里好取；**代价：看不到 TTL** |
| `+noall +answer` | `+noall` 关掉所有输出段，`+answer` 只开 ANSWER 段 → 为什么用：**要保留 TTL 列**就得用它，`+short` 会丢 TTL |
| `dig \| grep status` | 只取 `->>HEADER<<- ... status: XXX` 那一行 → 为什么用：判断 NXDOMAIN / NOERROR / SERVFAIL 最快 |
| `flags: qr aa rd ra` | `qr`=这是应答；`aa`=权威应答；`rd`=客户端要求递归；`ra`=服务器愿意递归。**本项用它区分"本地数据答"和"转发答"** |

### 10.3 `resolvectl`（07 里见过 `status`，这里多了三个子命令）

| 命令 | 是什么 → 干什么 → 为什么这里用 |
|---|---|
| `resolvectl status` | 看每条链路的当前 DNS 服务器、DNS 域、DNSSEC/protocol 开关 → 为什么用：确认"上游到底是谁" |
| `resolvectl query <名字>` | **直接问 systemd-resolved**（既不过 nsswitch 也不看 resolv.conf）→ 为什么用：把"resolved 层"单独隔离出来测，是本项定位 `.local` 问题的关键工具 |
| `sudo resolvectl dns ens33 127.0.0.1` | 把 ens33 链路的 **DNS 服务器**设为 `127.0.0.1`（**运行时**，不写盘）→ 为什么用：不碰 `/etc/resolv.conf` 就让整机走自建 DNS；**重启失效** |
| `sudo resolvectl domain ens33 lab.local` | 给 ens33 登记一个**路由域**："`*.lab.local` 交给这条链路的 DNS" → 为什么用：**压过 resolved 对 `.local` 的 mDNS 规则**，是本项唯一能救 `lab.local` 的招 |
| `resolvectl flush-caches` | 清 resolved 的缓存（本项没用到，但改完 DNS 常需要）| — |

### 10.4 `getent` 与 `nsswitch`

| 命令 | 是什么 → 干什么 → 为什么这里用 |
|---|---|
| `getent hosts <名字>` | 走**完整 nsswitch 链**（`files` → `mdns4_minimal` → `dns`）解析 → 为什么用：`ping`/`curl`/`ssh` 用的就是这条路，**这才是"客户端能不能用域名"的真实测试** |
| `getent -s dns hosts <名字>` | `-s <数据源>` 强制**只用指定数据源**，跳过 files 和 mdns → 为什么用：判断"是不是前面的环节把查询吃掉了" |
| `grep '^hosts' /etc/nsswitch.conf` | 看主机名解析的**顺序和状态规则** → `[NOTFOUND=return]` 的含义是"若该模块返回 NOTFOUND 就停止"；**`UNAVAIL` 不触发**，会继续往下 |
| `dpkg -l libnss-mdns` | 看这个包装没装 → 为什么用：nsswitch 里写了模块名，但**模块不存在时那行就是死文字**（返回 UNAVAIL） |

### 10.5 其它

| 命令 / 参数 | 是什么 → 干什么 → 为什么这里用 |
|---|---|
| `ping -c1 -W2 <名字>` | `-c1` 只发 1 个包；`-W2` 最多等 2 秒 → 为什么用：不加这两个，`ping` 会一直跑着卡住终端 |
| `Resolve-DnsName -Server X -Type A -DnsOnly -QuickTimeout` | Windows 的 DNS 查询 cmdlet。`-Server` 指服务器；`-Type A` 只要 A 记录；`-DnsOnly` 不试 NetBIOS/LLMNR/mDNS；`-QuickTimeout` 几秒就放弃 → 为什么用：Windows 默认会串着试一堆，容易误判，且默认超时要等十几秒 |
| `for d in A B C; do ...; done` | shell 循环，`d` 依次取值 → 为什么用：一次量多个域名的 TTL，省得手打三遍 |
| `sudo tee <文件> > /dev/null <<'EOF'` | `tee` 把 stdin **同时**写文件和 stdout；`> /dev/null` 丢掉屏幕回显；`<<'EOF'` 单引号**禁止变量展开** → 为什么用：**root 权限写文件**，这是 `sudo echo > file` 失败的正确替代 |
| `ps -ef \| grep [d]nsmasq` | `[d]` 让 grep **不匹配自己**那一行（否则每次多一条假阳性）→ 为什么用：看**实际生效的完整命令行** |
| `tail -8 <文件>` | 看文件最后 8 行 → 为什么用：改动后只关心最新的几行日志 |

---

## 十一、验收记录

| 验收项 | 结果 |
|---|---|
| 装 `dnsmasq` 并把 `lab.local` 解析到本机 | ✅ `dig @192.168.9.128 www.lab.local` → `192.168.9.128`（TTL 0） |
| **客户端 `dig www.lab.local` 能出结果** | ✅ **Windows 客户端**：`Resolve-DnsName www.lab.local -Server 192.168.9.128` → `A 192.168.9.128`（日志 `from 192.168.9.1` 证明走网络）。**本机**：`dig www.lab.local`（不带 `@`）→ 通，**但需要额外一条 `resolvectl domain ens33 lab.local`** |
| 配置上游 DNS | ✅ `no-resolv` + `server=192.168.9.2`，日志 `using nameserver 192.168.9.2#53` |
| **能解释递归查询和转发** | ✅ 见 4.1：客户端要递归（一次问到底），递归服务器干活靠迭代（逐级接力），**dnsmasq 两者都不做，只做转发 + 缓存**；日志里 `forwarded` 就是实证 |
| 防火墙放行 53 | ✅ `53/udp` + `53/tcp`，放行前 `ERROR_TIMEOUT`、放行后立刻成功（因果证据） |
| 缓存生效 | ✅ 同一条命令行连问两次，第二次日志是 `cached`（第一次 `forwarded`） |

**一句话总结（面试可用）：**

> 我用 dnsmasq 起了个内网 DNS：只在 `ens33` 上监听（`bind-dynamic`），`no-resolv` + 显式 `server=` 指向上游避免环路，`local=/lab.test/` 把本地域圈住不转发，`log-queries` 落文件便于排查。系统侧用 `resolvectl dns` 把上游指向它，一条 `dig → 127.0.0.53(resolved) → 127.0.0.1(dnsmasq) → 上游` 的三段链路。中间踩到 `.local` 被 systemd-resolved 判给 mDNS 的坑，靠 `resolvectl domain` 插路由域解决，最终结论是**内网实验域名要用 `.test`/`.internal` 而不是 `.local`**。

---

## 十二、遗留 / 后续

- [ ] `/var/log/dnsmasq.log` **没有 logrotate**，会无限增长 → 留给 [13 备份脚本](13-备份脚本.md) / [15 故障演练](15-故障演练.md) 的"磁盘被日志占满"那一关（可加 `/etc/logrotate.d/dnsmasq`）
- [ ] **未实测** `DNSStubListener=no` 之后 `127.0.0.53` 和 `127.0.0.54` 是否真的都让出来（动手要改 `/etc/systemd/resolved.conf` + 重启 resolved，有短暂断 DNS 的风险，本项跳过了）
- [ ] **未查清** `127.0.0.54:53` 的确切用途（systemd 新版引入的第二个监听地址，与本实验无冲突，未深挖）
- [ ] `--local-service` 的"跨网段静默不答"未实测（需要第二台不同网段的机器，10 项内不具备条件）
- [ ] `resolvectl dns` / `resolvectl domain` 都是**运行时**设置，重启即丢 → 持久化在 [11 静态 IP](11-静态IP.md) 用 netplan 做
- [ ] 泛解析 `address=` 的 NXDOMAIN 失真风险只做了观察（`notexist.wild.lab.test` → `192.168.9.222`），没做生产级讨论
- [ ] 本环境上游把 TTL 压到 5 秒，导致"缓存命中率""DNS 改了不生效"类实验几乎做不了 → 15 故障演练第 5 关要另设计（如用 `hosts` 文件改 / 直接测 resolved 缓存）
- [ ] 未做 dnsmasq 的 **DHCP** 部分（本实验只用了 DNS 功能）
- [ ] 未做**主从/双 DNS 冗余**（单点故障只在第八节演练了现象，没做冗余配置）
