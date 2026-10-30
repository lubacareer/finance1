# Excel VBA project

`FinancialDiary.bas` is the reviewed source for the macro project embedded in
exported workbooks. `vbaProject.bin` was compiled in desktop Excel from that
source in a new, disposable blank workbook. Its SHA-256 is:

`0833b8825cce6ce249253816b56e7a348315d3e9f0b2b2e7f1fafd498e185aaa`

The same checksum is recorded beside the asset in `pubspec.yaml`. Never use a
personal workbook or statement to rebuild or test this project, and do not add
temporary workbooks or personal metadata to the repository.

## Release checklist

1. If the source changed, create a new blank `.xlsm` in desktop Excel. Remove
   identifying document properties, import `FinancialDiary.bas` as its only
   standard module in the Visual Basic editor, choose **Debug > Compile
   VBAProject**, and save the disposable workbook. Extract
   `xl/vbaProject.bin` from the workbook ZIP and replace the asset. Review the
   generated binary for personal metadata and unexpected code. Update the two
   checksum references when replacing it.
2. Run `Get-FileHash assets/vba/vbaProject.bin -Algorithm SHA256` in PowerShell
   and compare it with the recorded checksum.
3. Install `oletools==0.60.2` in a development Python environment and run
   `python tool/verify_vba_source.py`. This uses `olevba` to extract and compare
   the embedded VBA text with the reviewed source, and rejects extra code in
   the workbook and sheet modules. A candidate binary can be supplied as the
   script's argument before replacing the asset.
4. On Windows with desktop Excel and `pywin32`, generate a synthetic fixture by
   setting `FINANCE_TEST_XLSM_PATH` to a disposable path and running
   `flutter test --no-pub test/xlsm_export_test.dart`. Then run
   `python test/windows_xlsm_failure_smoke.py` with the same environment
   variable and acknowledge the expected alerts. The test opens the fixture
   read-only and closes without saving. Also exercise refresh and month
   navigation in a synthetic workbook.

Source extraction alone does not prove that compiled VBA behavior matches the
stored source: deliberately altered VBA can contain differing compiled code.
Compile the reviewed source in a clean workbook and perform the Excel checks
above rather than treating source comparison as a substitute for that process.
