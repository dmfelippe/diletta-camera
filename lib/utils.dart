part of 'diletta_camera.dart';

Future<CameraDescription?> _getCamera(CameraLensDirection dir) async {
  final cameras = await availableCameras();
  final camera = cameras.firstWhereOrNull((camera) => camera.lensDirection == dir);
  return camera ?? (cameras.isEmpty ? null : cameras.first);
}

Uint8List _concatenatePlanes(List<Plane> planes) {
  final allBytes = WriteBuffer();
  planes.forEach((plane) => allBytes.putUint8List(plane.bytes));
  return allBytes.done().buffer.asUint8List();
}

InputImageMetadata buildMetaData(
  CameraImage image,
  InputImageRotation rotation,
) {
  return InputImageMetadata(
      format: InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.yuv_420_888,
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      bytesPerRow: image.planes.first.bytesPerRow);
}

Future<T> _detect<T>(
  CameraImage image,
  HandleDetection<T> handleDetection,
  InputImageRotation rotation,
) async {
  return handleDetection(
    InputImage.fromBytes(
      bytes: _concatenatePlanes(image.planes),
      metadata: buildMetaData(image, rotation),
    ),
  );
}

InputImageRotation _rotationIntToImageRotation(int rotation) {
  return InputImageRotationValue.fromRawValue(rotation) ?? InputImageRotation.rotation0deg;
}
