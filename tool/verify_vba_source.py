"""Verify the compiled Excel project contains only the reviewed VBA source.

Install the pinned development tool with ``python -m pip install oletools==0.60.2``.
This script only reads files; it never opens a workbook in Excel or runs macros.
"""

import pathlib
import re
import sys

try:
    from oletools.olevba import VBA_Parser
except ImportError:
    sys.exit('Install oletools==0.60.2 to verify the VBA project.')

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'assets' / 'vba' / 'FinancialDiary.bas'
PROJECT = pathlib.Path(sys.argv[1]) if len(sys.argv) == 2 else ROOT / 'assets' / 'vba' / 'vbaProject.bin'

# VBA is case-insensitive, but quoted text and comments are not normalized.
# Compare each nonempty line separately so a lost line boundary cannot pass.
TOKEN = re.compile(r'"(?:[^"]|"")*"|\'[^\r\n]*|[A-Za-z_][A-Za-z_0-9]*|\d+(?:\.\d+)?|[^\s]')


def normalized(source):
    lines = []
    for line in source.splitlines():
        line = line.strip()
        if not line or line.startswith('Attribute VB_'):
            continue
        tokens = TOKEN.findall(line)
        lines.append(tuple(token if token.startswith(('"', "'")) else token.lower() for token in tokens))
    return lines


parser = VBA_Parser(str(PROJECT))
try:
    modules = list(parser.extract_macros())
finally:
    parser.close()

standard = [(name, code) for _, _, name, code in modules if name.lower().endswith('.bas')]
other_code = [(name, code) for _, _, name, code in modules if not name.lower().endswith('.bas') and normalized(code)]
if len(standard) != 1 or other_code:
    sys.exit('VBA project contains unexpected modules or workbook code.')
if normalized(standard[0][1]) != normalized(SOURCE.read_text(encoding='utf-8')):
    sys.exit('Compiled VBA source does not match FinancialDiary.bas.')
print('Verified VBA source matches FinancialDiary.bas; no other module contains code.')
