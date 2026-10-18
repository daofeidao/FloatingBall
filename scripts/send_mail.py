#!/usr/bin/env python3
"""把产物（IPA / tipa 等）当附件发到邮箱 —— 本项目专用的交付通道。

为什么有它
----------
项目规矩（全局 AGENTS.md 第八节）：**IPA 本体必须作为邮件附件发进用户邮箱。**
用户只能在手机上下载邮件附件，再交给 TrollStore 安装；只在聊天里说一声、
只给本地路径、只给 GitHub 链接，都等于没交付。

不走 UI
-------
用户桌面上有个 `wb\\scripts\\send-file-mail\\发送文件到邮箱.exe`，
但那是给他**手动点**用的（无窗口、吃 stdin，脚本调用会挂住）。
自动化一律走这个纯标准库的 Python 脚本。

凭证从哪来
----------
复用 WorkBuddy 那套已配好并验证过的 126 邮箱：`wb\\scripts\\notify\\notify.json`
（里面是明文授权码，本项目不复制、不提交）。
换机器时用 `--config` 指向别的 json 即可，格式：

    { "smtp": { "host": "smtp.126.com", "port": 465,
                "user": "xxx@126.com", "pass": "<授权码>", "to": "yyy@126.com" } }

核验送达
--------
⚠️ **收件人如果不是 `to` 里那个（也就是发外部地址），本脚本无法自证送达** ——
   能读的那个信箱是配置里的 `user` 自己。以前一直是「自发自收」，所以能核验；
   发外部地址只能靠用户在手机上确认。这一点发之前要跟用户讲清楚，别默默发完就算数。

用法
----
    python scripts/send_mail.py <文件> <收件人> <主题> [正文文件] [--config 路径]

例：
    python scripts/send_mail.py build/FloatingBall.tipa you@126.com \
        "悬浮球 0.1.20 已出包（含 IPA）" ref/mail_body.txt
"""
import argparse
import json
import mimetypes
import os
import smtplib
import sys
import time
from email.header import Header
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formataddr

# WorkBuddy 那套通道（126 邮箱，已验证过）
DEFAULT_CONFIG = r"D:\wb\scripts\notify\notify.json"
# 本机上 wb 有两个副本（D:\wb 和 桌面\wb），任选一个存在的
FALLBACK_CONFIGS = [
    DEFAULT_CONFIG,
    os.path.expandvars(r"%USERPROFILE%\Desktop\wb\scripts\notify\notify.json"),
]


def load_cfg(path=None):
    candidates = [path] if path else FALLBACK_CONFIGS
    for p in candidates:
        if p and os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                return json.load(f)["smtp"], p
    sys.exit("[!] 找不到凭证文件，试过：\n    " + "\n    ".join(str(c) for c in candidates)
             + "\n用 --config 指定，或参考本文件顶部的说明新建一个。")


def main():
    ap = argparse.ArgumentParser(description="把文件当附件发到邮箱")
    ap.add_argument("file", help="要发的文件")
    ap.add_argument("to", help="收件地址")
    ap.add_argument("subject", help="主题")
    ap.add_argument("body", nargs="?", default="", help="正文文件（UTF-8）；不给就用最简正文")
    ap.add_argument("--config", help="凭证 json 路径")
    args = ap.parse_args()

    if not os.path.exists(args.file):
        sys.exit("[!] 文件不存在：" + args.file)

    cfg, cfg_path = load_cfg(args.config)

    name = os.path.basename(args.file)
    size_kb = os.path.getsize(args.file) / 1024.0
    body = ""
    if args.body:
        with open(args.body, encoding="utf-8") as f:
            body = f.read()

    msg = MIMEMultipart()
    msg["From"] = formataddr((str(Header("悬浮球构建机器人", "utf-8")), cfg["user"]))
    msg["To"] = args.to
    msg["Subject"] = str(Header(args.subject, "utf-8"))
    msg.attach(MIMEText(body or "附件就是产物本体。", "plain", "utf-8"))

    ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
    with open(args.file, "rb") as f:
        part = MIMEText(f.read(), "base64", "utf-8")
    part["Content-Type"] = ctype
    part.add_header("Content-Disposition", "attachment", filename=("utf-8", "", name))
    msg.attach(part)

    print("凭证来自 %s" % cfg_path)
    print("连接 %s:%s ..." % (cfg["host"], cfg["port"]))
    with smtplib.SMTP_SSL(cfg["host"], int(cfg["port"]), timeout=90) as s:
        s.login(cfg["user"], cfg["pass"])
        s.sendmail(cfg["user"], [args.to], msg.as_string())

    warn = "" if args.to == cfg["to"] else (
        "\n⚠️ 收件人不是凭证里那个信箱（%s）—— 本机读不到它，无法自证送达，请让用户自己确认。" % cfg["to"])
    print("已发送 %s -> %s（附件 %s，%.1f KB，%s）%s"
          % (cfg["user"], args.to, name, size_kb, time.strftime("%Y-%m-%d %H:%M:%S"), warn))


if __name__ == "__main__":
    main()