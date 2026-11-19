#!/usr/bin/env python3
"""Writes the Sparkle update feed (appcast.xml) from the repository's GitHub releases.

Each release made by Scripts/release.sh carries Chirp.dmg and sparkle.json (its version, build, channel and
signature). Beta releases go on Sparkle's `beta` channel, which Chirp only reads when "Get beta versions" is on.
Drafts and releases without sparkle.json are left out.

Usage: GH_TOKEN=… python3 -I Scripts/appcast.py owner/repo > Site/appcast.xml
"""
import html
import json
import os
import re
import sys
import urllib.request
from email.utils import format_datetime
from datetime import datetime

API = "https://api.github.com"


def get(url, raw=False):
    request = urllib.request.Request(url, headers={"Accept": "application/octet-stream" if raw else "application/vnd.github+json"})
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request) as response:
        data = response.read()
    return data if raw else json.loads(data)


def notes_html(markdown):
    """Release notes as simple HTML: paragraphs and bullet lists are all Chirp's notes use."""
    out, in_list = [], False
    for line in markdown.splitlines():
        line = line.rstrip()
        bullet = re.match(r"^\s*[-*] (.*)", line)
        if bullet and not in_list:
            out.append("<ul>")
            in_list = True
        if not bullet and in_list:
            out.append("</ul>")
            in_list = False
        text = html.escape(bullet.group(1) if bullet else line.lstrip("# "))
        text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
        if bullet:
            out.append(f"<li>{text}</li>")
        elif text:
            out.append(f"<p>{text}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main():
    repo = sys.argv[1]
    releases = get(f"{API}/repos/{repo}/releases?per_page=50")
    items = []
    for release in releases:
        if release["draft"]:
            continue
        assets = {a["name"]: a for a in release["assets"]}
        if "Chirp.dmg" not in assets or "sparkle.json" not in assets:
            continue
        meta = json.loads(get(assets["sparkle.json"]["url"], raw=True))
        published = datetime.fromisoformat(release["published_at"].replace("Z", "+00:00"))
        channel = f"\n      <sparkle:channel>{meta['channel']}</sparkle:channel>" if meta.get("channel") else ""
        items.append(f"""    <item>
      <title>Chirp {html.escape(meta['version'])}</title>
      <pubDate>{format_datetime(published)}</pubDate>
      <link>{html.escape(release['html_url'])}</link>
      <sparkle:version>{meta['build']}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(meta['version'])}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{meta['minimumSystemVersion']}</sparkle:minimumSystemVersion>{channel}
      <description><![CDATA[{notes_html(release.get('body') or '')}]]></description>
      <enclosure url="{html.escape(assets['Chirp.dmg']['browser_download_url'])}" length="{meta['length']}" type="application/x-apple-diskimage" sparkle:edSignature="{meta['edSignature']}"/>
    </item>""")
    print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Chirp</title>
    <link>https://github.com/{repo}</link>
    <description>Updates for Chirp</description>
    <language>en</language>
{chr(10).join(items)}
  </channel>
</rss>""")


if __name__ == "__main__":
    main()
