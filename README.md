# raspberry-pi-pdf-printer

把树莓派 + HP LaserJet Professional P1108 变成一台「网页上传即打印」的网络打印机：
浏览器拖入 PDF → 打印机出纸 → **只有打印成功**的文件才归档到 `printed/`。

一条命令完成全部安装（CUPS 队列 + P1108 必需的 HPLIP 专有插件 + 开机自启的 Web 服务 + 自检打印）。

> **TL;DR (English):** turn a Raspberry Pi + HP LaserJet P1108 into a web print dropbox.
> `sudo bash install.sh` installs CUPS/HPLIP dependencies, the proprietary HPLIP
> plugin that the P1108 needs, creates the print queue, deploys a small Flask
> service as a systemd unit, and prints a self-test page. A PDF is moved to
> `printed/` **only after CUPS reports the job completed**.

---

## 已验证环境

| 项目 | 实测值 |
|---|---|
| 主板 | Raspberry Pi，`aarch64`（64 位内核） |
| 系统 | Debian GNU/Linux 10 (buster) / Raspberry Pi OS |
| CUPS | 2.2.10-6+deb10u10 + cups-filters 1.21.6 |
| HPLIP | 3.18.12+dfsg0-2（`printer-driver-hpcups`） |
| 打印机 | `03f0:002a HP, Inc LaserJet P1102`（P1108 属同一家族） |
| Python | 3.7 + `python3-flask` 1.0.2 + `python3-cups` 1.9.73 |

脚本按架构自动映射 `arm64 / arm32 / x86_64 / x86_32`，因此 32 位 Raspberry Pi OS 和
Intel NUC 上的 Debian/Ubuntu 同样可用；系统不限树莓派，只要是有 apt 的 Debian 系。

## 为什么需要那个「专有插件」

P1108 在 HPLIP 的 `models.dat` 里标记为 `plugin=1`：驱动本体开源，但打印流水线里
有一块 HP 专有的二进制。缺它时 CUPS 作业会永远卡在队列，日志长这样：

```
HPCupsFilter.cpp 489: m_Job initialization failed with error = 48
INFO: hpcups crashed on signal 11
```

`install.sh` 会读取 HPLIP 官方清单 `plugin.conf`，按你机器上装的 HPLIP 版本号
下载匹配的 `hplip-<版本>-plugin.run`，**校验 SHA1 与文件大小**后才安装。
本仓库不包含任何 HP 专有文件。

## 快速开始

```bash
git clone https://github.com/SibthorpStudio/rpi-hp1108-pdf-auto-printer.git
cd raspberry-pi-pdf-printer
sudo bash install.sh
```

没有装 `git` 的话：

```bash
sudo apt-get install -y git && \
sudo bash -c 'git clone https://github.com/SibthorpStudio/rpi-hp1108-pdf-auto-printer.git /tmp/pp && bash /tmp/pp/install.sh'
```

安装最后一步会自动打印一张自检页（`pdfprint self-test`）。看到它出来 = 全链路通了。

常用参数：

```
--printer NAME    CUPS 队列名（默认 HP-LaserJet-Professional-P1108）
--model PATTERN   查找设备/驱动的关键词（默认 p1108，可换成 p1102、m176n 等）
--dir PATH        部署目录（默认 /opt/pdfprint）
--user NAME       运行服务的用户（默认 pdfprint）
--port N          监听端口（默认 8080）
--paper SIZE      队列默认纸张，国内建议 --paper A4
--skip-deps       不执行 apt-get
--skip-plugin     不动 HPLIP 插件
--skip-test       跳过自检打印
```

## 使用

1. 浏览器打开 `http://<树莓派 IP>:8080/`（安装结束会打印这个地址）。
2. 点击或拖入 PDF（支持一次多个），页面每 2 秒刷新状态：
   排队中 → 打印中 → **已打印** / 失败。
3. 成功的文件出现在 `/opt/pdfprint/printed/`，重名自动追加 `-1`、`-2`；
   失败或超时的文件留在 `/opt/pdfprint/spool/` 里，不会被删除。

命令行也能用（脚本、手机、Home Assistant 都行）：

```bash
curl -F "file=@report.pdf" http://<树莓派 IP>:8080/upload   # 提交打印
curl http://<树莓派 IP>:8080/jobs                            # 查看最近作业状态
```

接口只有三个：`GET /`（页面）、`POST /upload`（字段名 `file`）、`GET /jobs`（JSON）。
非 PDF 一律返回 `415 只接受 PDF 文件`（按 `%PDF-` 魔数判断，不看扩展名）。

## 配置

改 `/etc/pdfprint.conf`（systemd `EnvironmentFile`），然后 `sudo systemctl restart pdfprint`：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PDFPRINT_PRINTER` | `HP-LaserJet-Professional-P1108` | 目标 CUPS 队列名，用 `lpstat -p` 查 |
| `PDFPRINT_PORT` | `8080` | 监听端口 |
| `PDFPRINT_BIND` | `0.0.0.0` | 改成 `127.0.0.1` 即只本机可访问 |
| `PDFPRINT_MAX_MB` | `50` | 单文件上限 |
| `PDFPRINT_TIMEOUT` | `240` | 等待一张纸打完的秒数，超时判失败 |
| `PDFPRINT_HISTORY` | `40` | 页面保留的最近作业条数（仅内存） |

日志与状态：

```bash
systemctl status pdfprint
journalctl -u pdfprint -f
lpstat -W completed -o HP-LaserJet-Professional-P1108
```

## 安全须知（务必看一眼）

服务**没有登录鉴权**，监听 `0.0.0.0:8080` —— 局域网里任何能连到这个端口的人都能打印、
也能看到最近文件名列表。建议至少做一条：

* 只在可信网络使用，或路由器上封掉该端口的 WAN 访问（默认不要做端口映射）；
* `PDFPRINT_BIND=127.0.0.1` + `ssh -L 8080:127.0.0.1:8080 pi@<Pi IP>` 远程用；
* 需要账号口令时，前面挂一个 nginx + `auth_basic`，服务只监听 127.0.0.1。

上传的文件只做「重命名 + 白名单字符过滤」，落在 `spool/`；服务以独立
`pdfprint` 用户运行，不是 root。

## 卸载

```bash
sudo bash uninstall.sh            # 停服务、删 systemd 单元，保留 printed/
sudo bash uninstall.sh --purge    # 连部署目录一起删（删除前会二次确认）
```

CUPS 队列和已安装的 HPLIP 插件属于系统打印配置，不会被脚本删除。

## 目录结构

```
install.sh                    一键安装入口（依赖 → 插件 → 队列 → 服务 → 自检）
uninstall.sh                  卸载
app/pdfprint.py               Flask 服务：上传 / 打印 / 按 IPP 作业状态归档
systemd/pdfprint.service      开机自启单元模板（install.sh 替换 @USER@ @DIR@）
config/pdfprint.conf.example  运行时配置样例，安装时写到 /etc/pdfprint.conf
scripts/install-hplip-plugin.sh  只修「P1108 缺插件、作业卡死」这一步
scripts/make-test-pdf.py      生成自检用的一页 PDF（无第三方依赖）
docs/TROUBLESHOOTING.md       排错：插件、卡队列、权限、状态判读
```

## 已知限制

* 用 Flask 自带开发服务器，单进程串行打印；够用（一次一张纸）但不是高并发方案。
* 作业历史在内存里，服务重启后列表清空 —— 文件归档不受影响。
* 只接受 PDF。图片/文本请先转成 PDF，或改用 `lp` 直接提交。
* 「打印成功」= CUPS 报告作业 `completed`。打印机断电、缺纸导致驱动侧超时的情况，
  会以 `timeout`/`aborted` 判为失败，文件留在 `spool/`。
* 树莓派通常是 DHCP 地址，建议在路由器上做 MAC 绑定，否则 IP 变了网页地址就失效。

## 许可与商标

代码采用 [MIT](LICENSE)。HP、LaserJet 为惠普公司商标；HPLIP 专有插件由 HP 分发，
安装时从官方源下载并校验，不以本仓库作为分发渠道。
