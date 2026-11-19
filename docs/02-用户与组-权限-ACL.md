# 02 用户 / 组 / 权限 / ACL

> 实验日期：2026-10-28
> 环境：Ubuntu 24.04.5 LTS（`ubuntulearn` / `192.168.9.128`），全部操作经 SSH 会话完成
> 快照：`lab-02-开始`

---

## 一、目标与验收

**做：**

- 建 3 个用户、2 个组
- 建一个共享目录，要求「同组可读写，其他人只读」
- 再用 ACL 给某个单独特权（`setfacl`）

**验收：**

- 能解释 `rwx` 对**目录**和**文件**含义的区别
- 能说清 `umask` 是怎么算出来的

**本次结论：** 两项口头验收均通过（见第一节末的问答记录）。

---

## 二、最终成果

```
用户 / 组：
  alice  → 附加组 devs
  bob    → 附加组 devs
  carol  → 附加组 ops，另通过 ACL 获得 /srv/shared 的 rwx

目录：
  /srv/shared        drwxrwsr-x+  root devs    ← 775 + SGID + ACL
    default ACL      user:carol:rwx（新建子项自动继承）
```

**验证一个共享目录是否配好，看三样：**

```bash
ls -ld /srv/shared       # 期望 drwxrwsr-x+ root devs
getfacl /srv/shared      # 期望有 user:carol:rwx 和 default: 五行
getent group devs        # 期望 devs:x:GID:alice,bob
```

`ls -l` 里两个符号必须会看：

| 符号 | 含义 |
|---|---|
| 属组位上的 `s` | SGID 已设（该是 `x` 的位置变成 `s`）；大写 `S` 表示组无 `x`，是配置错误 |
| 末尾的 `+` | 该目录/文件带 ACL 规则 |

---

## 三、用户与组的基本概念

### 3.1 主组 vs 附加组

| | 主组（primary group） | 附加组（supplementary） |
|---|---|---|
| 数量 | 每人**只能一个** | 可以多个 |
| 存在字段 | `/etc/passwd` 第 4 字段 | `/etc/group` 第 4 字段（成员列表） |
| 作用 | 新建文件时**默认的属组** | 额外获得该组的资源访问权 |
| 查看 | `id` 输出里 `gid=` 后面那个 | `id` 输出里 `groups=` 列表，带组名的 |

**Ubuntu 默认给每个用户建一个同名私有组**（`USERGROUPS_ENAB yes`），所以：

```bash
id alice
# uid=1002(alice) gid=1004(alice) groups=1004(alice),1002(devs)
#                 ^^^^^^^^^^^ 主组是 alice       ^^^^^^^^^ 附加组是 devs
```

业务组（devs / ops）挂在**附加组**上，这是正常现象，不是没配对。

### 3.2 UID / GID

- `0` = root
- `1–999` = 系统账号（服务用，不该登录）
- `1000+` = 普通用户
- `65534` = `nobody`

查普通用户的命令（`awk -F:` 按冒号切字段，`$3` 是 UID）：

```bash
getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1, $3}'
getent group  | awk -F: '$3 >= 1000 && $3 < 65534 {print $1, $3, $4}'
```

---

## 四、操作步骤

> **约定：每个命令块都标注执行身份。** 这是本次实验最大的一条教训——`sudo` 命令如果敲在错误身份下，会 `Operation not permitted`，但很容易被忽略然后一路错下去。

### 4.1 建组

```bash
# 身份：madrough
madrough@ubuntulearn:~$ sudo groupadd devs
madrough@ubuntulearn:~$ sudo groupadd ops
```

Linux 惯例：成功不输出。

### 4.2 建用户

```bash
# 身份：madrough
madrough@ubuntulearn:~$ sudo useradd -m -s /bin/bash -G devs alice
madrough@ubuntulearn:~$ sudo useradd -m -s /bin/bash -G devs bob
madrough@ubuntulearn:~$ sudo useradd -m -s /bin/bash -G ops  carol
```

| 参数 | 作用 | 不加的后果 |
|---|---|---|
| `-m` | 创建家目录 `/home/用户` | 无家目录，登录后没有 `~` |
| `-s /bin/bash` | 指定登录 shell | 可能是 `/bin/sh` 甚至 `nologin`，登不进去 |
| `-G devs` | 加入附加组 | 不在任何业务组 |

**`-G` 在这里不需要 `-a`**：新用户还没有任何附加组，不存在被覆盖的问题。`-a` 是给**已有用户追加**组时才必须的（`usermod -aG`）。

### 4.3 设密码

`useradd` 不设密码，账号默认锁定：

```bash
# 身份：madrough
madrough@ubuntulearn:~$ echo 'alice:<LAB_PASSWORD>' | sudo chpasswd
madrough@ubuntulearn:~$ echo 'bob:<LAB_PASSWORD>'   | sudo chpasswd
madrough@ubuntulearn:~$ echo 'carol:<LAB_PASSWORD>' | sudo chpasswd
```

> 密码会留在 shell 历史里。Ubuntu 默认 `HISTCONTROL=ignoreboth`，命令前加一个空格即可不被记录。

### 4.4 验证用户与组

```bash
# 身份：madrough
madrough@ubuntulearn:~$ id alice
madrough@ubuntulearn:~$ id bob
madrough@ubuntulearn:~$ id carol
madrough@ubuntulearn:~$ getent group devs ops
```

要确认：alice/bob 的 `groups=` 里有 `devs`，carol 有 `ops`，UID 各不相同且 ≥1002。

### 4.5 建共享目录

```bash
# 身份：madrough
madrough@ubuntulearn:~$ sudo mkdir -p /srv/shared
madrough@ubuntulearn:~$ sudo chown root:devs /srv/shared
madrough@ubuntulearn:~$ sudo chmod 2775 /srv/shared
```

**为什么属主是 root 而不是 alice/madrough**：共享目录属于"组织"而非个人，属主为 root 则无人能随手改其权限，真正的访问控制交给属组 `devs`。

**`2775` 拆解：**

| 位 | 数值 | 权限 | 对目录的效果 |
|---|---|---|---|
| 属主 | 7 | `rwx` | 列目录、进入、增删 |
| 属组 | 7 | `rwx` | 同上 → **同组可读写** |
| 其他人 | 5 | `r-x` | 能看能进、不能增删 → **其他人只读** |
| 特殊位 | 2 | **SGID** | 内部新建条目自动继承 `devs` 组 |

### 4.6 用 ACL 给 carol 单独开权限

```bash
# 身份：madrough
madrough@ubuntulearn:~$ which setfacl              # 没有则下面这条装包
madrough@ubuntulearn:~$ sudo apt install -y acl
madrough@ubuntulearn:~$ sudo setfacl -m u:carol:rwx /srv/shared
```

- `-m` = modify，新增/修改一条规则
- `u:carol:rwx` = 给用户 carol 授予 rwx
- carol 在 `ops` 组、不在 `devs`，按 `775` 只能算"其他人"（`r-x`），ACL 就是给单个用户开例外口子，优先级高于普通三位权限

### 4.7 设默认 ACL（关键，否则 ACL 不继承）

```bash
# 身份：madrough
madrough@ubuntulearn:~$ sudo setfacl -d -m u:carol:rwx /srv/shared
madrough@ubuntulearn:~$ getfacl /srv/shared
```

期望出现 5 行 `default:`：

```
default:user::rwx
default:user:carol:rwx
default:group::rwx
default:mask::rwx
default:other::r-x
```

**`-d` = default ACL，只对"今后新建"的子项生效，对已存在的目录无效。** 想让已存在的子目录拿到规则，只能删掉重建，或单独给那个子目录补一条。

---

## 五、实测记录（验收证据）

| # | 身份 | 操作 | 结果 |
|---|---|---|---|
| 1 | alice | `echo "written by alice" > /srv/shared/alice.txt` | 成功；`-rw-rw-r-- alice devs`（属组是 `devs` → SGID 生效） |
| 2 | bob | `echo "bob was here" >> /srv/shared/alice.txt` | **成功**（umask 为 002，文件是 664，组可写） |
| 3 | carol | `echo "carol via acl" > /srv/shared/carol.txt` | 成功；`-rw-rw-r-- carol devs`（ACL 给了她写权限） |
| 4 | student | `echo ... > /srv/shared/student.txt` | **失败** `Permission denied` → "其他人只读"成立 |
| 5 | student | `cat /srv/shared/alice.txt` | 成功 → 只读的"读"成立 |
| 6 | alice | `mkdir /srv/shared/subdir` | 子目录属组 `devs`、位上有 `s` → SGID 对目录也生效 |
| 7 | carol | 写入旧 `subdir/`（默认 ACL 未设时） | **失败** `Permission denied` → 证明 ACL 不自动继承 |
| 8 | carol | 设默认 ACL 并重建 `subdir` 后写入 | 成功 → 默认 ACL 继承生效 |

**第 4 项与第 1 项合起来，才完整证明"同组可读写、其他人只读"。**

---

## 六、原理笔记

### 6.1 `rwx` 对目录和文件的区别（核心）

| 位 | 对**文件** | 对**目录** |
|---|---|---|
| `r` | 读取文件**内容** | 读取**名字列表**（`ls` 能列出文件名） |
| `w` | 修改文件**内容** | 修改**目录项**：创建、删除、重命名里面的条目 |
| `x` | 可执行（程序/脚本） | **穿越/检索**：`cd` 进入、访问里面的文件 |

**三个反直觉但必须记住的点：**

1. **删不删看目录，不看文件。** 只要你对目录有 `w`+`x`，即使文件是 `444`，照样能 `rm`。删的是"目录里的那个名字"，跟文件本体无关。
2. **目录的 `w` 必须配合 `x`。** 只有 `w` 没 `x`，实际上什么也增删不了。
3. **文件名只是指针，读文件要求路径上每一级目录都有 `x`。** 所以 `r--` 的目录能 `ls` 看到名字，但 `cat`/`cd` 全部失败——"看得见摸不着"。

**目录权限四种组合：**

| 权限 | 能做什么 |
|---|---|
| `r-x` | `ls`、`cd`、读写里面的文件——正常公共目录 |
| `r--` | 只能 `ls` 看名字，`cd`/`cat` 全失败 |
| `--x` | 能 `cd` 到已知路径、访问已知文件名，但不能 `ls` 列目录 |
| `---` | 完全进不去 |

**区分两类 `w`/`x` 的唯一依据是 `ls -l` 第一位有没有 `d`。**

### 6.2 umask 的计算

**基础权限**（内核新建时的满配）：

- 目录 = `777`
- 文件 = `666`（文件天生无 `x`，防止新建文件意外可执行）

**公式**（按位清除，不是减法）：

```
最终权限 = 基础权限 & (~umask)
```

**本机实测 umask = `0002`：**

```
目录：777 & ~002 = 775  → drwxrwxr-x
文件：666 & ~002 = 664  → -rw-rw-r--
```

**为什么普通用户是 0002、root 是 0022：** Debian/Ubuntu 通过 PAM 的 `pam_umask` 模块 + `/etc/login.defs` 的 `USERGROUPS_ENAB yes` 实现——普通用户有私有组，给 `002` 让"同组协作"开箱可用；root 给 `022`。

| 身份 | umask | 新建文件 | 新建目录 |
|---|---|---|---|
| 普通用户 | `002` | `664` | `775` |
| root | `022` | `644` | `755` |

对照 `022`：

```
目录 777 & ~022 = 755 → drwxr-xr-x
文件 666 & ~022 = 644 → -rw-r--r--
```

> 面试话术：umask 是"屏蔽位"，用按位清除生效，不是从 777 里做减法。

### 6.3 SGID（`2xxx`）

- 作用在**目录**上：里面新建的文件/子目录，**属组继承该目录的属组**，而不是创建者的主组
- 为什么共享目录必须有它：否则 alice 建的文件属组是 `alice`，bob 写不了，共享目录形同虚设
- `ls -l` 表现为属组位的 `s`；大写 `S` = 组没有 `x`，属配置错误

### 6.4 Sticky 位（`1xxx`，补充知识）

目录加 sticky（如 `3775`，典型是 `/tmp` 的 `1777`）：谁都能建文件，但**只有属主和 root 能删自己的文件**。共享目录要不要加，取决于是否信任组内成员。

### 6.5 ACL 与 ACL mask（本次踩到的坑）

目录一旦有 ACL，`ls -l` 里那三位**属组权限显示的不再是 `group::` 的真实值，而是 mask**。

而 `chmod g±w` 改的正好就是 **mask**。实测过程：

```bash
# 身份：madrough
madrough@ubuntulearn:~$ sudo chmod g-w /srv/shared
madrough@ubuntulearn:~$ getfacl /srv/shared
```

结果：

```
user:carol:rwx           #effective:r-x     ← 规则一个字没改
group::rwx               #effective:r-x
mask::r-x                                  ← 被 chmod 改掉了
```

此时 carol 写入 → `Permission denied`。执行 `chmod g+w` 后 `mask::rwx` 恢复，carol 又能写了。

**结论：**

- `chmod` 老命令不认识 ACL，只能改 mask
- mask 是所有 ACL 条目（属主和 other 之外）的**上限**
- ACL 规则本身没变，但被 mask 削掉后 `#effective:` 会显示实际生效值
- **面试问题「ACL 和 chmod 会冲突吗」→ 就答 mask 这一套**

---

## 七、踩坑清单

| # | 坑 | 正确做法 |
|---|---|---|
| 1 | `setfacl` 在错误身份下执行，报 `Operation not permitted` 被忽略 | `/srv/shared` 属主是 root，必须 `sudo`，且要在有 sudo 的身份（madrough）下执行 |
| 2 | 以为 `setfacl -m` 会自动往下继承 | ACL **不继承**；要新建子项也带规则必须 `setfacl -d`（default ACL） |
| 3 | 给已存在的子目录设了 `-d` 却发现没生效 | `-d` 只管今后新建的；已存在的要删掉重建或单独补规则 |
| 4 | 以为普通用户 umask 是 `022` | Ubuntu 普通用户是 `002`（私有组 + pam_umask），root 才是 `022` |
| 5 | 目录设了组可写，同组却改不了别人的文件 | 目录权限管"建/删"，文件权限管"改内容"，两码事 |
| 6 | `chmod` 后 ACL 权限莫名消失 | `chmod` 改的是 mask，会削掉 ACL 生效值 |
| 7 | `drwxrwsr-x` 里的 `s` 看成拼写错误 | 属组位的 `s` = SGID，正常 |
| 8 | 以为 `ls` 末尾的 `+` 无所谓 | `+` = 有 ACL，看到它就该同时看 `getfacl` |
| 9 | 共享目录忘设 SGID | 文件属组会变成创建者私有组，组内协作失效 |
| 10 | 用 `useradd` 忘了 `-m -s` | 家目录缺失、shell 可能是 `nologin` |

---

## 八、命令速查

```bash
# 用户与组
getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1, $3}'   # 普通用户
getent group  | awk -F: '$3 >= 1000 && $3 < 65534 {print $1, $3, $4}'
sudo groupadd devs
sudo useradd -m -s /bin/bash -G devs alice
echo 'alice:密码' | sudo chpasswd
id alice

# 目录与权限
sudo mkdir -p /srv/shared
sudo chown root:devs /srv/shared
sudo chmod 2775 /srv/shared            # 775 + SGID
sudo chmod 3775 /srv/shared            # 775 + SGID + sticky
ls -ld /srv/shared

# ACL
sudo apt install -y acl
sudo setfacl -m u:carol:rwx /srv/shared        # 访问 ACL（只管自己）
sudo setfacl -d -m u:carol:rwx /srv/shared     # 默认 ACL（管新建子项）
getfacl /srv/shared
sudo setfacl -b /srv/shared                    # 清空所有 ACL
sudo setfacl -x u:carol /srv/shared            # 只删 carol 这一条

# 身份切换
su - alice            # 切到 alice（带 - 加载登录环境）
exit                  # 退回上一层
```

---

## 九、口头验收记录（2026-10-28）

| 问题 | 回答要点 | 判定 |
|---|---|---|
| 目录的 `w` 与文件的 `w` 是否相同 | 不同。目录 `w` = 可创建/修改/删除目录内条目及文件名；文件 `w` = 只改文件内容。`444` 文件仍可被 `rm`，因为删的是目录条目，前提是目录有 `wx` | ✅ |
| 目录有 `r` 无 `x` 时 `ls` 与 `cd` 的结果 | `ls` 能列出文件名；`cd` 失败（无穿越权限） | ✅ |
| `umask 0002` 下新建目录/文件权限 | 目录 `775`，文件 `664`（777 & ~002、666 & ~002） | ✅ |
| `2775` 里的 `2` 是什么，不加会怎样 | SGID。不加则 alice 建的文件属组是 `alice`，bob 无法写入 | ✅ |

---

## 十、待办 / 后续

- [ ] 03 磁盘分区与挂载（记住先拍快照 `lab-03-开始`）
- [ ] sticky 位只在原理里讲了，还没实测——可在 03 或之后补一个 `/tmp` 对比实验
- [ ] 撤实验时记得 `sudo rm -rf /srv/shared` 并删用户，避免污染后续实验

---

## 十一、命令详解（本项首次出现的命令与参数）

> 原则：每个新出现的命令或参数，都要能说清「它是什么、这个参数干什么、为什么这里要用它」。

### 11.1 `groupadd` / `groupdel` — 建组、删组

```bash
sudo groupadd devs
sudo groupdel ops
sudo groupadd -g 2000 testgrp     # 指定 GID
```

- `-g` 指定 GID，不指定则自动分配下一个可用的（≥1000）
- `groupdel` 不能删仍有成员作为**主组**的组

### 11.2 `useradd` 的参数

```bash
sudo useradd -m -s /bin/bash -G devs alice
```

| 参数 | 含义 | 不加的后果 |
|---|---|---|
| `-m` | 创建家目录 | 无 `/home/alice` |
| `-s /bin/bash` | 指定登录 shell | 可能是 `/bin/sh` 或 `nologin` |
| `-G devs` | 附加组 | 不在任何业务组 |
| `-g devs` | **主组**（小写 g） | 默认建同名私有组 |
| `-u 1500` | 指定 UID | 自动分配 |
| `-d /path` | 指定家目录路径 | 默认 `/home/用户名` |
| `-e 2026-12-31` | 账号过期日 | 永不过期 |
| `-r` | 建系统账号（UID < 1000） | — |

- **`-G`（大写）附加组 vs `-g`（小写）主组**，是最常见的拼写混淆点
- 新建用户时 `-G` 不需要 `-a`（新用户本来就没附加组）

### 11.3 `chpasswd` — 批量设密码

```bash
echo 'alice:<LAB_PASSWORD>' | sudo chpasswd
printf 'alice:pw1\nbob:pw2\n' | sudo chpasswd    # 一次设多个
```

- 从标准输入读 `用户名:密码`，每行一个
- `-e` 表示密码已加密（默认视为明文）
- **比 `passwd` 适合脚本**（`passwd` 是交互式的）
- 密码会留在 shell 历史，命令前加空格可避免（`HISTCONTROL=ignoreboth`）

### 11.4 `passwd` — 改密码

```bash
passwd              # 改自己的
sudo passwd alice   # 改别人的（root 身份，不需要旧密码）
sudo passwd -l alice   # 锁定账号（lock）
sudo passwd -u alice   # 解锁
sudo passwd -S alice   # 看状态（status）
```

### 11.5 `id` / `groups` — 查身份

```bash
id              # uid=... gid=... groups=...
id alice
groups alice
```

- `gid=` 后面是**主组**，`groups=` 列表里包含了主组和所有附加组
- 验证"加组成功没有"就看 `groups=` 里有没有目标组

### 11.6 `chown` / `chgrp` — 改属主属组

```bash
sudo chown root:devs /srv/shared      # 同时改属主和属组
sudo chown alice /srv/shared          # 只改属主
sudo chgrp devs /srv/shared           # 只改属组
sudo chown -R alice:devs /srv/shared  # 递归
```

- 格式 `属主:属组`，冒号也可写成点（`root.devs`）
- 只有 root 能把文件给别的用户（普通用户只能"送"给自己的组）

### 11.7 `chmod` — 改权限（数字法与符号法）

```bash
sudo chmod 2775 /srv/shared           # 数字法（八进制）
sudo chmod u+rwx,g+rwx,o+rx /srv/shared   # 符号法
sudo chmod g-w /srv/shared            # 去掉组的 w
sudo chmod -R 755 /srv/shared         # 递归
```

**数字法每一位 = r(4) + w(2) + x(1) 的和：**

| 数字 | 权限 | 目录含义 |
|---|---|---|
| 7 | rwx | 列、进、增删 |
| 6 | rw- | 列、增删但不能进（**没用**） |
| 5 | r-x | 列、进，不能增删 |
| 4 | r-- | 只能列名字 |
| 0 | --- | 什么都不能 |

**四位数时第一位是特殊位：**

| 首位 | 名称 | 作用 |
|---|---|---|
| `2` | SGID | 目录内新建项继承该目录的属组 |
| `4` | SUID | 执行时以文件属主身份运行（如 `passwd`） |
| `1` | Sticky | 只能删自己的文件（如 `/tmp`） |
| `2775` | SGID + 775 | 本实验用的 |

**符号法**：`u`（属主）/`g`（属组）/`o`（其他）/`a`（全部），`+` 加、`-` 减、`=` 设为

### 11.8 `setfacl` — 设置 ACL

```bash
sudo setfacl -m u:carol:rwx /srv/shared      # 给用户加
sudo setfacl -m g:devs:rwx /srv/shared       # 给组加
sudo setfacl -d -m u:carol:rwx /srv/shared   # 默认 ACL（新建子项继承）
sudo setfacl -x u:carol /srv/shared          # 删某一条
sudo setfacl -b /srv/shared                  # 清空所有 ACL
sudo setfacl -R -m u:carol:rw /srv/shared    # 递归
```

| 参数 | 含义 |
|---|---|
| `-m` | modify，新增或修改规则 |
| `-x` | remove，删除指定条目 |
| `-b` | remove all，删除全部 ACL |
| `-d` | **default**，作用于"今后新建的子项"，不影响已有 |
| `-R` | 递归 |
| `-n` | 不重算 mask |

- 条目格式 `u:用户:权限` / `g:组:权限` / `m::权限`（mask）/ `o::权限`
- **访问 ACL（`-m`）只作用于该对象本身**；要继承必须 `-d`
- `-d` 只对**新建**的子项生效，已存在的子目录得删掉重建或单独补

### 11.9 `getfacl` — 查看 ACL

```bash
getfacl /srv/shared
```

输出里几个关键部分：

| 行 | 含义 |
|---|---|
| `# owner` / `# group` | 属主 / 属组 |
| `# flags: -s-` | `s` 表示 SGID 已设（还有 `-t-` sticky、`-m-` mask） |
| `user::rwx` | 属主权限（两个冒号中间空 = 属主） |
| `user:carol:rwx` | carol 的单独条目 |
| `group::rwx` | 属组权限 |
| `mask::rwx` | **mask，ACL 生效上限** |
| `other::r-x` | 其他人 |
| `default:...` | 默认 ACL（管新建子项） |
| `#effective:r-x` | 被 mask 削掉后的**实际生效值** |

- 看到 `#effective:` 就说明有条目被 mask 限制了

### 11.10 `getent` 与 `umask`

```bash
getent group devs ops        # 同时查多个
umask                        # 显示当前 umask（0022 形式）
umask -S                     # 符号形式显示（u=rwx,g=rx,o=rx）
```

- `umask` 是**屏蔽位**，最终权限 = 基础权限 & ~umask
- 目录基础 `777`，文件基础 `666`

### 11.11 `mkdir -p` / `rm -rf`

```bash
sudo mkdir -p /srv/shared        # 父目录不存在也建，已存在不报错
sudo rm -rf /srv/shared          # 递归强制删除
```

| 参数 | 含义 |
|---|---|
| `-p` | parents，递归创建父目录；目标已存在也不报错 |
| `-r` | recursive，递归删目录 |
| `-f` | force，忽略不存在的文件、不提示 |

- **`rm -rf` 极度危险**，路径写错无法撤销。执行前 `ls` 确认，或先 `echo` 打印目标路径

### 11.12 `ls -ld` — 看目录本身而不是内容

```bash
ls -ld /srv/shared
ls -l /srv/shared     # 这才是看目录里的内容
```

| 参数 | 含义 |
|---|---|
| `-l` | long，长格式（权限、属主、大小、时间） |
| `-d` | directory，**只显示目录本身**，不展开内容 |

- 看目录权限必须用 `-ld`，`-l` 会把里面的文件列出来

### 11.13 `echo` 与重定向

```bash
echo "carol via acl" > /srv/shared/carol.txt    # 覆盖写入
echo "bob was here" >> /srv/shared/alice.txt    # 追加
```

| 符号 | 含义 |
|---|---|
| `>` | 覆盖写（文件原有内容清空） |
| `>>` | 追加 |
| `2>` | 重定向标准错误 |
| `&>` | 重定向标准输出 + 标准错误 |

- **重定向由当前 shell 执行**，所以 `sudo echo x > /root/f` 会失败
- `~/.bashrc` 里的 `set -o noclobber` 会禁止 `>` 覆盖已有文件

### 11.14 `su -` 与 `exit`

```bash
sudo su - alice      # 用 sudo 提权后切到 alice（不用输 alice 密码）
su - alice           # 直接切（要输 alice 的密码）
exit                 # 退回上一层
```

- `sudo su - alice` 在实际运维里比 `su - alice` 常用：只输自己的密码，且能审计到"谁切过"
- 实验里用 `su - alice` 是为了验证"alice 自己能登录并使用自己的环境"

