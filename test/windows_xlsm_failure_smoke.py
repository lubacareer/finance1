"""Opt-in desktop Excel test for failure cleanup on a synthetic workbook.

Generate a disposable fixture with FINANCE_TEST_XLSM_PATH set while running
test/xlsm_export_test.dart. Then run this script on Windows with pywin32 and
desktop Excel. Acknowledge each expected message box as it appears. The file is
opened read-only and closed without saving; never use a personal workbook.
"""
import os

import win32com.client


path = os.environ['FINANCE_TEST_XLSM_PATH']
excel = win32com.client.DispatchEx('Excel.Application')
excel.Visible = True
excel.DisplayAlerts = False
book = None
try:
    book = excel.Workbooks.Open(path, ReadOnly=True)
    instructions = book.Worksheets('_instructions')
    transactions = book.Worksheets('_transactions')
    monthly = [sheet for sheet in book.Worksheets if len(sheet.Name) == 7
               and sheet.Name[4] == '-' and sheet.Name[:4].isdigit()
               and sheet.Name[5:].isdigit()]
    assert len(monthly) >= 2
    fallback = 'Refresh failed; check workbook data.'
    first = monthly[0]
    second = monthly[1]
    original_date = transactions.Range('C2').Value

    def refresh(case):
        print(f'EXPECTED DIALOG: {case}; acknowledge it to continue.', flush=True)
        excel.Run("'" + book.Name.replace("'", "''") + "'!RefreshSummaries")

    def prepare():
        first.Unprotect()
        for sheet in monthly:
            sheet.Range('B2').Value = 1
            sheet.Range('A3').Value = 'before refresh'
        transactions.Range('C2').Value = original_date
        excel.ScreenUpdating = True

    def verify(expected, protected=False, updating=True):
        assert excel.ScreenUpdating is updating
        for sheet in monthly[1 if protected else 0:]:
            assert sheet.Range('B2').Value == 0, sheet.Name
            assert sheet.Range('A3').Value == expected, sheet.Name
        if protected:
            assert first.Range('B2').Value == 1
            assert first.Range('A3').Value == 'before refresh'

    prepare()
    instructions.Name = '_instructions_renamed'
    transactions.Range('C2').Value = 'not-a-date'
    refresh('renamed instructions')
    verify(fallback)
    instructions.Name = '_instructions'

    for value, expected in [('', fallback), ('   ', fallback),
                            ('=NA()', fallback), ('רענון נכשל', 'רענון נכשל')]:
        prepare()
        if value == '=NA()':
            instructions.Range('A4').Formula = value
        else:
            instructions.Range('A4').Value = value
        first.Protect()
        refresh(f'protected month and instruction {value!r}')
        verify(expected, protected=True)

    prepare()
    instructions.Delete()
    transactions.Range('C2').Value = 'not-a-date'
    excel.ScreenUpdating = False
    refresh('deleted instructions with screen updating originally disabled')
    verify(fallback, updating=False)
    excel.ScreenUpdating = True
    assert second.Range('B2').Value == 0
    print('Excel XLSM failure-cleanup smoke test passed', flush=True)
finally:
    if book is not None:
        book.Close(False)
    excel.Quit()
