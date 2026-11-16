#!/usr/bin/python3
# =============================================================================
# sconsole-scrshot-backup-gallery.py
#
# Purpose:
#   Generates static HTML pages for browsing the backed-up screenshots:
#     <local-dir>/index.html            tree of year > month > week (Sun-Sat)
#                                       beside a view pane
#     <local-dir>/YYYY-MM/index.html    month calendar
#     <local-dir>/YYYY-MM/week-N.html   week N of the month: day x hour table;
#                                       an hour opens its screenshots in a grid,
#                                       and a screenshot opens zoomed with Save
#     <local-dir>/gallery.css, gallery.js  shared by all pages
#   Weeks are rows of the month's calendar, so a week that spans two months is
#   split between them and each month folder only links its own images.
#   Every page carries a signature of the data it shows and is rewritten only
#   when that changes, so a backup run normally rewrites just the index, the
#   current month and the current week. The backup runs this after each run
#   that filed new screenshots.
#   Uses Apple's /usr/bin/python3 (3.9), standard library only.
#
# Usage:
#   sconsole-scrshot-backup-gallery.py [options]
#
# Parameters:
#   --local-dir <dir>  Local backup folder with the YYYY-MM/ month folders.
#                      Default: ~/projects/workspace/sconsole/sconsole-screenshots
#   --all              Rewrite every page, even unchanged ones (use after
#                      changing this script's page layout).
#   /?, -h, --help     Print this help and exit.
#
# Exit codes:
#   0  pages up to date
#   1  the backup folder could not be read
#   2  bad arguments
# =============================================================================
import calendar
import hashlib
import html
import json
import os
import re
import sys
from datetime import date

LOCAL_DIR = os.path.expanduser("~/projects/workspace/sconsole/sconsole-screenshots")
GEN_VERSION = 3   # bump when the page layout changes, so --all is not needed
MONTH = re.compile(r"^\d{4}-\d\d$")
SHOT = re.compile(r"^(\d{4}-\d\d-\d\d) (\d\d)(\d\d)(\d\d)\.png$")
SIG = re.compile(r'<meta name="gallery-sig" content="([0-9a-f]+)">')
# Month and week pages also open on their own (e.g. from the status page), so
# they link back to the tree; _top replaces the index rather than nesting it
ALL_LINK = '<a href="../index.html" target="_top">All screenshots</a>'

CSS = """\
:root {
  --bg: #f6f5f2; --card: #ffffff; --text: #1d1d1f; --muted: #6e6e73;
  --line: #e3e1dc; --accent: #2f6fdf; --code-bg: #f0efeb;
  --heat1: #dfe9fb; --heat2: #b5cdf6; --heat3: #7ea8ee; --heat4: #2f6fdf; --heat-text: #ffffff;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #161617; --card: #212123; --text: #f2f2f4; --muted: #9a9aa0;
    --line: #333336; --accent: #6ea2ff; --code-bg: #2b2b2e;
    --heat1: #23324d; --heat2: #2c4a80; --heat3: #3d66b3; --heat4: #6ea2ff; --heat-text: #10131a;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text); }
body { font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
.muted { color: var(--muted); }

/* index: tree + view pane */
.app { display: grid; grid-template-columns: 250px 1fr; height: 100vh; }
.tree { border-right: 1px solid var(--line); background: var(--card); overflow-y: auto; padding: 16px 12px; }
.tree h1 { font-size: 17px; margin: 0 0 2px; }
.tree .sub { font-size: 12px; color: var(--muted); margin: 0 0 14px; }
.tree details { margin: 2px 0; }
.tree summary { cursor: pointer; padding: 3px 6px; border-radius: 6px; list-style-position: outside; }
.tree summary:hover { background: var(--code-bg); }
.tree .year > summary { font-weight: 600; }
.tree .month { margin-left: 12px; }
.tree .weeks { list-style: none; margin: 0 0 4px 14px; padding: 0; }
.tree .weeks a, .tree summary a { color: inherit; display: block; padding: 2px 6px; border-radius: 6px; }
.tree summary a { display: inline; padding: 0; }
.tree .weeks a:hover { background: var(--code-bg); text-decoration: none; }
.tree .count { color: var(--muted); font-size: 12px; float: right; }
.tree .current { background: var(--accent) !important; color: #fff !important; }
.tree .current .count { color: #fff; }
.view { width: 100%; height: 100%; border: 0; display: block; background: var(--bg); }
@media (max-width: 700px) {
  .app { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
  .tree { max-height: 38vh; border-right: 0; border-bottom: 1px solid var(--line); }
}

/* month and week pages */
main { max-width: 1200px; margin: 0 auto; padding: 20px 16px 48px; }
.crumbs { font-size: 13px; color: var(--muted); }
.head { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: 8px; }
h1 { font-size: 26px; margin: 4px 0; letter-spacing: -0.02em; }
h2 { font-size: 18px; margin: 28px 0 10px; }
.pager { display: flex; gap: 14px; font-size: 14px; }
.pager .off { color: var(--muted); }
.wrap { overflow-x: auto; border: 1px solid var(--line); border-radius: 12px; background: var(--card); }
table { border-collapse: collapse; width: 100%; }
th { font-size: 12px; color: var(--muted); font-weight: 600; padding: 8px 6px; text-align: center; }

.cal td { border-top: 1px solid var(--line); vertical-align: top; padding: 6px; width: 13.5%; }
.cal td.wk { width: 5.5%; text-align: center; vertical-align: middle; font-size: 13px; white-space: nowrap; }
.cal .day { display: block; color: inherit; border-radius: 8px; padding: 4px; }
.cal a.day:hover { background: var(--code-bg); text-decoration: none; }
.cal .num { font-weight: 600; }
.cal .n { float: right; font-size: 12px; color: var(--muted); }
.cal img { display: block; width: 100%; aspect-ratio: 16 / 9; object-fit: cover; border-radius: 6px; margin-top: 4px; background: var(--code-bg); }
.cal .out { opacity: .35; }

.heat th.h { min-width: 30px; }
.heat td { border-top: 1px solid var(--line); padding: 3px; text-align: center; }
.heat td.d { text-align: left; white-space: nowrap; padding: 6px 10px; font-size: 14px; }
.heat a, .heat span.e { display: block; min-width: 28px; padding: 5px 0; border-radius: 5px; font-size: 12px; font-variant-numeric: tabular-nums; }
.heat a { color: var(--text); }
.heat a:hover { outline: 2px solid var(--accent); text-decoration: none; }
.heat .l1 { background: var(--heat1); } .heat .l2 { background: var(--heat2); }
.heat .l3 { background: var(--heat3); color: var(--heat-text); } .heat .l4 { background: var(--heat4); color: var(--heat-text); }
.heat a.sel { outline: 3px solid var(--text); }
.heat tr.selday td.d { font-weight: 700; color: var(--accent); }

/* week page: header and compact table stay put, the hour's screenshots scroll */
main.week { display: flex; flex-direction: column; height: 100vh; padding-top: 12px; padding-bottom: 12px; }
main.week > * { flex: none; }
main.week h1 { font-size: 22px; margin: 2px 0; }
main.week p { margin: 2px 0 8px; font-size: 13px; }
main.week .heat th { padding: 3px 1px; font-size: 11px; }
main.week .heat td { padding: 1px 2px; }
main.week .heat td.d { padding: 2px 8px; font-size: 13px; }
main.week .heat a, main.week .heat span.e { min-width: 20px; padding: 2px 0; font-size: 11px; }
main.week #hour { flex: 1; min-height: 0; display: flex; flex-direction: column; }
main.week #hour h2 { margin: 10px 0 8px; font-size: 16px; }
main.week .shots { flex: 1; min-height: 0; overflow-y: auto; align-content: start; padding: 2px 4px 12px 2px;
  grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); }
@media (max-width: 700px), (max-height: 520px) {
  main.week { height: auto; display: block; }
  main.week .shots { overflow: visible; }
}

.hourbar { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: 8px; }
.hourbar button { font: inherit; font-size: 14px; color: var(--accent); background: none; border: 0; cursor: pointer; padding: 0 0 0 12px; }
.hourbar button:disabled { color: var(--muted); cursor: default; }
.shots { display: grid; gap: 12px; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); }
.shots figure { margin: 0; }
.shots img { display: block; width: 100%; aspect-ratio: 16 / 9; object-fit: cover; border-radius: 8px; cursor: zoom-in; background: var(--code-bg); border: 1px solid var(--line); }
.shots figcaption { font-size: 13px; color: var(--muted); margin-top: 3px; }
.hint { color: var(--muted); font-size: 14px; }

/* zoomed screenshot */
.lightbox { position: fixed; inset: 0; z-index: 10; background: rgba(0, 0, 0, .9); display: flex; flex-direction: column; }
.lightbox[hidden] { display: none; }
.lb-bar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px; padding: 10px 14px; color: #f2f2f4; }
.lb-bar .lb-actions { display: flex; gap: 6px; }
.lb-bar button, .lb-bar a { font: 600 14px -apple-system, sans-serif; color: #f2f2f4; background: rgba(255, 255, 255, .12); border: 0; border-radius: 8px; padding: 6px 12px; cursor: pointer; }
.lb-bar a:hover, .lb-bar button:hover { background: rgba(255, 255, 255, .24); text-decoration: none; }
.lb-bar button:disabled { opacity: .35; cursor: default; }
.lb-img { flex: 1; min-height: 0; width: 100%; object-fit: contain; padding: 0 12px 12px; }
"""

JS = """\
// Shared by the gallery's month and week pages: tells the index which view is
// open, draws a week page's hour grid from its #YYYY-MM-DDTHH link, and shows
// a clicked screenshot zoomed with Prev/Next, Open and Save.
(function () {
  'use strict';
  var $ = function (s, el) { return (el || document).querySelector(s); };
  var DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  var url = function (name) { return encodeURIComponent(name); };
  var fmtDay = function (d) {
    var t = new Date(d + 'T00:00');
    return DAYS[t.getDay()] + ' ' + t.getDate() + ' ' + MONTHS[t.getMonth()] + ' ' + t.getFullYear();
  };
  var hhmm = function (s) { return s.slice(0, 2) + ':' + s.slice(2, 4); };

  if (window.parent !== window) {
    var parts = location.pathname.split('/');
    window.parent.postMessage({ gallery: parts.slice(-2).join('/') }, '*');
  }

  // --- zoomed screenshot ---
  var box = document.createElement('div');
  box.className = 'lightbox';
  box.hidden = true;
  box.innerHTML = '<div class="lb-bar"><span class="lb-cap"></span><span class="lb-actions">' +
    '<button data-a="prev">&lsaquo; Prev</button><button data-a="next">Next &rsaquo;</button>' +
    '<a class="lb-open" target="_blank">Open</a><a class="lb-save" download>Save</a>' +
    '<button data-a="close">&times;</button></span></div><img class="lb-img" alt="">';
  document.body.appendChild(box);
  var shots = [], at = 0;

  function show(i) {
    at = i;
    var name = shots[i];
    $('.lb-img', box).src = url(name);
    $('.lb-open', box).href = url(name);
    $('.lb-save', box).href = url(name);
    $('.lb-save', box).setAttribute('download', name);
    $('.lb-cap', box).textContent = fmtDay(name.slice(0, 10)) + ', ' + hhmm(name.slice(11, 15)) +
      '  (' + (i + 1) + ' of ' + shots.length + ')';
    $('[data-a=prev]', box).disabled = i === 0;
    $('[data-a=next]', box).disabled = i === shots.length - 1;
  }
  function zoom(list, i) { shots = list; box.hidden = false; show(i); }
  function close() { box.hidden = true; $('.lb-img', box).removeAttribute('src'); }
  box.addEventListener('click', function (e) {
    var a = e.target.getAttribute('data-a');
    if (a === 'prev' && at > 0) show(at - 1);
    else if (a === 'next' && at < shots.length - 1) show(at + 1);
    else if (a === 'close' || e.target === box) close();
  });
  document.addEventListener('keydown', function (e) {
    if (box.hidden) return;
    if (e.key === 'Escape') close();
    else if (e.key === 'ArrowLeft' && at > 0) show(at - 1);
    else if (e.key === 'ArrowRight' && at < shots.length - 1) show(at + 1);
  });

  // --- week page: hour grid ---
  var W = window.WEEK;
  if (!W) return;
  var slots = [];   // [day, hour] pairs that have screenshots, in order
  Object.keys(W.days).sort().forEach(function (d) {
    Object.keys(W.days[d]).sort().forEach(function (h) { slots.push([d, h]); });
  });

  function render() {
    var m = /^#(\\d{4}-\\d\\d-\\d\\d)(?:T(\\d\\d))?$/.exec(location.hash);
    var day = m && m[1], hour = m && m[2];
    document.querySelectorAll('.heat .sel').forEach(function (a) { a.classList.remove('sel'); });
    document.querySelectorAll('.heat tr.selday').forEach(function (r) { r.classList.remove('selday'); });
    var row = day && document.getElementById('d' + day);
    if (row) row.classList.add('selday');
    var sec = $('#hour');
    if (!hour || !W.days[day] || !W.days[day][hour]) {
      sec.innerHTML = '<p class="hint">' + (row ? 'Pick an hour in ' + fmtDay(day) + '\\u2019s row' :
        'Pick an hour in the table') + ' to see its screenshots.</p>';
      return;
    }
    var cell = document.querySelector('.heat a[href="#' + day + 'T' + hour + '"]');
    if (cell) cell.classList.add('sel');
    var names = W.days[day][hour].map(function (t) { return day + ' ' + t + '.png'; });
    var i = slots.findIndex(function (s) { return s[0] === day && s[1] === hour; });
    var prev = slots[i - 1], next = slots[i + 1];
    var link = function (s) { return s ? '#' + s[0] + 'T' + s[1] : ''; };
    sec.innerHTML = '<div class="hourbar"><h2>' + fmtDay(day) + ', ' + hour + ':00\\u2013' + hour + ':59 ' +
      '<span class="muted">\\u00b7 ' + names.length + ' screenshot' + (names.length === 1 ? '' : 's') + '</span></h2>' +
      '<span><button data-go="' + link(prev) + '"' + (prev ? '' : ' disabled') + '>&lsaquo; Previous hour</button>' +
      '<button data-go="' + link(next) + '"' + (next ? '' : ' disabled') + '>Next hour &rsaquo;</button></span></div>' +
      '<div class="shots">' + names.map(function (n, k) {
        return '<figure><img loading="lazy" src="' + url(n) + '" alt="' + n + '" data-k="' + k + '">' +
          '<figcaption>' + hhmm(n.slice(11, 15)) + '</figcaption></figure>';
      }).join('') + '</div>';
    sec.querySelectorAll('img').forEach(function (img) {
      img.addEventListener('click', function () { zoom(names, +img.getAttribute('data-k')); });
    });
    sec.querySelectorAll('button[data-go]').forEach(function (b) {
      b.addEventListener('click', function () { if (b.getAttribute('data-go')) location.hash = b.getAttribute('data-go'); });
    });
  }
  window.addEventListener('hashchange', render);
  render();
})();
"""


# -----------------------------------------------------------------------------
# print_usage
#   Purpose : Print the usage text from this script's header.
#   Input   : stream - where to print (default stdout)
#   Output  : the header without comment markers
# -----------------------------------------------------------------------------
def print_usage(stream=sys.stdout):
    with open(os.path.realpath(__file__)) as fh:
        lines = fh.read().splitlines()[2:]
    for line in lines:
        if line.startswith("# ====="):
            break
        stream.write(re.sub(r"^# ?", "", line) + "\n")


# -----------------------------------------------------------------------------
# parse_args
#   Purpose : Read command-line options.
#   Input   : argv - the script's arguments (without the program name)
#   Output  : dict with local_dir, all; on /? prints usage and exits 0; on a
#             bad argument prints usage to stderr and exits 2
# -----------------------------------------------------------------------------
def parse_args(argv):
    opts = {"local_dir": LOCAL_DIR, "all": False}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("/?", "-h", "--help"):
            print_usage()
            sys.exit(0)
        if arg == "--all":
            opts["all"] = True
            i += 1
            continue
        if arg == "--local-dir" and i + 1 < len(argv):
            opts["local_dir"] = argv[i + 1]
            i += 2
            continue
        print(f"Unknown argument: {arg}", file=sys.stderr)
        print_usage(sys.stderr)
        sys.exit(2)
    return opts


# -----------------------------------------------------------------------------
# scan
#   Purpose : Index the screenshots in every month folder.
#   Input   : local_dir - the backup folder
#   Output  : {"YYYY-MM": {"YYYY-MM-DD": {"HH": ["HHMMSS", ...]}}}, sorted
#             lists; raises OSError if local_dir can't be read
# -----------------------------------------------------------------------------
def scan(local_dir):
    months = {}
    for entry in os.scandir(local_dir):
        if not (entry.is_dir() and MONTH.match(entry.name)):
            continue
        days = {}
        for f in os.scandir(entry.path):
            m = SHOT.match(f.name)
            if m and f.name.startswith(entry.name):
                days.setdefault(m.group(1), {}).setdefault(m.group(2), []).append(
                    m.group(2) + m.group(3) + m.group(4))
        for hours in days.values():
            for times in hours.values():
                times.sort()
        if days:
            months[entry.name] = days
    return months


# -----------------------------------------------------------------------------
# month_weeks
#   Purpose : Split a month into calendar rows, Sunday to Saturday.
#   Input   : ym - "YYYY-MM"
#   Output  : list of (week_number, [7 dates]); dates outside the month are
#             included so the calendar rows are complete
# -----------------------------------------------------------------------------
def month_weeks(ym):
    cal = calendar.Calendar(firstweekday=6)
    return list(enumerate(cal.monthdatescalendar(int(ym[:4]), int(ym[5:])), 1))


# -----------------------------------------------------------------------------
# week_label
#   Purpose : Human label for the in-month days of a week row.
#   Input   : dates - the in-month dates of the week, in order
#   Output  : e.g. "15 – 21 Nov", or "30 Nov" for a single day
# -----------------------------------------------------------------------------
def week_label(dates):
    first, last = dates[0], dates[-1]
    mon = first.strftime("%b")
    return f"{first.day} {mon}" if first == last else f"{first.day} – {last.day} {mon}"


# -----------------------------------------------------------------------------
# signature
#   Purpose : Fingerprint the data a page shows, so unchanged pages are kept.
#   Input   : payload - JSON-serialisable data the page is built from
#   Output  : 16 hex characters
# -----------------------------------------------------------------------------
def signature(payload):
    raw = json.dumps([GEN_VERSION, payload], sort_keys=True, default=str)
    return hashlib.sha1(raw.encode()).hexdigest()[:16]


# -----------------------------------------------------------------------------
# write_page
#   Purpose : Write a file atomically unless it already carries the same
#             signature (or the same content, for files without one).
#   Input   : path; content - full text; sig - signature or None; force -
#             rewrite regardless
#   Output  : the file at path; returns True if it was written
# -----------------------------------------------------------------------------
def write_page(path, content, sig=None, force=False):
    if not force and os.path.exists(path):
        with open(path, errors="replace") as fh:
            old = fh.read() if sig is None else fh.read(2048)
        if (sig is None and old == content) or (sig is not None and SIG.search(old)
                                                and SIG.search(old).group(1) == sig):
            return False
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(content)
    os.replace(tmp, path)
    return True


# -----------------------------------------------------------------------------
# shell
#   Purpose : Wrap a page body in the common HTML document.
#   Input   : title; body - inner HTML; sig; up - path prefix to the gallery
#             root ("" or "../"); script - extra inline script before
#             gallery.js, or None to leave gallery.js out
#   Output  : the full HTML text
# -----------------------------------------------------------------------------
def shell(title, body, sig, up, script=""):
    js = "" if script is None else f"{script}<script src=\"{up}gallery.js\"></script>\n"
    return (f"<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            f"<meta name=\"gallery-sig\" content=\"{sig}\">\n"
            f"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            f"<title>{html.escape(title)}</title>\n<link rel=\"stylesheet\" href=\"{up}gallery.css\">\n"
            f"</head>\n<body>\n{body}\n{js}</body>\n</html>\n")


# -----------------------------------------------------------------------------
# pager
#   Purpose : Previous/next links for a month or week page.
#   Input   : prev, nxt - (href, label) or None
#   Output  : HTML for the pager
# -----------------------------------------------------------------------------
def pager(prev, nxt):
    def link(item, arrow_left):
        if not item:
            return f'<span class="off">{"&lsaquo; " if arrow_left else ""}{"Previous" if arrow_left else "Next"}{"" if arrow_left else " &rsaquo;"}</span>'
        href, label = item
        text = f"&lsaquo; {html.escape(label)}" if arrow_left else f"{html.escape(label)} &rsaquo;"
        return f'<a href="{href}">{text}</a>'
    return f'<div class="pager">{link(prev, True)}{link(nxt, False)}</div>'


# -----------------------------------------------------------------------------
# render_week
#   Purpose : Build a week page: a day x hour table of screenshot counts; the
#             hour grid and zoom are drawn by gallery.js from window.WEEK.
#   Input   : ym; n - week number; dates - in-month dates; days - the month's
#             scan data; prev, nxt - pager entries with hrefs relative to
#             this month folder
#   Output  : (html, sig)
# -----------------------------------------------------------------------------
def render_week(ym, n, dates, days, prev, nxt):
    data = {d.isoformat(): days[d.isoformat()] for d in dates if d.isoformat() in days}
    sig = signature({"week": [ym, n], "dates": dates, "data": data, "prev": prev, "next": nxt})
    month_name = dates[0].strftime("%B %Y")
    total = sum(len(t) for h in data.values() for t in h.values())
    head = "".join(f'<th class="h">{h:02d}</th>' for h in range(24))
    rows = []
    for d in dates:
        key = d.isoformat()
        cells = []
        for h in range(24):
            times = data.get(key, {}).get(f"{h:02d}")
            if times:
                level = 4 if len(times) >= 12 else 3 if len(times) >= 8 else 2 if len(times) >= 4 else 1
                cells.append(f'<td><a class="l{level}" href="#{key}T{h:02d}" '
                             f'title="{len(times)} screenshots">{len(times)}</a></td>')
            else:
                cells.append('<td><span class="e"></span></td>')
        rows.append(f'<tr id="d{key}"><td class="d"><a href="#{key}">{d.strftime("%a %d")}</a></td>'
                    + "".join(cells) + "</tr>")
    body = (f'<main class="week">\n<div class="crumbs">{ALL_LINK} &rsaquo; <a href="index.html">{month_name}</a> &rsaquo; Week {n}</div>\n'
            f'<div class="head"><h1>Week {n} <span class="muted">· {week_label(dates)}</span></h1>'
            f'{pager(prev, nxt)}</div>\n'
            f'<p class="muted">{total:,} screenshots. Click an hour to see its screenshots; click a screenshot to zoom and save.</p>\n'
            f'<div class="wrap"><table class="heat"><thead><tr><th></th>{head}</tr></thead>\n<tbody>\n'
            + "\n".join(rows) + '\n</tbody></table></div>\n<section id="hour"></section>\n</main>')
    script = f"<script>window.WEEK = {json.dumps({'month': ym, 'days': data}, separators=(',', ':'))};</script>\n"
    return shell(f"Week {n}, {month_name} - sconsole screenshots", body, sig, "../", script), sig


# -----------------------------------------------------------------------------
# render_month
#   Purpose : Build a month page: a Sunday-to-Saturday calendar with each
#             day's screenshot count and a midday thumbnail, linking to the
#             week pages.
#   Input   : ym; weeks - from month_weeks; days - the month's scan data;
#             prev, nxt - pager entries with hrefs relative to this folder
#   Output  : (html, sig)
# -----------------------------------------------------------------------------
def render_month(ym, weeks, days, prev, nxt):
    counts = {d: sum(len(t) for t in h.values()) for d, h in days.items()}
    thumbs = {}
    for d, hours in days.items():
        times = [t for h in sorted(hours) for t in hours[h]]
        thumbs[d] = min(times, key=lambda t: abs(int(t[:2]) * 60 + int(t[2:4]) - 12 * 60))
    sig = signature({"month": ym, "counts": counts, "thumbs": thumbs, "prev": prev, "next": nxt})
    first = date(int(ym[:4]), int(ym[5:]), 1)
    head = "<th></th>" + "".join(f"<th>{d}</th>" for d in ("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"))
    rows = []
    for n, week in weeks:
        has = any(d.isoformat() in days for d in week if d.month == first.month)
        wk = f'<a href="week-{n}.html">Week {n}</a>' if has else f'<span class="muted">Week {n}</span>'
        cells = [f'<td class="wk">{wk}</td>']
        for d in week:
            key = d.isoformat()
            if d.month != first.month:
                cells.append(f'<td class="out"><span class="day"><span class="num">{d.day}</span></span></td>')
            elif key in days:
                img = f"{key} {thumbs[key]}.png"
                cells.append(f'<td><a class="day" href="week-{n}.html#{key}"><span class="num">{d.day}</span>'
                             f'<span class="n">{counts[key]}</span>'
                             f'<img loading="lazy" src="{html.escape(img.replace(" ", "%20"))}" alt="{key}"></a></td>')
            else:
                cells.append(f'<td><span class="day muted"><span class="num">{d.day}</span></span></td>')
        rows.append("<tr>" + "".join(cells) + "</tr>")
    total = sum(counts.values())
    body = (f'<main>\n<div class="crumbs">{ALL_LINK} &rsaquo; {first.year}</div>\n'
            f'<div class="head"><h1>{first.strftime("%B %Y")}</h1>{pager(prev, nxt)}</div>\n'
            f'<p class="muted">{total:,} screenshots on {len(days)} days. Click a week or a day to open it.</p>\n'
            f'<div class="wrap"><table class="cal"><thead><tr>{head}</tr></thead>\n<tbody>\n'
            + "\n".join(rows) + "\n</tbody></table></div>\n</main>")
    return shell(f"{first.strftime('%B %Y')} - sconsole screenshots", body, sig, "../"), sig


# -----------------------------------------------------------------------------
# render_index
#   Purpose : Build the gallery's index: a year > month > week tree with a
#             view pane that opens the newest week.
#   Input   : tree - [(ym, total, [(n, label, count)])] oldest first
#   Output  : (html, sig)
# -----------------------------------------------------------------------------
def render_index(tree):
    sig = signature({"tree": tree})
    newest = tree[-1]
    start = f"{newest[0]}/week-{newest[2][-1][0]}.html"
    total = sum(t for _, t, _ in tree)
    years = {}
    for ym, count, weeks in tree:
        years.setdefault(ym[:4], []).append((ym, count, weeks))
    parts = []
    for y in sorted(years, reverse=True):
        ycount = sum(c for _, c, _ in years[y])
        parts.append(f'<details class="year"{" open" if y == newest[0][:4] else ""}>'
                     f'<summary>{y} <span class="count">{ycount:,}</span></summary>')
        for ym, count, weeks in reversed(years[y]):
            name = date(int(ym[:4]), int(ym[5:]), 1).strftime("%B")
            parts.append(f'<details class="month"{" open" if ym == newest[0] else ""}><summary>'
                         f'<a href="{ym}/index.html" target="view">{name}</a> <span class="count">{count:,}</span></summary>'
                         '<ul class="weeks">')
            for n, label, wcount in weeks:
                parts.append(f'<li><a href="{ym}/week-{n}.html" target="view">Week {n} '
                             f'<span class="muted">{html.escape(label)}</span><span class="count">{wcount:,}</span></a></li>')
            parts.append("</ul></details>")
        parts.append("</details>")
    body = (f'<div class="app">\n<nav class="tree">\n<h1>sconsole screenshots</h1>\n'
            f'<p class="sub">{total:,} screenshots · newest {html.escape(newest[2][-1][1])} {newest[0][:4]}</p>\n'
            + "\n".join(parts) + f'\n</nav>\n<iframe class="view" name="view" src="{start}" title="Screenshots"></iframe>\n</div>')
    script = """<script>
// Highlight the open view in the tree; the view pages post their path here
window.addEventListener('message', function (e) {
  var page = e.data && e.data.gallery;
  if (!page) return;
  document.querySelectorAll('.tree .current').forEach(function (a) { a.classList.remove('current'); });
  var a = document.querySelector('.tree a[href="' + page + '"]');
  if (!a) return;
  a.classList.add('current');
  for (var el = a.parentElement; el; el = el.parentElement) if (el.tagName === 'DETAILS') el.open = true;
  a.scrollIntoView({ block: 'nearest' });
});
</script>
"""
    return shell("sconsole screenshots", body, sig, "", None).replace("</body>", script + "</body>"), sig


# --- main ---
if __name__ == "__main__":
    opts = parse_args(sys.argv[1:])
    root = opts["local_dir"]
    try:
        months = scan(root)
    except OSError as e:
        print(f"cannot read {root}: {e}", file=sys.stderr)
        sys.exit(1)
    if not months:
        print(f"no screenshots under {root}; nothing to do")
        sys.exit(0)

    written = 0
    written += write_page(f"{root}/gallery.css", CSS, force=opts["all"])
    written += write_page(f"{root}/gallery.js", JS, force=opts["all"])

    # Every week with screenshots, in order, for the tree and the week pagers
    yms = sorted(months)
    all_weeks = []
    for ym in yms:
        for n, week in month_weeks(ym):
            dates = [d for d in week if d.strftime("%Y-%m") == ym]
            count = sum(len(t) for d in dates for t in months[ym].get(d.isoformat(), {}).values())
            if count:
                all_weeks.append((ym, n, dates, count))

    def week_href(item, from_ym):
        ym, n = item[0], item[1]
        return f"week-{n}.html" if ym == from_ym else f"../{ym}/week-{n}.html"

    for i, (ym, n, dates, _) in enumerate(all_weeks):
        prev = all_weeks[i - 1] if i > 0 else None
        nxt = all_weeks[i + 1] if i + 1 < len(all_weeks) else None
        page, sig = render_week(
            ym, n, dates, months[ym],
            (week_href(prev, ym), f"Week {prev[1]}" + ("" if prev[0] == ym else f", {date.fromisoformat(prev[0] + '-01'):%b}")) if prev else None,
            (week_href(nxt, ym), f"Week {nxt[1]}" + ("" if nxt[0] == ym else f", {date.fromisoformat(nxt[0] + '-01'):%b}")) if nxt else None)
        written += write_page(f"{root}/{ym}/week-{n}.html", page, sig, opts["all"])

    for i, ym in enumerate(yms):
        label = lambda m: date.fromisoformat(m + "-01").strftime("%b %Y")
        prev = (f"../{yms[i - 1]}/index.html", label(yms[i - 1])) if i > 0 else None
        nxt = (f"../{yms[i + 1]}/index.html", label(yms[i + 1])) if i + 1 < len(yms) else None
        page, sig = render_month(ym, month_weeks(ym), months[ym], prev, nxt)
        written += write_page(f"{root}/{ym}/index.html", page, sig, opts["all"])

    tree = []
    for ym in yms:
        weeks = [(n, week_label(dates), count) for wym, n, dates, count in all_weeks if wym == ym]
        tree.append((ym, sum(c for _, _, c in weeks), weeks))
    page, sig = render_index(tree)
    written += write_page(f"{root}/index.html", page, sig, opts["all"])

    print(f"gallery: {written} page(s) written, {len(all_weeks)} weeks in {len(yms)} months")
