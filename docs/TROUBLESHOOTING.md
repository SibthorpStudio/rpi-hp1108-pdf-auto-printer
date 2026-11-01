# 排错指南

按「现象 → 定位 → 处理」排列，都是这台 P1108 上真实踩过的坑。

## 0. 一分钟自检

```bash
systemctl status pdfprint --no-pager        # 服务在不在
ss -ltnp | grep ':8080'                     # 端口有没有监听
lsusb | grep -i hp                          # USB 层能不能看到打印机
ls -l /usr/share/hplip/prnt/plugins         # 专有插件在不在（lj.so 必须不是红字/断链）
lpstat -p -d                                # CUPS 队列状态与默认队列
lpstat -o                                   # 有没有作业卡住
curl -s http://127.0.0.1:8080/jobs | python3 -m json.tool   # 服务侧最近作业
```

## 1. 作业永远停在队列、Web 端一直「打印中」最后 timeout

看 CUPS 日志：

```bash
sudo tail -n 80 /var/log/cups/error_log | grep -iE "plugin|hpcups|crash"
```

命中这三行就是缺 HPLIP 专有插件（不是配置错、不是线没插好）：

```
PID 12345 (<HPCupsFilter.cpp 489>)： m_Job initialization failed with error = 48
INFO: hpcups crashed on signal 11
job-state-reasons: hplip.plugin-error
```

处理：

```bash
sudo bash scripts/install-hplip-plugin.sh
sudo systemctl restart cups
lpstat -o                       # 之前卡住的作业要手动清掉
sudo cancel <队列名>-<编号>
```

`install-hplip-plugin.sh` 会按已装的 HPLIP 版本从官方 `plugin.conf` 找到对应
`.run`，校验 SHA1 后再装。想走 HP 官方交互式安装器也可以，但它需要一个终端：

```bash
sudo hp-plugin -i          # 界面会问你用什么方式下载，选 http 即可
```

注意 `hp-plugin -i -p <文件>` 要求文件名**必须**是 `hplip-<版本>-plugin.run`，
否则报 `Plug-in filename must be ...`；另外它在非交互终端里会挂住等输入。

## 2. `hp-doctor` 说 “cupsext not present in the system”

这条在本机是误报，别跟着折腾。判断方法：

```bash
python3 -c "import cupsext, hpmudext; print('HPLIP python extensions OK')"
ls /usr/share/hplip/cupsext*.so /usr/lib/python3/dist-packages/cupsext*.so 2>/dev/null
```

能 import 就说明扩展没问题，真正的病灶通常是上面第 1 条的打印插件。

## 3. Web 报 “CUPS 拒绝该作业: …”

pycups 连不上或没权限提交作业：

```bash
groups pdfprint                     # 应包含 lp sys
sudo usermod -aG lp,sys pdfprint
sudo systemctl restart pdfprint
```

`@SYSTEM@` 在 Debian 上就是 `sys root`；服务用户不在 `sys` 里时，CUPS 的默认策略
可能拒绝它提交作业。装 `--user pi`（沿用你登录桌面的用户）也能绕过这个问题。

若 `Connection refused`：检查 `cups.service` 是否在跑、`/etc/cups/cupsd.conf` 里
`Listen /run/cups/cups.sock` 是否被改过。

## 4. 上传被拒绝

| 返回 | 原因 |
|---|---|
| `只接受 PDF 文件` (415) | 前 5 个字节不是 `%PDF-`。图片/文本/Word 请先转 PDF |
| `文件超过 N MB` (413) | 调大 `PDFPRINT_MAX_MB` 后重启服务 |
| `空文件` (400) | 上传通道断开，重新提交 |
| `没有收到文件` (400) | 表单字段名不是 `file`（`curl -F "file=@x.pdf"`） |

`lp` 命令能直接打 PDF，可用来确认「问题在 Web 服务还是在打印机」：

```bash
lp -d HP-LaserJet-Professional-P1108 /path/to/x.pdf
lpstat -o; lpstat -W completed -o HP-LaserJet-Professional-P1108
```

## 5. 打印成功判断的含义

服务轮询 IPP `job-state`：

| `job-state` | 服务显示 | 处理 |
|---|---|---|
| 3 pending / 4 processing | `queued` / `printing` | 正常等待 |
| 9 completed | `printed` → 文件移到 `printed/` | 完成 |
| 6 aborted / 5 canceled | `failed`，文件留在 `spool/` | 看 `job-state-reasons` |
| 超过 `PDFPRINT_TIMEOUT` | `failed: timeout ...` | 多为缺纸、离线、USB 掉线 |

`job-state-reasons` 里最常见的两个：

* `connecting-to-device` 长时间不变 → USB 未被识别或掉线，`lsusb | grep -i hp`、换口、
  别用不带供电的 hub；
* `hplip.plugin-error` → 回到本文第 1 条。

想看得更细，临时开调试日志（事后关掉）：

```bash
sudo cupsctl --debug-logging
sudo tail -f /var/log/cups/error_log
sudo cupsctl --no-debug-logging
```

## 6. 服务起不来

```bash
journalctl -u pdfprint -n 50 --no-pager
```

* `ModuleNotFoundError: cups` → `sudo apt install -y python3-cups`
* `ModuleNotFoundError: flask` → `sudo apt install -y python3-flask`
* `Address already in use` → 上一个手动启动的实例还活着：
  `sudo ss -ltnp | grep 8080` 找到 PID，`sudo systemctl stop pdfprint` 后 kill 掉，
  再 `sudo systemctl start pdfprint`
* `AttributeError: module 'cups' has no attribute 'IPP_JOB_PRINTING'` → 你用的 pycups
  版本状态常量名不同。Debian 上是 `IPP_JOB_PROCESSING`；用
  `python3 -c "import cups;print([x for x in dir(cups) if x.startswith('IPP_JOB')])"` 查。

## 7. 换打印机 / 换端口

不改代码，只改 `/etc/pdfprint.conf`：

```
PDFPRINT_PRINTER=<lpstat -p 里的队列名>
PDFPRINT_PORT=<端口>
PDFPRINT_BIND=127.0.0.1     # 只本机访问，配合 SSH 隧道
```

然后 `sudo systemctl restart pdfprint`。

给别的机器访问 CUPS 管理页（631）用：

```bash
sudo cupsctl --remote-admin --remote-any     # 用完记得 --no-remote-admin --no-remote-any
```

## 8. 其他「需要专有插件」的 HP 机型

`plugin=1` 的机型都走同一套流程（例：P1005 系列需要 `lj` 之外的固件、
M176n/M177fw 需要 `lj` + `scan` 插件）。查你自己的机器：

```bash
grep -A3 -i "LaserJet Professional P1108" /usr/share/hplip/data/models/models.dat | head
```

看到 `plugin=1` 就说明必须有专有插件。`drv:///hpcups.drv/*.ppd` 里带
`requires proprietary plugin` 字样的驱动同理。
