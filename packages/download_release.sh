#!/usr/bin/env python3
"""
Usage: ./download_release.sh <html_file> <output_dir>

Parses a Confluence release page HTML and recreates the directory structure
locally. Set DRY_RUN=False (or env var DRY_RUN=0) to perform actual downloads
with wget instead of creating empty placeholder files.
"""

import sys
import os
import re
import urllib.parse
import subprocess
from html.parser import HTMLParser

DRY_RUN = os.environ.get('DRY_RUN', '1') != '0'

FILE_EXTS = ('.tar.gz', '.tgz', '.run', '.whl', '.zip', '.tar')


def is_file_url(url):
    path = url.split('?')[0]
    return any(path.endswith(ext) for ext in FILE_EXTS)


def filename_from_url(url):
    path = url.split('?')[0]
    return urllib.parse.unquote(path.split('/')[-1])


def type_to_dirs(type_str):
    """Map a (possibly combined) Chinese type cell to a list of dir names."""
    s = type_str
    dirs = []
    if '继续预训练' in s:
        dirs.append('continue_pretrain')
    if re.search(r'lora', s, re.IGNORECASE):
        dirs.append('lora')
    if '全参' in s:
        dirs.append('fullparam')
    if 'finetune' in s.lower():
        dirs.append('finetune')
    if '预训练' in s and '继续预训练' not in s:
        dirs.append('pretrain')
    # '微调' as standalone (not part of lora微调 or 全参微调) → finetune
    if '微调' in s and 'lora' not in s.lower() and '全参' not in s and '继续' not in s:
        dirs.append('finetune')
    if not dirs:
        safe = re.sub(r'[^\w\-]', '_', type_str).strip('_') or 'misc'
        dirs = [safe]
    return dirs


# ---------------------------------------------------------------------------

class ReleasePageParser(HTMLParser):

    def __init__(self):
        super().__init__()
        # Heading context
        self.h1 = self.h2 = self.h3 = ''
        self._in_heading = False
        self._hlevel = 0
        self._hbuf = ''

        # Table / cell state
        self._in_table = False
        self._in_td = False
        self._tdbuf = ''
        self._td_hrefs = []      # href values collected inside current cell
        self._row_cells = []     # list of (text, [file_hrefs]) for current row

        # Per-table rolling context (updated on primary rows)
        self._cur_model = ''
        self._cur_type = ''
        self._cur_os = ''

        # Results: list of (relative_path, url)
        self.entries = []

    # ---- heading tracking -------------------------------------------------

    def handle_starttag(self, tag, attrs):
        adict = dict(attrs)
        if tag in ('h1', 'h2', 'h3', 'h4'):
            self._in_heading = True
            self._hlevel = int(tag[1])
            self._hbuf = ''
        if tag == 'table':
            self._in_table = True
            self._cur_model = self._cur_type = self._cur_os = ''
        if tag == 'tr' and self._in_table:
            self._row_cells = []
        if tag in ('td', 'th') and self._in_table:
            self._in_td = True
            self._tdbuf = ''
            self._td_hrefs = []
        if tag == 'a' and self._in_td:
            href = adict.get('href', '')
            if href:
                self._td_hrefs.append(href)

    def handle_endtag(self, tag):
        if tag in ('h1', 'h2', 'h3', 'h4') and self._in_heading:
            self._in_heading = False
            text = re.sub(r'\s+', ' ', self._hbuf).strip()
            text = text.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>')
            if self._hlevel == 1:
                self.h1 = text; self.h2 = self.h3 = ''
                self._cur_model = self._cur_type = ''
            elif self._hlevel == 2:
                self.h2 = text; self.h3 = ''
                self._cur_model = self._cur_type = ''
            else:
                self.h3 = text
                self._cur_model = self._cur_type = ''

        if tag == 'table':
            self._in_table = False
            self._cur_model = self._cur_type = ''

        if tag in ('td', 'th') and self._in_td:
            self._in_td = False
            text = re.sub(r'\s+', ' ', self._tdbuf).strip()
            text = text.replace('&amp;', '&')
            file_hrefs = [h for h in self._td_hrefs if is_file_url(h)]
            # Also extract file URLs from plain text (some cells have URLs as
            # text without <a href>, or wrapped in <span class="nolink">)
            text_urls = [u.rstrip('.,;') for u in re.findall(r'https?://\S+', text)
                         if is_file_url(u.rstrip('.,;'))]
            all_hrefs = list(dict.fromkeys(file_hrefs + text_urls))
            self._row_cells.append((text, all_hrefs))

        if tag == 'tr' and self._in_table:
            self._dispatch_row(self._row_cells)
            self._row_cells = []

    def handle_data(self, data):
        if self._in_heading:
            self._hbuf += data
        if self._in_td and self._in_table:
            self._tdbuf += data

    # ---- row dispatch ------------------------------------------------------

    def _dispatch_row(self, cells):
        if not cells:
            return
        texts = [c[0] for c in cells]
        # Skip header rows (cells contain known header keywords)
        if any(t in ('包名', 'Package Name', '模型名称', '包链接', 'MD5', 'Date',
                     'Version', 'OS信息', '涉及源码url', '源码branch', '源码包链接',
                     'Pytorch版本', '类型', 'Package链接', 'Harbor地址') for t in texts):
            return

        h2, h3 = self.h2, self.h3
        if '软件栈安装包' in h2:
            self._row_packages(cells)
        elif '基础镜像' in h2:
            self._row_images(cells)
        elif '模型训练源码包' in h2 and '大模型' in h3:
            self._row_llm(cells)
        elif '模型训练源码包' in h2 and '小模型' in h3:
            self._row_model_codes(cells)
        elif '模型推理源码包' in h2:
            self._row_infer_codes(cells)
        elif 'FW' in self.h1 or 'FLASH' in h2 or 'Brflash' in h2 or 'Brflu' in h2:
            self._row_fw(cells)

    def _add(self, rel_path, url):
        if rel_path and url:
            self.entries.append((rel_path, url))

    # ---- section-specific row handlers ------------------------------------

    def _row_packages(self, cells):
        """
        软件栈安装包 table columns (0-based):
          5-col layout (2604+): 0=行号  1=包名  2=OS信息  3=包链接  4=MD5
          4-col layout (2512):  0=包名  1=OS信息  2=包链接  3=MD5
        OS column value is used directly as the subdirectory name,
        except .whl files always go to packages/whl/.
        """
        file_cells = [(i, c) for i, c in enumerate(cells) if c[1]]
        if not file_cells:
            return
        os_col = 2 if len(cells) >= 5 else 1
        os_info = cells[os_col][0].strip() if len(cells) > os_col else ''
        for _, cell in file_cells:
            for url in cell[1]:
                fname = filename_from_url(url)
                if fname.endswith('.whl'):
                    subdir = 'whl'
                else:
                    subdir = os_info if os_info else 'general'
                self._add(f'packages/{subdir}/{fname}', url)

    def _row_images(self, cells):
        """基础镜像 → images/"""
        for cell in cells:
            for url in cell[1]:
                fname = filename_from_url(url)
                self._add(f'images/{fname}', url)

    def _row_llm(self, cells):
        """
        训练-大模型 table columns:
          0=模型名称  1=类型  2=PT版本  3=源码url  4=源码branch  5=源码包链接
        Continuation rows (rowspan) have only 3 cells: url, branch, pkg_link.
        Track current model/type across continuation rows.
        """
        file_cells = [(i, c) for i, c in enumerate(cells) if c[1]]
        if not file_cells:
            return

        if len(cells) >= 5:
            model = cells[0][0].strip()
            typ   = cells[1][0].strip()
            if model and not model.startswith('http'):
                self._cur_model = model
            if typ and not typ.startswith('http'):
                self._cur_type = typ

        if not self._cur_model:
            return

        model_safe = re.sub(r'[^\w\-.]', '', self._cur_model)
        type_dirs = type_to_dirs(self._cur_type)

        for _, cell in file_cells:
            for url in cell[1]:
                fname = filename_from_url(url)
                for tdir in type_dirs:
                    self._add(f'llm_codes/{model_safe}/{tdir}/{fname}', url)

    def _row_model_codes(self, cells):
        """
        训练-小模型 table columns:
          0=模型名称  1=NA/OS  2=源码url  3=branch  4=包链接
        Continuation rows: 3 cells.
        """
        file_cells = [(i, c) for i, c in enumerate(cells) if c[1]]
        if not file_cells:
            return

        if len(cells) >= 4:
            model = cells[0][0].strip()
            if model and not model.startswith('http'):
                self._cur_model = model

        if not self._cur_model:
            return

        model_safe = re.sub(r'[^\w\-.]', '', self._cur_model)
        for _, cell in file_cells:
            for url in cell[1]:
                fname = filename_from_url(url)
                self._add(f'model_codes/{model_safe}/{fname}', url)

    def _row_infer_codes(self, cells):
        """
        模型推理源码包 columns:
          0=模型名称  1=PT版本  2=源码url  3=branch  4=源码包
        Continuation rows: 3 cells.
        """
        file_cells = [(i, c) for i, c in enumerate(cells) if c[1]]
        if not file_cells:
            return

        if len(cells) >= 4:
            model = cells[0][0].strip()
            if model and not model.startswith('http'):
                self._cur_model = model

        if not self._cur_model:
            return

        model_safe = re.sub(r'[^\w\-.]', '', self._cur_model)
        for _, cell in file_cells:
            for url in cell[1]:
                fname = filename_from_url(url)
                self._add(f'infer_codes/{model_safe}/{fname}', url)

    def _row_fw(self, cells):
        """FW & Brflash → fw_tools/"""
        for cell in cells:
            for url in cell[1]:
                fname = filename_from_url(url)
                self._add(f'fw_tools/{fname}', url)


# ---------------------------------------------------------------------------

def main():
    # Unset proxy vars so wget reaches internal servers directly.
    # Only affects this process and its children, not the system environment.
    for _var in ('http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY',
                 'all_proxy', 'ALL_PROXY', 'no_proxy', 'NO_PROXY'):
        os.environ.pop(_var, None)

    if len(sys.argv) < 3:
        print(f'Usage: {sys.argv[0]} <html_file> <output_dir>', file=sys.stderr)
        print(f'  Set env DRY_RUN=0 to perform actual downloads.', file=sys.stderr)
        sys.exit(1)

    html_file  = sys.argv[1]
    output_dir = sys.argv[2]

    if not os.path.exists(html_file):
        print(f'Error: file not found: {html_file}', file=sys.stderr)
        sys.exit(1)

    with open(html_file, 'r', encoding='utf-8') as f:
        content = f.read()

    start = content.find('id="main-content"')
    if start < 0:
        start = 0

    parser = ReleasePageParser()
    parser.feed(content[start:])

    # Deduplicate (preserve first occurrence)
    seen = set()
    entries = []
    for path, url in parser.entries:
        if path not in seen:
            seen.add(path)
            entries.append((path, url))

    print(f'Found {len(entries)} files')

    failures = []  # list of (full_path, url)
    for i, (rel_path, url) in enumerate(entries, 1):
        full_path = os.path.join(output_dir, rel_path)
        os.makedirs(os.path.dirname(full_path), exist_ok=True)

        if DRY_RUN:
            if not os.path.exists(full_path):
                open(full_path, 'w').close()
            print(f'[DRY-RUN] {full_path}')
        else:
            print(f'[{i}/{len(entries)}] {rel_path}', flush=True)
            r = subprocess.run(
                ['wget', '-q', '-c', '-O', full_path, url],
            )
            if r.returncode != 0:
                failures.append((full_path, url))
                # Remove incomplete download to avoid leaving partial files
                try:
                    os.remove(full_path)
                except FileNotFoundError:
                    pass
                print(f'  FAILED (removed): {rel_path}', file=sys.stderr, flush=True)

    if failures:
        sep = '=' * 60
        print(f'\n{sep}', file=sys.stderr)
        print(f'DOWNLOAD FAILURES: {len(failures)} / {len(entries)} files', file=sys.stderr)
        print(sep, file=sys.stderr)
        for path, url in failures:
            print(f'  PATH: {path}', file=sys.stderr)
            print(f'  URL:  {url}', file=sys.stderr)
            print(file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
