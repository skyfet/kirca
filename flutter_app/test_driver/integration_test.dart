import 'dart:async';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot: (String screenshotName, List<int> screenshotBytes, [
      Map<String, Object?>? args,
    ]) async {
      final dir = Directory('integration_test/screenshots');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/$screenshotName.png');
      await file.writeAsBytes(screenshotBytes);
      return true;
    },
  );
}
