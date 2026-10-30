"""Verify the compiled Excel project contains only the reviewed VBA source.

Install the pinned development tool with ``python -m pip install oletools==0.60.2``.
This script only reads files; it never opens a workbook in Excel or runs macros.
"""

import argparse
import hashlib
import io
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'assets' / 'vba' / 'FinancialDiary.bas'
PIN_SOURCE = ROOT / 'lib' / 'services' / 'vba_integrity.dart'

arguments = argparse.ArgumentParser(description=__doc__)
arguments.add_argument('project', nargs='?', type=pathlib.Path,
                       default=ROOT / 'assets' / 'vba' / 'vbaProject.bin')
project = arguments.parse_args().project

try:
    import olefile
    from oletools.olevba import VBA_Parser
except ImportError:
    sys.exit('Install oletools==0.60.2 to verify the VBA project.')

pins = re.findall(r"const trustedVbaSha256\s*=\s*'([0-9a-f]{64})'\s*;",
                  PIN_SOURCE.read_text(encoding='utf-8'))
if len(pins) != 1:
    sys.exit('Cannot read the canonical VBA SHA-256 pin.')
try:
    content = project.read_bytes()
except OSError as error:
    sys.exit(f'Cannot read VBA project: {error}')
if not olefile.isOleFile(data=content):
    sys.exit('VBA project must be an OLE compound file.')
if hashlib.sha256(content).hexdigest() != pins[0]:
    sys.exit('VBA project SHA-256 does not match the reviewed pin.')
try:
    with olefile.OleFileIO(io.BytesIO(content), raise_defects=olefile.DEFECT_INCORRECT):
        pass
except (OSError, ValueError) as error:
    sys.exit(f'Invalid OLE compound file: {error}')

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


parser = VBA_Parser(str(project), data=content)
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
