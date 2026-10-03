#!/usr/bin/env python3
"""
Sync release notes from markdown docs (or direct arguments) to website/changelog.html and website/assets/site.js.

Usage:
  python3 scripts/sync_website_changelog.py --doc docs/releases/v1.0.9.md
  python3 scripts/sync_website_changelog.py --latest
  python3 scripts/sync_website_changelog.py --version 1.0.9 --date 2026-08-28 --notes-cn-file /path/to/cn.txt --notes-en-file /path/to/en.txt
"""

import sys
import os
import re
import json
import argparse
from datetime import datetime

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
HTML_PATH = os.path.join(ROOT_DIR, 'website', 'changelog.html')
JS_PATH = os.path.join(ROOT_DIR, 'website', 'assets', 'site.js')
RELEASES_DIR = os.path.join(ROOT_DIR, 'docs', 'releases')


def parse_raw_notes_text(text: str) -> list[str]:
    """Parse notes from text, supporting multiline bullets, escaped newlines, and inline dash delimiters."""
    if not text:
        return []
    
    # Normalize escaped newlines if any
    text = text.replace('\\n', '\n')
    
    lines = text.strip().splitlines()
    parsed = []
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
        
        # If line contains multiple bullet points separated by ' - ' or ' • '
        # e.g., "- item 1 - item 2" or "item 1 - item 2"
        # Check if line starts with bullet
        line = re.sub(r'^([-*•]|\d+[\.\)])\s+', '', line).strip()
        
        # If the line still contains ' - ' (dash with spaces on both sides) separating distinct sentences
        sub_items = re.split(r'\s+[-•]\s+', line)
        for item in sub_items:
            item = item.strip()
            # remove leading bullet if any
            item = re.sub(r'^([-*•]|\d+[\.\)])\s+', '', item).strip()
            if item:
                parsed.append(item)
                
    return parsed


def extract_notes_from_doc(doc_path: str):
    """Extract version, date, and cn/en release notes from markdown file."""
    if not os.path.isfile(doc_path):
        raise FileNotFoundError(f"Release doc not found: {doc_path}")

    with open(doc_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Extract version
    version_match = re.search(r'Prepared version:\s*([0-9]+\.[0-9]+\.[0-9]+)', content)
    if not version_match:
        version_match = re.search(r'Next candidate version:\s*([0-9]+\.[0-9]+\.[0-9]+)', content)
    if not version_match:
        version_match = re.search(r'# Release v?([0-9]+\.[0-9]+\.[0-9]+)', content)
    if not version_match:
        # Try from filename
        fn_match = re.search(r'v?([0-9]+\.[0-9]+\.[0-9]+)', os.path.basename(doc_path))
        if fn_match:
            version = fn_match.group(1)
        else:
            version = None
    else:
        version = version_match.group(1)

    # Extract Chinese notes
    cn_match = re.search(r'(?:^|\n)#{2,4}\s*(?:.*?\s+)?(?:中文|Chinese)\s*\n(.*?)(?=\n#{2,3}\s+|\Z)', content, flags=re.DOTALL | re.IGNORECASE)
    cn_text = cn_match.group(1) if cn_match else ''
    cn_notes = parse_raw_notes_text(cn_text)

    # Extract English notes
    en_match = re.search(r'(?:^|\n)#{2,4}\s*(?:.*?\s+)?(?:English|英文)\s*\n(.*?)(?=\n#{2,3}\s+|\Z)', content, flags=re.DOTALL | re.IGNORECASE)
    en_text = en_match.group(1) if en_match else ''
    en_notes = parse_raw_notes_text(en_text)

    # Fallback date
    date_match = re.search(r'(\d{4}-\d{2}-\d{2})', os.path.basename(doc_path))
    if date_match:
        release_date = date_match.group(1)
    else:
        release_date = datetime.now().strftime('%Y-%m-%d')

    return version, release_date, cn_notes, en_notes


def version_to_key(version: str) -> str:
    return 'v' + re.sub(r'[^0-9a-zA-Z]', '', version)


def update_changelog_html(html_path: str, target_version: str, release_date: str, cn_notes: list[str]):
    if not os.path.isfile(html_path):
        print(f"HTML file not found: {html_path}", file=sys.stderr)
        return

    with open(html_path, 'r', encoding='utf-8') as f:
        html_content = f.read()

    v_key = version_to_key(target_version)

    # 1. Update stat1Value
    html_content = re.sub(
        r'(<strong[^>]*data-i18n="changelogPage\.stat1Value"[^>]*>)([^<]*)(</strong>)',
        rf'\g<1>v{target_version}\g<3>',
        html_content
    )

    card_items_html = []
    for i, item in enumerate(cn_notes, 1):
        card_items_html.append(
            f'              <div class="feature-list-item"><span data-i18n="changelogPage.{v_key}Item{i}">{item}</span></div>'
        )
    items_block = "\n".join(card_items_html)

    badge_pattern = f'<span class="icon-badge">{target_version}</span>'

    if badge_pattern in html_content:
        # Existing card for this version -> update it
        card_regex = rf'<article class="card feature-card reveal-on-scroll[^"]*">\s*<span class="icon-badge">{re.escape(target_version)}</span>.*?</article>'
        m = re.search(card_regex, html_content, flags=re.DOTALL)
        if m:
            old_card = m.group(0)
            delay_m = re.search(r'reveal-on-scroll\s+(delay-\d+)', old_card)
            cls = f"reveal-on-scroll {delay_m.group(1)}" if delay_m else "reveal-on-scroll"
            replacement = f'''<article class="card feature-card {cls}">
            <span class="icon-badge">{target_version}</span>
            <h3 data-i18n="changelogPage.{v_key}Title">v{target_version}</h3>
            <p data-i18n="changelogPage.{v_key}Date">发布日期：{release_date}</p>
            <div class="feature-list">
{items_block}
            </div>
          </article>'''
            html_content = html_content[:m.start()] + replacement + html_content[m.end():]
    else:
        # Insert as newest card
        grid_start = '<div class="feature-grid">'
        if grid_start in html_content:
            pos = html_content.find(grid_start) + len(grid_start)
            html_before = html_content[:pos]
            html_after = html_content[pos:]

            # Re-index delays
            articles = re.findall(r'<article class="card feature-card reveal-on-scroll[^"]*">', html_after)
            for idx, art in enumerate(articles, 1):
                new_art = f'<article class="card feature-card reveal-on-scroll delay-{idx}">'
                html_after = html_after.replace(art, new_art, 1)

            new_card = f'''
          <article class="card feature-card reveal-on-scroll">
            <span class="icon-badge">{target_version}</span>
            <h3 data-i18n="changelogPage.{v_key}Title">v{target_version}</h3>
            <p data-i18n="changelogPage.{v_key}Date">发布日期：{release_date}</p>
            <div class="feature-list">
{items_block}
            </div>
          </article>'''
            html_content = html_before + new_card + html_after

    with open(html_path, 'w', encoding='utf-8') as f:
        f.write(html_content)
    print(f"Updated {html_path} for v{target_version}")


def update_site_js(js_path: str, target_version: str, release_date: str, cn_notes: list[str], en_notes: list[str]):
    if not os.path.isfile(js_path):
        print(f"JS file not found: {js_path}", file=sys.stderr)
        return

    with open(js_path, 'r', encoding='utf-8') as f:
        js_content = f.read()

    v_key = version_to_key(target_version)

    def build_zh_entries():
        lines = [
            f"      {v_key}Title: 'v{target_version}',",
            f"      {v_key}Date: '发布日期：{release_date}',"
        ]
        for i, item in enumerate(cn_notes, 1):
            escaped = item.replace("'", "\\'")
            lines.append(f"      {v_key}Item{i}: '{escaped}',")
        return "\n".join(lines)

    def build_en_entries():
        lines = [
            f"      {v_key}Title: 'v{target_version}',",
            f"      {v_key}Date: 'Released: {release_date}',"
        ]
        for i, item in enumerate(en_notes, 1):
            escaped = item.replace("'", "\\'")
            lines.append(f"      {v_key}Item{i}: '{escaped}',")
        return "\n".join(lines)

    def update_changelog_block(content, lang, entries_func):
        split_marker = '\n  en: {'
        split_idx = content.find(split_marker)
        if split_idx == -1:
            return content

        if lang == 'zh':
            target_part = content[:split_idx]
            other_part = content[split_idx:]
        else:
            other_part = content[:split_idx]
            target_part = content[split_idx:]

        m_block = re.search(r'(changelogPage:\s*\{)(.*?)(\n    \},|\n    notFoundPage:)', target_part, flags=re.DOTALL)
        if not m_block:
            return content

        block_header = m_block.group(1)
        block_body = m_block.group(2)
        block_footer = m_block.group(3)

        # Update stat1Value
        block_body = re.sub(r'(stat1Value:\s*[\'"])(v?[^\'"]+)([\'"])', rf'\g<1>v{target_version}\g<3>', block_body)

        # Remove existing version entry if present
        pattern = r'\n\s*' + re.escape(v_key) + r'Title:.*?(?=\n\s*v\d+Title:|\Z)'
        block_body = re.sub(pattern, '', block_body, flags=re.DOTALL)

        # Insert after stat3Value
        m_stat3 = re.search(r'(stat3Value:\s*[\'"][^\'"]*[\'"],\n)', block_body)
        if m_stat3:
            entries = entries_func()
            block_body = block_body[:m_stat3.end()] + entries + "\n" + block_body[m_stat3.end():]

        new_target_part = target_part[:m_block.start()] + block_header + block_body + block_footer + target_part[m_block.end():]

        if lang == 'zh':
            return new_target_part + other_part
        else:
            return other_part + new_target_part

    js_content = update_changelog_block(js_content, 'zh', build_zh_entries)
    js_content = update_changelog_block(js_content, 'en', build_en_entries)

    with open(js_path, 'w', encoding='utf-8') as f:
        f.write(js_content)
    print(f"Updated {js_path} for v{target_version}")


def main():
    parser = argparse.ArgumentParser(description="Sync release notes to website changelog.")
    parser.add_argument('--doc', type=str, help='Path to release markdown doc (e.g. docs/releases/v1.0.9.md)')
    parser.add_argument('--latest', action='store_true', help='Use docs/releases/latest_app_store_release_notes.md')
    parser.add_argument('--version', type=str, help='Target version (e.g. 1.0.9)')
    parser.add_argument('--date', type=str, help='Release date (YYYY-MM-DD)')
    parser.add_argument('--notes-cn', type=str, help='Chinese release notes')
    parser.add_argument('--notes-cn-file', type=str, help='Path to file containing Chinese release notes')
    parser.add_argument('--notes-en', type=str, help='English release notes')
    parser.add_argument('--notes-en-file', type=str, help='Path to file containing English release notes')

    args = parser.parse_args()

    target_version = args.version
    release_date = args.date or datetime.now().strftime('%Y-%m-%d')
    cn_notes = []
    en_notes = []

    if args.latest:
        args.doc = os.path.join(RELEASES_DIR, 'latest_app_store_release_notes.md')

    if args.doc:
        doc_ver, doc_date, doc_cn, doc_en = extract_notes_from_doc(args.doc)
        target_version = target_version or doc_ver
        release_date = args.date or doc_date
        cn_notes = doc_cn
        en_notes = doc_en

    if args.notes_cn_file and os.path.isfile(args.notes_cn_file):
        with open(args.notes_cn_file, 'r', encoding='utf-8') as f:
            cn_notes = parse_raw_notes_text(f.read())
    elif args.notes_cn:
        cn_notes = parse_raw_notes_text(args.notes_cn)

    if args.notes_en_file and os.path.isfile(args.notes_en_file):
        with open(args.notes_en_file, 'r', encoding='utf-8') as f:
            en_notes = parse_raw_notes_text(f.read())
    elif args.notes_en:
        en_notes = parse_raw_notes_text(args.notes_en)

    if not cn_notes:
        print("Error: No Chinese release notes found or provided.", file=sys.stderr)
        sys.exit(1)

    if not en_notes:
        en_notes = list(cn_notes)

    if not target_version:
        print("Error: Target version could not be determined.", file=sys.stderr)
        sys.exit(1)

    update_changelog_html(HTML_PATH, target_version, release_date, cn_notes)
    update_site_js(JS_PATH, target_version, release_date, cn_notes, en_notes)
    print(f"Successfully synced v{target_version} ({len(cn_notes)} items) to website files.")


if __name__ == '__main__':
    main()
