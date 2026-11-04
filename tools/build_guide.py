#!/usr/bin/env python3
"""
EN: Embeds the tool files (as a ZIP and as individual files) into docs/QuickGuide.html,
    so the guide works as a self-contained download page, even offline.
    Run this after changing any tool file:  python3 tools/build_guide.py
JP: ツール一式 (ZIP と個別ファイル) を docs/QuickGuide.html に埋め込み、
    オフラインでも使えるダウンロードページにする。ツールのファイルを変更したら実行する。
"""
import base64
import datetime
import io
import json
import pathlib
import re
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
GUIDE = ROOT / 'docs' / 'QuickGuide.html'

# (path in repo, name in ZIP, description key in the guide, also offered as an individual download)
FILES = [
    ('CatiaIdleGuard.ps1',                 'CatiaIdleGuard.ps1',            'f_main',   True),
    ('config.json',                        'config.json',                   'f_cfg',    True),
    ('Start-CatiaIdleGuard.bat',           'Start-CatiaIdleGuard.bat',      'f_start',  True),
    ('Test-CatiaIdleGuard.bat',            'Test-CatiaIdleGuard.bat',       'f_test',   True),
    ('Install-Startup.ps1',                'Install-Startup.ps1',           'f_inst',   True),
    ('Install-AllUsers.ps1',               'Install-AllUsers.ps1',          'f_admin',  True),
    ('README.md',                          'README.md',                     'f_readme', True),
    ('docs/CatiaIdleGuard_QuickGuide.pdf', 'CatiaIdleGuard_QuickGuide.pdf', 'f_pdf',    False),
]
TEXT_EXT = {'.ps1', '.bat', '.json', '.md'}
MIME = {'.ps1': 'text/plain', '.bat': 'text/plain', '.json': 'application/json',
        '.md': 'text/markdown', '.pdf': 'application/pdf'}


def load(path: pathlib.Path) -> bytes:
    data = path.read_bytes()
    if path.suffix.lower() in TEXT_EXT:
        # Windows line endings for Notepad / cmd.exe (BOM, if any, is kept as is)
        data = data.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
    return data


def main() -> None:
    now = datetime.datetime.now()
    buf = io.BytesIO()
    singles = []
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel, name, key, single in FILES:
            data = load(ROOT / rel)
            info = zipfile.ZipInfo(name, date_time=now.timetuple()[:6])
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, data)
            if single:
                singles.append({'name': name, 'key': key, 'size': len(data),
                                'mime': MIME.get(pathlib.Path(name).suffix.lower(), 'application/octet-stream'),
                                'b64': base64.b64encode(data).decode('ascii')})
    zbytes = buf.getvalue()
    payload = {
        'built': now.strftime('%Y-%m-%d'),
        'zip': {'name': 'CatiaIdleGuard.zip', 'size': len(zbytes),
                'b64': base64.b64encode(zbytes).decode('ascii')},
        'files': singles,
    }
    html = GUIDE.read_text(encoding='utf-8')
    pattern = re.compile(r'(<script type="application/json" id="payload">)(.*?)(</script>)', re.S)
    if not pattern.search(html):
        raise SystemExit('payload <script> not found in QuickGuide.html')
    html = pattern.sub(lambda m: m.group(1) + json.dumps(payload, separators=(',', ':')) + m.group(3), html, count=1)
    GUIDE.write_text(html, encoding='utf-8')
    print(f'ZIP {len(zbytes) / 1024:.1f} KB, {len(singles)} individual files, guide {GUIDE.stat().st_size / 1024:.0f} KB')


if __name__ == '__main__':
    main()
