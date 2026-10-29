package io.paratoner.flutter_tesseract_ocr;

import android.os.AsyncTask;
import androidx.annotation.NonNull;
import com.googlecode.tesseract.android.TessBaseAPI;
import java.io.File;
import java.util.Map;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

public class FlutterTesseractOcrPlugin implements FlutterPlugin, MethodCallHandler {
  private MethodChannel channel;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    BinaryMessenger messenger = binding.getBinaryMessenger();
    channel = new MethodChannel(messenger, "flutter_tesseract_ocr");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (channel != null) {
      channel.setMethodCallHandler(null);
      channel = null;
    }
  }

  @Override
  public void onMethodCall(final MethodCall call, final Result result) {
    if (!call.method.equals("extractText") && !call.method.equals("extractHocr")) {
      result.notImplemented();
      return;
    }
    final String tessDataPath = call.argument("tessData");
    final String imagePath = call.argument("imagePath");
    final String language = call.argument("language") == null ? "eng" : call.argument("language");
    final Map<String, String> args = call.argument("args");
    if (tessDataPath == null || imagePath == null || language.isEmpty()) {
      result.error("OCR_INVALID_ARGUMENT", "Missing OCR input or language.", null);
      return;
    }
    // Each task owns its engine. Concurrent calls or engine detachment cannot
    // recycle an engine while another recognition task is using it.
    new OcrAsyncTask(tessDataPath, language, new File(imagePath), args, result,
        call.method.equals("extractHocr")).execute();
  }

  private static class OcrAsyncTask extends AsyncTask<Void, Void, String> {
    private final String tessDataPath;
    private final String language;
    private final File imageFile;
    private final Map<String, String> args;
    private final Result result;
    private final boolean extractHocr;
    private String errorCode;

    OcrAsyncTask(String tessDataPath, String language, File imageFile,
        Map<String, String> args, Result result, boolean extractHocr) {
      this.tessDataPath = tessDataPath;
      this.language = language;
      this.imageFile = imageFile;
      this.args = args;
      this.result = result;
      this.extractHocr = extractHocr;
    }

    @Override
    protected String doInBackground(Void... voids) {
      TessBaseAPI api = null;
      boolean initializing = true;
      try {
        api = new TessBaseAPI();
        if (!api.init(tessDataPath, language)) {
          errorCode = "OCR_INIT_FAILED";
          return null;
        }
        initializing = false;
        int psm = TessBaseAPI.PageSegMode.PSM_AUTO_OSD;
        if (args != null) {
          for (Map.Entry<String, String> entry : args.entrySet()) {
            if (entry.getKey().equals("psm")) {
              psm = Integer.parseInt(entry.getValue());
            } else {
              api.setVariable(entry.getKey(), entry.getValue());
            }
          }
        }
        api.setPageSegMode(psm);
        api.setImage(imageFile);
        return extractHocr ? api.getHOCRText(0) : api.getUTF8Text();
      } catch (Exception | LinkageError error) {
        errorCode = initializing ? "OCR_INIT_FAILED" : "OCR_FAILED";
        return null;
      } finally {
        if (api != null) {
          try {
            api.recycle();
          } catch (RuntimeException ignored) {
            // The native engine may already be unavailable after an init error.
          }
        }
      }
    }

    @Override
    protected void onPostExecute(String recognizedText) {
      if (errorCode != null || recognizedText == null) {
        result.error(errorCode == null ? "OCR_FAILED" : errorCode,
            "Could not recognize this page offline.", null);
      } else {
        result.success(recognizedText);
      }
    }
  }
}
