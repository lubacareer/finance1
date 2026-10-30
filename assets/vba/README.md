# Excel VBA project

`FinancialDiary.bas` is the reviewed source for the macro project embedded in
exported workbooks. `vbaProject.bin` was compiled in desktop Excel from that
source in a new, disposable blank workbook. Its SHA-256 is:

`2b888864730b6f116c1c79c1feb1068725dbc77f2030f8d5b8a022215ab29bf3`

The canonical checksum is in `lib/services/vba_integrity.dart`, and is also
recorded beside the asset in `pubspec.yaml`. The app checks the complete binary
against the pin before exporting. Never use a personal workbook or statement to
rebuild or test this project, and do not add temporary workbooks or personal
metadata to the repository.

## Release checklist

1. If the source changed, create a new blank `.xlsm` in desktop Excel. Remove
   identifying document properties, import `FinancialDiary.bas` as its only
   standard module in the Visual Basic editor, choose **Debug > Compile
   VBAProject**, and save the disposable workbook. Extract
   `xl/vbaProject.bin` from the workbook ZIP. Inspect the candidate with
   `olevba` and review the source and binary for personal metadata and
   unexpected code. Run `Get-FileHash` on the candidate and update the canonical
   pin and the checksum references here and in `pubspec.yaml` after review. Then
   replace the asset with the reviewed candidate.
2. Run `Get-FileHash assets/vba/vbaProject.bin -Algorithm SHA256` in PowerShell
   and compare it with the canonical pin and both recorded references.
3. Install `oletools==0.60.2` in a development Python environment and run
   `python tool/verify_vba_source.py`. This uses `olevba` to extract and compare
   the embedded VBA text with the reviewed source, verifies the canonical pin,
   and rejects extra code in the workbook and sheet modules. The script accepts
   one candidate path, but it must match the current reviewed pin.
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
