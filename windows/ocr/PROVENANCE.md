# Windows OCR bundle

The bundled `tesseract.exe` is built from the signed upstream Tesseract 5.5.4 tag
(`c5065e4c17df16a75960a0e0fa50e4399df1ac74`, commit
`7e548e6eff172f38f97664afe7f7ce40db36c8d6`). GitHub's tag verification returned
`verified: true`. The executable's SHA-256 is
`0b6670e056c54dc8de074d6916fbefdc59545a3537d03341e3174f2f30f7c0bd`.

Its Leptonica and image-library dependencies were built statically with vcpkg
baseline `d4c0a46cb8f63e5c9fa007d13baf1cb3e43bf7e3` and triplet
`x64-windows-static`. The build used MSVC 14.52.36314 and CMake 4.4.4, with
`BUILD_SHARED_LIBS=OFF`, `BUILD_TRAINING_TOOLS=OFF`,
`DISABLED_LEGACY_ENGINE=ON`, `DISABLE_ARCHIVE=ON`, `DISABLE_CURL=ON`,
`DISABLE_TIFF=ON`, `GRAPHICS_DISABLED=ON`, `ENABLE_NATIVE=OFF` and the static
MSVC runtime. `dumpbin /dependents` reports only the Windows `KERNEL32.dll`.
The included `licenses` directory contains notices for the engine and its
statically linked dependencies. These settings and inputs pin the build; byte
reproducibility across toolchain versions has not been established.

The `eng`, `heb`, and `rus` language models are from tessdata_fast commit
`87416418657359cb625c412a48b6e1d6d41c29bd`; their hashes are recorded in
`lib/services/ocr_integrity.dart`. The application verifies and locks the engine
and models before starting OCR, and refuses to run if their hashes differ.
