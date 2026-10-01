#!/usr/bin/env python3
"""
KitoIP asset generator.

Creates:
    assets/social-preview.png   GitHub social preview + README hero (1280x640)
    assets/demo.gif             Animated terminal walkthrough

All terminal text below is transcribed from a REAL read-only run of KitoIP:
the main menu, and mode [4] "Proxy List" (which changes no system setting).
The machine's own public IP is masked with the documentation range
203.0.113.0/24 before it is drawn.

Requirements:
    pip install pillow

Usage:
    python tools/make_assets.py
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")
FONTS = "C:/Windows/Fonts"

# ----------------------------------------------------------------- palette
BG = (13, 17, 23)
WIN = (22, 27, 34)
TITLEBAR = (33, 38, 45)
BORDER = (48, 54, 61)
TXT = (201, 209, 217)
DIM = (110, 118, 129)
GREEN = (63, 185, 80)
CYAN = (88, 166, 255)
YELLOW = (227, 179, 65)
RED = (248, 81, 73)
MAGENTA = (188, 140, 255)
ORANGE = (255, 166, 87)
WHITE = (240, 246, 252)

# ----------------------------------------------------------------- layout
WIN_W, WIN_H = 900, 700
CANVAS_W, CANVAS_H = WIN_W, WIN_H


def font(path, size):
    try:
        return ImageFont.truetype(os.path.join(FONTS, path), size)
    except OSError:
        return ImageFont.load_default()


MONO = "CascadiaCode.ttf"
MONO_B = "consolab.ttf"
UI = "segoeuib.ttf"
UI_R = "segoeui.ttf"

F_TERM = font(MONO, 15)
F_TERM_B = font(MONO_B, 15)
LINE_H = 20
PAD_X = 18
TEXT_TOP = 48


# ----------------------------------------------------------------- helpers
def blank():
    return []


def line(*segments):
    """line(('text', COLOR), ...) -> list of segments"""
    return list(segments)


def draw_terminal(lines, cursor=None):
    """Render a terminal window showing `lines`.

    lines:  list of segments-lists (one per line)
    cursor: optional (line_index, prefix_text) to draw a block cursor after
    """
    img = Image.new("RGB", (CANVAS_W, CANVAS_H), WIN)
    d = ImageDraw.Draw(img)

    # window chrome
    d.rounded_rectangle([(0, 0), (WIN_W - 1, WIN_H - 1)], radius=10,
                        fill=WIN, outline=BORDER)
    d.rectangle([(0, 0), (WIN_W - 1, 36)], fill=TITLEBAR)
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = 20 + i * 20
        d.ellipse([(cx, 14), (cx + 11, 25)], fill=c)

    title = "KitoIP - Proxy + IP Toolkit"
    tw = d.textlength(title, font=font(MONO, 12))
    d.text(((WIN_W - tw) / 2, 13), title, font=font(MONO, 12), fill=DIM)

    # body
    y = TEXT_TOP
    max_lines = (WIN_H - TEXT_TOP - 12) // LINE_H
    visible = lines[-max_lines:]
    offset = len(lines) - len(visible)

    for i, segs in enumerate(visible):
        x = PAD_X
        for text, color in segs:
            d.text((x, y), text, font=F_TERM, fill=color)
            x += d.textlength(text, font=F_TERM)
        if cursor and (offset + i) == cursor[0]:
            cx = PAD_X + d.textlength(cursor[1], font=F_TERM)
            d.rectangle([(cx, y + 2), (cx + 8, y + 15)], fill=TXT)
        y += LINE_H
    return img


# ----------------------------------------------------------------- content
SPLASH = [
    line(("   +================================================================+", CYAN)),
    line(("   |             #   #  ###  #####   ###   ###  ####                |", YELLOW)),
    line(("   |             #  #    #     #    #   #   #   #   #               |", YELLOW)),
    line(("   |             ###     #     #    #   #   #   ####                |", YELLOW)),
    line(("   |             #  #    #     #    #   #   #   #                   |", YELLOW)),
    line(("   |             #   #  ###    #     ###   ###  #                   |", YELLOW)),
    line(("   |                   Proxy + IP Toolkit  -  v6                    |", MAGENTA)),
    line(("   |             Hang-free scan engine: C# thread pool              |", DIM)),
    line(("   +================================================================+", CYAN)),
    blank(),
]

MENU = [
    line(("  ============================================================", CYAN)),
    line(("      K I T O I P  ", MAGENTA), ("   Proxy + IP Toolkit", WHITE)),
    line(("  ============================================================", CYAN)),
    line(("      Country     : ", DIM), ("DE", YELLOW)),
    line(("      Pool        : ", DIM), ("9605 candidates", WHITE), ("  (remote + local)", DIM)),
    line(("      Best        : ", DIM), ("10", WHITE), ("   |   Cache: ", DIM), ("380", WHITE)),
    line(("      Active proxy: ", DIM), ("none", DIM)),
    blank(),
    line(("    [1]  Connect to a Foreign IP   ", WHITE), ("(country filter + lowest ms)", DIM)),
    line(("    [2]  Fast Connect              ", GREEN), ("(from cache, in seconds)", DIM)),
    line(("    [3]  Proxy Hunt                ", WHITE), ("(rebuild the best list)", DIM)),
    line(("    [4]  Proxy List                ", WHITE), ("(show the fastest candidates)", DIM)),
    line(("    [5]  Select Country            ", WHITE), ("(now: DE)", DIM)),
    line(("    [6]  Proxy Off                 ", WHITE), ("(back to the normal connection)", DIM)),
    line(("    [7]  Status", WHITE)),
    blank(),
    line(("    [8]  Change LAN IP", WHITE)),
    line(("    [9]  WireGuard WARP VPN", WHITE)),
    line(("    [P]  Manage Proxy List         ", WHITE), ("(bulk import / clear cache)", DIM)),
    line(("    [0]  Exit", WHITE)),
    blank(),
]

LIST_HEAD = [
    line(("  ============================================", CYAN)),
    line(("       K I T O V P N   -   Public IP / Country", MAGENTA)),
    line(("  ============================================", CYAN)),
    line(("Mode=", DIM), ("List", WHITE), (" Country=", DIM), ("DE", YELLOW),
         (" MaxLatencyMs=", DIM), ("900", WHITE), (" TcpWorkers=", DIM), ("768", WHITE)),
    line(("Current public IP: ", DIM), ("203.0.113.42", WHITE), (" (Azerbaijan)", DIM)),
    line(("Preparing candidate pool...", YELLOW)),
    line(("  9594 candidates from remote sources.", DIM)),
    line(("  Pool: local 28 + cache 40 -> ", DIM), ("9605 unique candidates total.", WHITE)),
    line(("9605 candidates will go through the TCP pre-filter (priority 40, fresh 9565).", DIM)),
]


def bar(done, total, width=28, label="TCP  "):
    pct = int(done * 100 / total)
    filled = int(done * width / total)
    return "  %s [%s%s] %3d%%  %d/%d" % (
        label, "#" * filled, "-" * (width - filled), pct, done, total)


LIST_TAIL = [
    line(("  TCP   [Done] 9605/9605  (14s)", GREEN)),
    line(("TCP filter: ", WHITE), ("1266", GREEN), ("/9605 ports open.", WHITE)),
    line(("1266 proxies will go through HTTP/HTTPS testing (concurrency 256)...", DIM)),
    line(("  HTTP  [Done] 1266/1266  (25s)", GREEN)),
    line(("147 working proxies (73 of them opened an HTTPS tunnel).", GREEN)),
    line(("2 proxies are HTTPS-OK and fast (<=900ms).", GREEN)),
    blank(),
    line(("  Best proxies (sorted by ms):", YELLOW)),
    blank(),
    line(("Proxy                 Latency KBps Https CC Country City", WHITE)),
    line(("-----                 ------- ---- ----- -- ------- ----", DIM)),
    line(("103.237.102.191:11111     356    0  True DE Germany Frankfurt am Main", TXT)),
    line(("18.157.123.132:3128       525    0  True DE Germany Frankfurt am Main", TXT)),
    blank(),
]


PROMPT_PS = "PS C:\\KitoIP> "
CMD = ".\\KitoIP.bat"
PROMPT = PROMPT_PS + CMD


def build_frames():
    frames = []          # (PIL.Image, duration_ms)

    acc = []

    # --- phase 1: type the launch command
    for n in range(4, len(CMD) + 1, 4):
        acc_now = acc + [line((PROMPT_PS, GREEN), (CMD[:n], TXT))]
        frames.append((draw_terminal(acc_now), 90))
    acc.append(line((PROMPT_PS, GREEN), (CMD, TXT)))
    frames.append((draw_terminal(acc), 350))

    # --- phase 2: splash
    acc.append(blank())
    for i in range(0, len(SPLASH) + 1, 3):
        frames.append((draw_terminal(acc + SPLASH[:i]), 110))
    acc += SPLASH
    acc.append(line(("   [OK] Ready.", GREEN)))
    frames.append((draw_terminal(acc), 400))
    acc.append(blank())

    # --- phase 3: menu
    for i in range(3, len(MENU) + 1, 3):
        frames.append((draw_terminal(acc + MENU[:i]), 95))
    acc += MENU
    acc.append(line(("  Selection > ", WHITE)))
    frames.append((draw_terminal(acc), 700))

    # --- phase 4: choose [4]
    acc[-1] = line(("  Selection > ", WHITE), ("4", YELLOW))
    frames.append((draw_terminal(acc), 500))
    acc.append(blank())

    # --- phase 5: proxy list header
    for i in range(3, len(LIST_HEAD) + 1, 3):
        frames.append((draw_terminal(acc + LIST_HEAD[:i]), 110))
    acc += LIST_HEAD

    # --- phase 6: TCP progress
    tcp_steps = [241, 610, 1529, 2436, 3590, 5420, 7360, 9605]
    for step in tcp_steps[:-1]:
        acc_step = acc + [line((bar(step, 9605), CYAN))]
        frames.append((draw_terminal(acc_step), 130))
    acc_tcp = acc + [line((bar(9605, 9605), GREEN))]
    frames.append((draw_terminal(acc_tcp), 300))
    acc = acc_tcp[:9]

    # --- phase 7: HTTP progress
    acc.append(LIST_TAIL[1])
    acc.append(LIST_TAIL[2])
    for step in [120, 383, 971, 1152, 1266]:
        acc_step = acc + [line((bar(step, 1266, 28, "HTTP "), CYAN))]
        frames.append((draw_terminal(acc_step), 140))
    acc.append(line(("  HTTP  [Done] 1266/1266  (25s)", GREEN)))

    # --- phase 8: results
    acc += LIST_TAIL[4:]
    for i in range(2, len(LIST_TAIL[4:]) + 1, 2):
        frames.append((draw_terminal(acc[: len(acc) - len(LIST_TAIL[4:]) + i]), 200))
    frames.append((draw_terminal(acc), 2600))

    # loop back smoothly
    frames.append((draw_terminal(acc), 600))
    return frames


# ----------------------------------------------------------------- banner
def build_social_preview():
    W, H = 1280, 640
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    # subtle vertical gradient
    for y in range(H):
        t = y / H
        c = (int(13 + 12 * t), int(17 + 14 * t), int(23 + 20 * t))
        d.line([(0, y), (W, y)], fill=c)

    # accent glow bar
    d.rectangle([(0, 0), (W, 6)], fill=(88, 166, 255))

    f_logo = font(MONO_B, 96)
    f_tag = font(UI, 34)
    f_sub = font(UI_R, 22)
    f_chip = font(UI, 20)
    f_small = font(UI_R, 18)

    logo = "K I T O I P"
    d.text((80, 62), logo, font=f_logo, fill=WHITE)

    d.text((84, 194), "One menu. Three ways",
           font=f_tag, fill=(201, 209, 217))
    d.text((84, 234), "to change your IP.",
           font=f_tag, fill=(201, 209, 217))
    d.text((84, 282), "Public IP  ·  LAN IP  ·  Country-selectable WARP",
           font=f_sub, fill=DIM)

    # chips (2 x 2 grid)
    chip_rows = [
        [("Windows 10 / 11", CYAN), ("PowerShell 5.1", MAGENTA)],
        [("Zero dependencies", GREEN), ("No binaries", YELLOW)],
    ]
    for ri, row in enumerate(chip_rows):
        x = 84
        cy = 320 + ri * 50
        for label, col in row:
            tw = d.textlength(label, font=f_chip)
            d.rounded_rectangle([(x, cy), (x + tw + 34, cy + 44)], radius=22,
                                fill=(28, 34, 44), outline=col)
            d.text((x + 17, cy + 11), label, font=f_chip, fill=col)
            x += tw + 48

    d.text((84, 436), "13+ auto-fetched proxy sources", font=f_small, fill=(139, 148, 158))
    d.text((84, 462), "100k+ proxy scanning   ·   hang-free C# thread-pool engine",
           font=f_small, fill=(139, 148, 158))

    d.text((84, 504), "github.com/Vorlixx/KitoIP", font=font(UI, 26), fill=(88, 166, 255))

    d.line([(84, 558), (620, 558)], fill=(48, 54, 61))
    d.text((84, 574), "Built for Windows. One menu. No hangs.", font=f_small, fill=(110, 118, 129))

    # ------------------------------------------------- right: terminal mock
    tx, ty, tw2, th = 660, 140, 540, 470
    d.rounded_rectangle([(tx, ty), (tx + tw2, ty + th)], radius=12,
                        fill=(15, 20, 27), outline=BORDER)
    d.rectangle([(tx, ty), (tx + tw2, ty + 30)], fill=TITLEBAR)
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = tx + 16 + i * 18
        d.ellipse([(cx, ty + 11), (cx + 9, ty + 20)], fill=c)

    f_t = font(MONO, 15)
    f_tb = font(MONO_B, 15)
    rows = [
        ("PS C:\\KitoIP> ", GREEN, ".\\KitoIP.bat", TXT, f_t),
        ("  [OK] Ready.", GREEN, "", "", f_t),
        ("", "", "", "", f_t),
        ("      K I T O I P", MAGENTA, "   Proxy + IP Toolkit", WHITE, f_tb),
        ("      Country     : ", DIM, "DE", YELLOW, f_t),
        ("      Pool        : ", DIM, "9605 candidates", WHITE, f_t),
        ("      Best        : ", DIM, "10   |   Cache: 380", WHITE, f_t),
        ("", "", "", "", f_t),
        ("  Selection > ", WHITE, "4   [Proxy List]", YELLOW, f_t),
        ("", "", "", "", f_t),
        ("  9605 candidates -> TCP pre-filter", DIM, "", "", f_t),
        ("  TCP   [Done] 9605/9605  (14s)", GREEN, "", "", f_t),
        ("  1266 ports open -> HTTP/HTTPS test", DIM, "", "", f_t),
        ("  HTTP  [Done] 1266/1266  (25s)", GREEN, "", "", f_t),
        ("  147 working proxies", GREEN, "  (73 HTTPS-OK)", GREEN, f_t),
        ("", "", "", "", f_t),
        ("  103.237.102.191:11111", TXT, "   356 ms  DE", DIM, f_t),
        ("  18.157.123.132:3128", TXT, "     525 ms  DE", DIM, f_t),
    ]
    yy = ty + 44
    for a, ca, b, cb, fo in rows:
        xx = tx + 14
        if a:
            d.text((xx, yy), a, font=fo, fill=ca)
            xx += d.textlength(a, font=fo)
        if b:
            d.text((xx, yy), b, font=fo, fill=cb)
        yy += 23

    os.makedirs(ASSETS, exist_ok=True)
    out = os.path.join(ASSETS, "social-preview.png")
    img.save(out, "PNG", optimize=True)
    return out


# ----------------------------------------------------------------- main
def main():
    os.makedirs(ASSETS, exist_ok=True)

    png = build_social_preview()
    print("wrote", png, os.path.getsize(png), "bytes")

    frames = build_frames()
    imgs = [f[0].convert("P", palette=Image.ADAPTIVE, colors=64) for f in frames]
    durations = [f[1] for f in frames]
    gif = os.path.join(ASSETS, "demo.gif")
    imgs[0].save(
        gif,
        "GIF",
        save_all=True,
        append_images=imgs[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=2,
    )
    print("wrote", gif, os.path.getsize(gif), "bytes", len(imgs), "frames")


if __name__ == "__main__":
    sys.exit(main())
