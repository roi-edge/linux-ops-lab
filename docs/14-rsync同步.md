# 14 rsync 同步

> 实验日期：2026-11-10
> 环境：Ubuntu 24.04.5 LTS（`ubuntulearn` / `192.168.9.50`），**rsync 3.2.7（protocol 31）**
> 快照：`lab-14-开始`
> 关联：[13 备份脚本](13-备份脚本.md)（备份产物是天然的同步源）、[02 用户与组-权限-ACL](02-用户与组-权限-ACL.md)（ACL 与 `-A`）、[11 静态 IP](11-静态IP.md)（`192.168.9.50`）

---

## 一、目标与验收

**做：** 本地目录增量同步到另一个目录；加 `--delete` 前先 `--dry-run`

**验收：** 能说清 **`-a` 和 `-avz` 的差别**，以及**什么时候必须加 `--delete`**

**结论：** 达成。核心认知是两条：

1. **`-a` 不等于"全部"** —— 它是 `-rlptgoD`，**不含 `-H`（硬链接）、`-A`（ACL）、`-X`（扩展属性）**。实测：`-a` 同步后硬链接 `%n` 从 2 变 1、ACL 丢失；加 `-HA` 后全部恢复。
2. **`-z` 只作用于传输层** —— 实测 5,000,068 字节的数据，网络上从 **5,001,865 字节降到 1,141 字节**（3808 倍），但落地文件大小**一点没变**（`Literal data` 两次都是 5,000,068）。

---

## 二、最终状态

### 2.1 环境

```bash
# 身份：madrough @ ubuntulearn
madrough@ubuntulearn:~$ rsync --version | head -1
rsync  version 3.2.7  protocol version 31
```

### 2.2 源目录 `/data/rsync-src`（刻意造的"麻烦都有"）

| 文件 | 属性 | 用来验什么 |
|---|---|---|
| `a.txt` | `-rw-rw-r--+`，**硬链接数 2**，**带 ACL `user:alice:r--`** | `-H` 和 `-A` |
| `hard-a` | 与 `a.txt` 同一 inode（`%n=2`） | 硬链接关系 |
| `big.bin` | **5,000,000 字节**，高重复率文本 | `-z` 的压缩效果 |
| `empty.txt` | 0 字节（`: >` 创建） | 空文件 |
| `link-to-a` | 符号链接 → `a.txt`（相对路径） | `-l` |
| `broken-link` | 符号链接 → `/nonexistent/path`（**坏链**） | rsync 不该因此报错 |
| `sub1/` | 权限 **`700`** | `-p` |
| `sub1/old.txt` | mtime **`2020-01-02 03:04`** | `-t` |
| `sub2/empty/` | 空目录 | 目录递归 |

### 2.3 参数结论（本项的"D 日"）

| 用途 | 参数 |
|---|---|
| 日常安全同步 | `rsync -aHAX --numeric-ids` |
| 跨网络再加 | `-z`（仅慢链路 / 可压缩数据） |
| 镜像/备份 | 再加 `--delete`（**必须先 `-n`**） |
| 先演习 | `-n`（`--dry-run`）+ `-i`（`--itemize-changes`） |

---

## 三、操作步骤（按真实顺序）

### 3.1 摸底

```bash
# 身份：madrough @ ubuntulearn（普通用户）
madrough@ubuntulearn:~$ rsync --version | head -2
madrough@ubuntulearn:~$ dpkg -l rsync | tail -1
madrough@ubuntulearn:~$ command -v rsync
```

**实测：`rsync 3.2.7 protocol 31`，包状态 `ii`（已正确安装）。**

### 3.2 造源目录（本项最关键的准备）

```bash
# 身份：madrough @ ubuntulearn（普通用户）
madrough@ubuntulearn:~$ S=/data/rsync-src
madrough@ubuntulearn:~$ rm -rf "$S"; mkdir -p "$S/sub1" "$S/sub2/empty"
madrough@ubuntulearn:~$ echo "hello rsync" > "$S/a.txt"
madrough@ubuntulearn:~$ yes "rsync compressible payload 12345" | head -c 5000000 > "$S/big.bin"
madrough@ubuntulearn:~$ : > "$S/empty.txt"
madrough@ubuntulearn:~$ ln -s a.txt "$S/link-to-a"
madrough@ubuntulearn:~$ ln -s /nonexistent/path "$S/broken-link"
madrough@ubuntulearn:~$ ln "$S/a.txt" "$S/hard-a"
madrough@ubuntulearn:~$ chmod 700 "$S/sub1"
madrough@ubuntulearn:~$ touch -d "2020-01-02 03:04:05" "$S/sub1/old.txt"
madrough@ubuntulearn:~$ setfacl -m u:alice:r "$S/a.txt"
madrough@ubuntulearn:~$ find "$S" -maxdepth 2 -printf '%M %n %u:%g %TY-%Tm-%Td_%TH:%TM %p\n' | sort -k5
```

**为什么造这些**：`-a` 的每个字母对应一种属性，**源目录里没有那种"麻烦"，你就验不出那个字母到底生效没有**。

| 命令 | 作用 |
|---|---|
| `yes "..." \| head -c 5000000 > big.bin` | 造**高重复率**的 5MB 文本 → `-z` 才有戏剧性的压缩比。用 `/dev/urandom` 造随机数据的话 `z` 几乎压不动，**验不出效果** |
| `: > empty.txt` | `:` 是"什么也不做"的内置命令，配重定向 = **创建空文件的标准写法** |
| `ln "$S/a.txt" "$S/hard-a"` | 建**硬链接**（不带 `-s`） |
| `setfacl -m u:alice:r` | 给真实 Linux 用户 `alice` 加 ACL |

**踩坑**：一开始我写的是 `setfacl -m u:lab:r` —— **`lab` 是实验 12 的 MySQL 账号，不是 Linux 用户**，`setfacl` 直接失败、`getfacl` 里什么都没有。数据库用户和系统用户是**两套独立的体系**。

**设置成功后 `ls -l` 的权限串会多一个 `+`**：`-rw-rw-r--+`，`getfacl` 里多出 `user:alice:r--` 和自动生成的 `mask::rw-`。

### 3.3 第一次全量同步

```bash
# 身份：madrough @ ubuntulearn（普通用户）
madrough@ubuntulearn:~$ rm -rf /data/rsync-dst
madrough@ubuntulearn:~$ rsync -av /data/rsync-src/ /data/rsync-dst/
```

**实测：**

```
sending incremental file list
created directory /data/rsync-dst
./
a.txt
big.bin
broken-link -> /nonexistent/path
empty.txt
hard-a
link-to-a -> a.txt
sub1/
sub1/old.txt
sub2/
sub2/empty/

sent 5,001,819 bytes  received 174 bytes  10,003,986.00 bytes/sec
total size is 5,000,046  speedup is 1.00
```

**`speedup is 1.00` = 一个字节都没省**（目标是空的，全量传）。

**同步后逐项比对（这是 `-a` 的"体检报告"）：**

| 检查项 | 源 | 目标 | 结论 |
|---|---|---|---|
| `sub1` 权限 | `drwx------` | `drwx------` | ✅ `p` |
| `old.txt` mtime | `2020-01-02 03:04` | `2020-01-02 03:04` | ✅ `t` |
| `link-to-a` / `broken-link` | `lrwxrwxrwx` | `lrwxrwxrwx` | ✅ `l`（坏链也不报错） |
| **`a.txt` / `hard-a` 的 `%n`** | **2** | **1 / 1** | ❌ **`-a` 不保硬链接** |
| **`getfacl` 的 `user:alice`** | 有 | **没有** | ❌ **`-a` 不保 ACL** |

### 3.4 增量同步（什么都不传）

```bash
# 身份：madrough @ ubuntulearn（普通用户）
madrough@ubuntulearn:~$ rsync -av /data/rsync-src/ /data/rsync-dst/
madrough@ubuntulearn:~$ rsync -a --stats /data/rsync-src/ /data/rsync-dst/ | tail -12
```

**实测：**

```
sending incremental file list
                                          ← 空白，没有文件被处理
sent 354 bytes  received 15 bytes  738.00 bytes/sec
total size is 5,000,046  speedup is 13,550.26

Total transferred file size: 0 bytes
Literal data: 0 bytes
Total bytes sent: 354
```

**354 字节 = 只交换了"文件清单"（名字/大小/mtime），5MB 内容一个字节没动。**

### 3.5 制造差异 + `--dry-run` 看 `--delete` 会删什么

```bash
# 身份：madrough @ ubuntulearn（普通用户）
madrough@ubuntulearn:~$ echo "changed at $(date +%H:%M)" >> /data/rsync-src/a.txt
madrough@ubuntulearn:~$ echo "brand new" > /data/rsync-src/new.txt
madrough@ubuntulearn:~$ rm -f /data/rsync-src/empty.txt
madrough@ubuntulearn:~$ echo "only exists on dst" > /data/rsync-dst/dst-only.txt
madrough@ubuntulearn:~$ rsync -avni --delete /data/rsync-src/ /data/rsync-dst/
```

**实测（itemize 输出）：**

```
*deleting   empty.txt           ← 源里删了，目标要跟着删
*deleting   dst-only.txt        ← 目标端独有（别人放的/上次遗留），也要删
.d..t...... ./                  ← 目录本身的 mtime 变了
>f.st...... a.txt               ← 大小(s)+时间(t) 变了
>f.st...... hard-a              ← ★ 硬链接的连带变化
>f+++++++++ new.txt             ← 新建
```

**`hard-a` 也跟着变**：因为源里 `a.txt` 和 `hard-a` **是同一个 inode**，对 `a.txt` 追加内容，`hard-a` 的大小和 mtime 必然一起变。而目标端它们是两个独立文件，所以两个都得重传。**这一行是"硬链接是两个入口一份数据"的直接证据。**

### 3.6 真正执行 + 幂等验证

```bash
# 身份：madrough @ ubuntulearn（普通用户）
madrough@ubuntulearn:~$ rsync -av --delete /data/rsync-src/ /data/rsync-dst/
madrough@ubuntulearn:~$ rsync -avni --delete /data/rsync-src/ /data/rsync-dst/
```

**实测第一次：**

```
deleting empty.txt
deleting dst-only.txt
./
a.txt
hard-a
new.txt
sent 556 bytes  received 115 bytes
```

**实测第二次（幂等验证）：完全空白。**

> **"跑一次就收敛"是 rsync 配置正确的标志。** 如果反复跑都在报 `>f.xxx` 或 `*deleting`，说明有东西永远对不上（典型：`-a` 想改属主但你不是 root、两边 umask 影响权限、时间精度问题）。

### 3.7 `-a` vs `-avz` 实测（走 SSH，真实客户端/服务端）

```bash
# 身份：madrough @ ubuntulearn（普通用户，会问密码）
madrough@ubuntulearn:~$ rsync -av -e ssh --stats /data/rsync-src/ madrough@192.168.9.50:/data/rsync-nz/ 2>&1 | tail -12
madrough@ubuntulearn:~$ rsync -avz -e ssh --stats /data/rsync-src/ madrough@192.168.9.50:/data/rsync-z/ 2>&1 | tail -12
```

**实测对比：**

| 字段 | 不带 `z` | 带 `z` |
|---|---|---|
| `Total file size` | 5,000,090 | 5,000,090 |
| `Total transferred file size` | 5,000,068 | 5,000,068 |
| **`Literal data`** | **5,000,068** | **5,000,068** |
| **`Total bytes sent`** | **5,001,865** | **1,141** |
| `speedup` | 1.00 | **3,808.14** |

**两个关键读数：**

| 读数 | 说明 |
|---|---|
| **`Literal data` 两次相同** | **`-z` 没有改变"要传哪些数据"的判断**，只改变了"这些数据怎么发出去" |
| **`Total bytes sent` 差 4384 倍** | 这就是压缩在传输层的全部作用 |

**为什么能压这么狠**：`big.bin` 是同一行 30 字节文本重复 16 万次，zlib 的滑动窗口几乎把它压成"一行 + 重复次数"。

**为什么必须走 SSH 才能验**：本地 rsync 默认 `--whole-file`（走内存/管道，不做 delta、`-z` 收益极小）。**`-z` 的意义只在"网络链路"这个前提成立时才有。**

### 3.8 补上 `-H` 和 `-A`（闭环）

```bash
# 身份：madrough @ ubuntulearn（普通用户）
madrough@ubuntulearn:~$ rm -rf /data/rsync-dst3
madrough@ubuntulearn:~$ rsync -avHA /data/rsync-src/ /data/rsync-dst3/
madrough@ubuntulearn:~$ find /data/rsync-dst3 -maxdepth 1 -printf '%M %n %p\n' | sort -k3
madrough@ubuntulearn:~$ getfacl -p /data/rsync-dst3/a.txt
```

**实测：**

```
...
sub2/empty/
a.txt => hard-a          ← ★ rsync 说"我不复制，给 a.txt 建个硬链接"
sent 5,001,822 bytes

-rw-rw-r-- 2 /data/rsync-dst3/a.txt      ← %n = 2
-rw-rw-r-- 2 /data/rsync-dst3/hard-a     ← %n = 2
       ← getfacl 里有 user:alice:r-- 和 mask::rw-
```

**`a.txt => hard-a` 这一行就是 `-H` 在工作**：它不再写一份新数据，而是把 `hard-a` 做成指向 `a.txt` 的硬链接。

---

## 四、原理

### 4.1 `-a` 到底是哪七个字母

```
-a  =  -r  -l  -p  -t  -g  -o  -D
        │   │   │   │   │   │   └─ --devices --specials  设备文件 + 特殊文件
        │   │   │   │   │   └───── --owner               属主（需 root 才真能改）
        │   │   │   │   └───────── --group               属组
        │   │   │   └───────────── --times               修改时间
        │   │   └───────────────── --perms               权限
        │   └───────────────────── --links               符号链接（当链接复制）
        └───────────────────────── --recursive           递归
```

**`-a` 之外还需要什么：**

| 缺什么 | 参数 | 什么时候必须 |
|---|---|---|
| 硬链接 | **`-H`** | 目标端要保持"一份数据多个名字"（省空间 + 保持一致性） |
| **ACL** | **`-A`** | 目录上有 ACL（实验 02 的 `/srv/shared` 就是） |
| 扩展属性 | `-X` | SELinux 标签、`capabilities`、自定义 xattr |
| 稀疏文件 | `-S` | 虚拟机镜像、数据库大文件（不保会把稀疏区全写实，体积暴涨） |
| 按内容校验 | `-c` | 怀疑"大小和时间都一样但内容不同" |

### 4.2 rsync 凭什么判断"要不要传"

**默认的快速检查（quick check）：**

| 条件 | 判断 |
|---|---|
| 文件大小**相同** 且 mtime **相同**（精确到秒） | **跳过** |
| 任一不同 | 认为需要更新 → 进入传输流程 |

**这就是两个经典陷阱的来源：**

| 现象 | 原因 | 解法 |
|---|---|---|
| 内容改了但**大小和时间都没变** | 快速检查通过 → 跳过 | **`-c`（`--checksum`）**：读全文算校验和，慢但准 |
| 只 `touch` 了一下（内容没变） | 时间不同 → 视为要更新 → 重传 | 无法完全避免；`-c` 也会"因为校验和相同而跳过"，但代价是读全文 |

### 4.3 delta 算法（rsync 的灵魂）

传输一个已存在的文件时，rsync 不是"整份重传"：

```
① 接收端把旧文件切成固定大小的块，对每块算两种校验和（弱滚动 + 强 MD5）
② 把这些校验和发给发送端
③ 发送端在新文件上滑动窗口，用弱校验快速找匹配
④ 匹配上的块只发"块号"（Matched data），没匹配上的发原始字节（Literal data）
⑤ 接收端按指令重组：复制旧块 + 插入新字节
```

**效果**：改一个大文件里的几行，**网络上只传改动的部分**。

**`--stats` 里对应的两个字段：**

| 字段 | 含义 |
|---|---|
| `Literal data` | 真正当"新数据"发出去的字节 |
| **`Matched data`** | 通过块匹配**复用的旧数据字节**（不用发） |

**但本地传输默认不走 delta**（`--whole-file`），因为本地读写比"算校验和"更快。要强制走 delta 加 `--no-whole-file`。

### 4.4 `--delete` 的三层语义

| 写法 | 删除时机 | 特点 |
|---|---|---|
| `--delete`（默认） | **传输过程中记录，结束后删** | 最安全：中途断了不会"删了没补上" |
| `--delete-before` | 传输**前**先删 | 先腾空间（目标盘紧张时用），但中断后目标处于"缺文件"状态 |
| `--delete-during` | 边传边删 | 快，但中断时两边都不完整 |
| `--delete-delay` | 传输中记录，最后删 | 兼顾空间与安全（和默认接近） |
| `--delete-excluded` | 连 `--exclude` 排除的也删 | **危险**：你排除的"目标端保留物"也会被清掉 |

**`--delete` 删的是"目标端所有源里没有的东西"** —— 包括别人手工放的、上次遗留的、误放的。**这就是必须先 `-n` 的原因。**

### 4.5 源路径末尾的 `/`（最经典的坑）

| 写法 | 结果 |
|---|---|
| `rsync -a src/ dst/` | 把 **src 里的内容**放进 dst → `dst/a.txt` |
| `rsync -a src  dst/` | 把 **src 目录本身**放进 dst → `dst/src/a.txt` |

**一个斜杠，结果完全不同。** 用 `-n` 先看一遍就能发现。

### 4.6 `-z` 与 `--skip-compress`

| 项 | 说明 |
|---|---|
| `-z` / `--compress` | 传输时 zlib 压缩 |
| `--compress-level=N` | 0（不压）~ 9（最高） |
| `--skip-compress=LIST` | 对已压缩的扩展名**跳过压缩**（默认就跳过一些，如 `jpg/png/mp4/zip/gz`） |

**判据**：`压缩节省的字节 × 单位带宽成本 > CPU 时间 × 单位算力成本`。带宽便宜、CPU 紧张 → 不压；带宽贵（跨公网/4G）→ 压。

---

## 五、生产实践（实际工作中的正确做法）

### 5.1 最常用的四种用法

| 场景 | 命令 |
|---|---|
| **备份到另一台机** | `rsync -aHAX --numeric-ids --delete -e ssh src/ backup@host:/data/bak/` |
| **发布代码** | `rsync -az --delete --exclude-from=exclude.txt ./ user@web:/var/www/app/` |
| **本机镜像** | `rsync -aHAX --delete src/ dst/` |
| **增量快照（硬链接）** | `rsync -aHAX --link-dest=/bak/last src/ /bak/2026-11-10/` |

**`--link-dest` 是"时间机器"式备份的核心**：新备份里**没有变化的文件直接做成硬链接**指向上一份 → **每份备份看起来都是全量，但磁盘只占一份**。适合"每天一个快照，保留 30 天"。

### 5.2 `--numeric-ids`：跨机器必加

| 不加 | 加了 |
|---|---|
| rsync 按**用户名/组名**映射属主 | 直接按 **UID/GID 数字**复制 |
| 两台机器用户表不一致时，**属主会变成另一个人**（甚至变成 root） | 属主数字原样保留（前提：目标端 UID/GID 含义一致） |

**这是最隐蔽的坑之一**：同步完成后 `ls -l` 显示的名字看着"正常"，但其实是**同一个数字对应了不同的人**。

### 5.3 限速与断点续传

| 场景 | 参数 |
|---|---|
| 别把带宽打满 | `--bwlimit=10m`（10 MB/s） |
| 大文件断了要续 | `--partial --append-verify` |
| 传输大文件时减少磁盘 IO | `--inplace`（原地写，慎用：中断会损坏目标文件） |

### 5.4 cron 里跑 rsync：必须先解决免密

`cron` 没有交互终端，**密码提示会让任务永久挂住**。所以必须：

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519     # 无密码短语（cron 场景）
ssh-copy-id madrough@192.168.9.50
ssh -o BatchMode=yes madrough@192.168.9.50 true      # 验证免密可行
```

**`-o BatchMode=yes`** 是验证手段：**如果还需要密码，它会立刻失败而不是等待**（这样 cron 里不会挂死）。

### 5.5 退出码：0 才是成功，但 24 通常可接受

| 码 | 含义 | cron 里怎么处理 |
|---|---|---|
| **0** | 成功 | ✅ |
| 23 | 部分文件因错误未传（如权限不足） | ⚠️ 告警 |
| **24** | **传输期间源文件消失了**（`--delete` 场景常见） | ✅ **通常当成成功**（日志类不断写入，文件消失是正常的） |
| 25 | 达到 `--max-delete` 上限 | ⚠️ 说明要删的太多，检查是不是目标路径写错了 |
| 30 / 35 | 数据传输/连接超时 | ⚠️ 告警 |

**脚本里必须显式判断**，别用 `&&` 一刀切：

```bash
rsync ... ; rc=$?
case $rc in
  0|24) log "OK" ;;
  *)    log "FAIL rc=$rc"; exit 1 ;;
esac
```

### 5.6 `--itemize-changes` 当作审计日志

```bash
rsync -aHAX --delete --itemize-changes --out-format='%i %n%L' src/ dst/ >> /var/log/rsync.log 2>&1
```

**`%i` = itemize 码，`%n` = 文件名，`%L` = 链接目标。** 每天一条日志，出问题时能回答"那天到底动了哪些文件"。

### 5.7 排除清单用文件维护

```bash
rsync -a --delete --exclude-from=/etc/rsync-exclude.txt src/ dst/
```

```
# /etc/rsync-exclude.txt
*.log
*.tmp
cache/
node_modules/
.git/
```

**规则顺序有意义**（先匹配先赢），且 `--exclude` 后加 `--delete` 时，**被排除的东西默认不会被删**（除非加 `--delete-excluded`）—— 这个默认行为是"安全"的。

### 5.8 别用 root 到处跑

| 风险 | 说明 |
|---|---|
| root + `--delete` + 写错目标路径 | **可以删掉 `/etc`** |
| 建议 | 用普通用户 + `sudo` 只提权需要的部分；或 `--fake-super` 让非 root 也能记录属主 |

**`-a` 里的 `-o`（属主）普通用户改不了**，所以"想完整保留属主"经常被迫用 root —— **这时候更要用 `-n` + 明确路径**。

### 5.9 常见误区小结

| 误区 | 事实 |
|---|---|
| `-avz` 是"最好的参数" | `z` 只在慢链路有用；`-a` 缺 `-H/-A/-X` |
| rsync 会"同步删除" | **不会**，除非加 `--delete` |
| rsync 是"备份软件" | 它是**同步工具**，没有版本、没有保留策略；做备份要配 `--link-dest` 或上层脚本 |
| `--delete` 有回收站 | **没有**，删了就没了 |
| 目标端比源端多文件说明同步失败 | 不一定，是"没加 `--delete`" |

---

## 六、踩坑清单

| # | 坑 | 说明 / 正确做法 |
|---|---|---|
| 1 | 源路径末尾 `/` 写错 | `src/` = 内容；`src` = 目录本身。**一个斜杠决定 `dst/a.txt` 还是 `dst/src/a.txt`** |
| 2 | 以为 `-a` 是"全部" | `-a` = `-rlptgoD`，**不保硬链接（`-H`）、ACL（`-A`）、xattr（`-X`）**。本次实测 `%n` 2→1、ACL 丢失 |
| 3 | 加 `--delete` 前不做 `-n` | `--delete` 会删"目标端所有源里没有的东西"，**没有回收站**。永远先 `-avni` 看清单 |
| 4 | `-z` 加在本机/局域网同步上 | 纯浪费 CPU。`-z` 只在**慢链路 + 可压缩数据**时有意义 |
| 5 | 以为 `-z` 会让目标文件变小 | **不会**。`Literal data` 两次相同就是证据：压缩只在传输层 |
| 6 | 用随机数据测 `-z` | `/dev/urandom` 压不动，看不出效果。要用**高重复率文本**（`yes ... \| head -c`） |
| 7 | 用本机同步测 `-z` 或 delta | 本地默认 `--whole-file`，不走 delta。要验必须**走 ssh** 或加 `--no-whole-file` |
| 8 | 内容改了但大小时间没变 → 不同步 | 快速检查只看 size+mtime。用 `-c` 按校验和 |
| 9 | `setfacl -m u:lab:r` | `lab` 是**MySQL 用户**，不是 Linux 用户 → setfacl 静默失败。要用真实系统用户（`alice`） |
| 10 | 跨机同步不写 `--numeric-ids` | 按用户名映射属主，两机用户表不一致时**属主变错人** |
| 11 | cron 里跑 rsync 没配免密 | 密码提示会让任务**永久挂住**。用 `ssh-keygen` + `ssh-copy-id`，并用 `-o BatchMode=yes` 验证 |
| 12 | 用 `&&` 判断 rsync 成功 | 退出码 **24（源文件传输中消失）通常可接受**，`23/25/30` 才是真问题。要 `case` 分支 |
| 13 | 反复跑都报差异 | 说明有永不收敛的东西（属主改不了、时间精度、权限）。**"跑一次就空"才是配置正确** |
| 14 | 单独用 rsync 当备份 | 它没有版本/保留策略。备份要配 `--link-dest` 快照或上层脚本（实验 13 那套） |
| 15 | `--delete-excluded` 随手加 | 会把"你特意排除、想让目标端保留"的东西也删掉 |

---

## 七、命令详解（本项首次出现）

### 7.1 rsync 参数

| 参数 | 是什么 → 干什么 → 为什么这里用 |
|---|---|
| `-a` / `--archive` | `-rlptgoD` 的缩写 → 保属性 |
| `-v` / `--verbose` | 列出处理的每个文件 → 没有它看不到"动了什么" |
| **`-n` / `--dry-run`** | 只演习、不写盘 → **`--delete` 前的必经步骤** |
| **`-i` / `--itemize-changes`** | 每行 11 字符状态码 → 精确看出"改的是大小还是时间还是权限" |
| `-z` / `--compress` | 传输时 zlib 压缩 → 只减少网络字节，不改文件 |
| `-H` / `--hard-links` | 保留硬链接 → 目标端仍是"一份数据多个名字" |
| `-A` / `--acls` | 保留 ACL（隐含 `-p`） | 
| `-X` / `--xattrs` | 保留扩展属性 |
| `-S` / `--sparse` | 保留稀疏文件（不把空洞写成实数据） |
| `-c` / `--checksum` | **按内容校验**而不是 size+mtime → 慢但准 |
| `--delete` | 删除目标端"源里没有"的文件 → 镜像必备，**危险** |
| `--delete-excluded` | 连被 exclude 的也删 → **慎用** |
| `--exclude=` / `--include=` | 按模式排除/包含 |
| `--exclude-from=FILE` | 从文件读排除清单 → 生产维护排除项的标准做法 |
| `--numeric-ids` | 用 UID/GID 数字而不是名字 → **跨机必加** |
| `--stats` | 打印统计（`Literal data`/`Matched data`/`bytes sent`）→ 验证增量与压缩效果 |
| `--bwlimit=RATE` | 限速 → 别把生产带宽打满 |
| `--partial` / `--append-verify` | 断点续传 |
| `--inplace` | 原地写目标文件（省磁盘，但中断会损坏目标） |
| `--link-dest=DIR` | 未变化的文件做成指向 `DIR` 的**硬链接** → 增量快照 |
| `--out-format=` | 自定义每行输出（`%i` 状态码 / `%n` 文件名 / `%L` 链接目标） |
| `-e ssh` | 用 ssh 作为远程 shell → rsync over ssh |
| `--no-whole-file` | 强制走 delta 算法（本地传输默认不走） |

### 7.2 itemize 状态码（11 位）

| 位 | 含义 |
|---|---|
| 1 `Y` | 更新类型：`>` 传给目标 / `<` 传回源 / `c` 创建 / `h` 硬链接 / `.` 不变 / `*` 消息（如 `deleting`） |
| 2 `X` | 类型：`f` 文件 / `d` 目录 / `L` 符号链接 / `D` 设备 / `S` 特殊 |
| 3 `c` | 内容/校验和变化 |
| 4 `s` | 大小变化 |
| 5 `t` | 时间变化 |
| 6 `p` | 权限变化 |
| 7 `o` | 属主变化 |
| 8 `g` | 属组变化 |
| 9 `u` | 保留位 |
| 10 `a` | ACL 变化 |
| 11 `x` | 扩展属性变化 |
| 特例 | `+` = 新建（`>f+++++++++`） |

### 7.3 造测试素材用到的

| 命令 | 是什么 → 干什么 |
|---|---|
| `yes "文本" \| head -c N > f` | 生成**高重复率**的 N 字节文件 → 测压缩 |
| `: > f` | 创建空文件（`:` 是内置空命令） |
| `ln f1 f2` | 建**硬链接**（同 inode） |
| `ln -s target name` | 建**符号链接** |
| `touch -d "2020-01-02 03:04:05" f` | 指定 mtime → 测 `-t` |
| `setfacl -m u:alice:r f` | 给用户加 ACL 条目 → 测 `-A`（`ls -l` 会出现 `+`） |
| `getfacl -p f` | 打印 ACL（`-p` 不省略路径前缀） |
| `find -printf '%M %n %u:%g %TY-%Tm-%Td %p'` | 一次性输出**权限/硬链接数/属主/时间/路径** → 对比源和目标的体检报表 |

---

## 八、验收记录

| 验收项 | 结果 |
|---|---|
| 本地目录增量同步到另一个目录 | ✅ 首次 `sent 5,001,819`；第二次 `Total transferred file size: 0`、`sent 354`（只发文件清单） |
| **加 `--delete` 前先 `--dry-run`** | ✅ `-avni --delete` 预告了 `*deleting empty.txt`、`*deleting dst-only.txt`、`>f.st a.txt`、`>f.st hard-a`、`>f+++++++++ new.txt`；确认后才去掉 `-n` 执行；最后再跑 `-n` **完全空白（幂等）** |
| **说清 `-a` 和 `-avz` 的差别** | ✅ `-a` = `-rlptgoD`（不含 `-H/-A/-X`）；`-z` 只压缩**传输层**。实测同一份 5,000,068 字节数据：网络发送 **5,001,865 → 1,141 字节**（3808 倍），而 `Literal data` 两次都是 5,000,068、目标文件大小不变 |
| **说清什么时候必须加 `--delete`** | ✅ 目标端角色是**镜像/备份**时（否则源端删掉的文件永久残留，目标变成"历史垃圾场"）；**归档/保留历史**时不能加 |
| 硬链接与 ACL 的实际差异 | ✅ `-a` 后 `%n` 2→1、ACL 丢失；`-aHA` 后 `%n=2`、`a.txt => hard-a`、ACL 完整 |

**面试可用的一句话总结：**

> 我用 rsync 做了目录同步和镜像：`-a` 其实是 `-rlptgoD`，不含硬链接和 ACL，所以生产规范是 `-aHAX --numeric-ids`；`-z` 只压传输层，我实测同一份数据网络字节能从 5MB 降到 1KB，但落地文件不变，所以局域网不加、跨公网才加。加 `--delete` 之前一定先 `-n -i` 看清单，因为它删的是"目标端所有源里没有的东西"，包括别人放的、没有回收站；执行完再跑一次 `-n`，输出为空才说明收敛。

---

## 九、遗留 / 后续

- [ ] 未测 **`--link-dest` 增量快照**（生产里"每天一份全量但只占一份磁盘"的核心手法）→ 可以放在实验 15/27 里补
- [ ] 未测 **`--bwlimit` 限速** 的实际效果
- [ ] 未测 **`-S`（稀疏文件）** 与 **`-X`（扩展属性）**
- [ ] 未配 **SSH 免密**（`ssh-keygen` + `ssh-copy-id`），所以本项 ssh 同步是手工输密码的 → **cron 里跑必须解决**，可留给实验 20 Ansible
- [ ] 未做 **rsync daemon 模式**（`rsyncd.conf` + 873 端口），生产里有用但非必需
- [ ] 未做 **`-c`（checksum）与默认快速检查的对照实验**
- [ ] 未做 **中断续传**（`--partial`）的演示
- [ ] `/data/rsync-src` 和 `/data/rsync-dst` 留作素材未删（各约 5MB）
- [ ] 未测**跨文件系统/跨机器大量小文件**的性能差异（`--delete` + 百万小文件是真实痛点）
