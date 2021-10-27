library diletta_camera;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:collection/collection.dart';
import 'package:device_info/device_info.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:visibility_detector/visibility_detector.dart';

export 'package:camera/camera.dart';

part 'utils.dart';

typedef HandleDetection<T> = Future<T> Function(InputImage image);
typedef ErrorWidgetBuilder = Widget Function(
    BuildContext context, CameraError error);

enum CameraError {
  unknown,
  cantInitializeCamera,
  androidVersionNotSupported,
  noCameraAvailable,
}

enum CameraState {
  loading,
  error,
  ready,
}

class DilettaCamera<T> extends StatefulWidget {
  final double zoomLevel;
  final FlashMode flashMode;
  final HandleDetection<T> detector;
  final Function(T) onResult;
  final WidgetBuilder? loadingBuilder;
  final ErrorWidgetBuilder? errorBuilder;
  final WidgetBuilder? overlayBuilder;
  final CameraLensDirection cameraLensDirection;
  final ResolutionPreset? resolution;
  final Function? onDispose;

  const DilettaCamera(
      {Key? key,
      required this.onResult,
      required this.detector,
      this.loadingBuilder,
      this.errorBuilder,
      this.overlayBuilder,
      this.cameraLensDirection = CameraLensDirection.back,
      this.resolution,
      this.onDispose,
      this.zoomLevel = -1,
      this.flashMode = FlashMode.off})
      : super(key: key);

  @override
  DilettaCameraState createState() => DilettaCameraState<T>();
}

class DilettaCameraState<T> extends State<DilettaCamera<T>>
    with WidgetsBindingObserver {
  XFile? _lastImage;
  final _visibilityKey = UniqueKey();
  CameraController? _cameraController;
  InputImageRotation? _rotation;
  CameraState cameraState = CameraState.loading;
  CameraError _cameraError = CameraError.unknown;
  bool _alreadyCheckingImage = false;
  bool _isStreaming = false;
  bool _isDeactivate = false;
  bool _initializing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance!.addObserver(this);
    _initialize();
  }

  @override
  void didUpdateWidget(DilettaCamera<T> oldWidget) {
    if (oldWidget.resolution != widget.resolution) {
      _initialize();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App state changed before we got the chance to initialize.
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive && !_initializing) {
      _stop(true);
    } else if (state == AppLifecycleState.resumed && _isStreaming) {
      _initialize();
    }
  }

  Future<void> stop() async {
    if (_cameraController != null) {
      _stop(true);
    }
  }

  void _stop(bool silently) {
    try {
      _cameraController?.dispose();
    } catch (error) {
      print(error);
    }
    if (silently) {
      _isStreaming = false;
    } else {
      setState(() {
        _isStreaming = false;
      });
    }
  }

  void start() {
    if (_cameraController != null) {
      _start();
    }
  }

  void _start() {
    _cameraController!.startImageStream(_processImage);
    setState(() {
      _isStreaming = true;
    });
  }

  void stopStream() {
    if (_cameraController != null) {
      _stopStream();
    }
  }

  void _stopStream() {
    _isStreaming = false;
    _cameraController!.stopImageStream();
  }

  CameraValue? get cameraValue => _cameraController?.value;

  InputImageRotation? get imageRotation => _rotation;

  Future<void> Function() get prepareForVideoRecording =>
      _cameraController!.prepareForVideoRecording;

  Future<void> startVideoRecording() async {
    await _cameraController!.stopImageStream();
    return _cameraController!.startVideoRecording();
  }

  Future<XFile> stopVideoRecording(String path) async {
    final file = await _cameraController!.stopVideoRecording();
    await _cameraController!.startImageStream(_processImage);
    return file;
  }

  CameraController? get cameraController => _cameraController;

  Future<XFile> takePicture(String path) async {
    _stop(true);
    final image = await _cameraController!.takePicture();
    _start();
    return image;
  }

  Future<void> flash(FlashMode mode) async {
    await _cameraController!.setFlashMode(mode);
  }

  Future<void> focus(FocusMode mode) async {
    await _cameraController!.setFocusMode(mode);
  }

  Future<void> focusPoint(Offset point) async {
    await _cameraController!.setFocusPoint(point);
  }

  Future<void> zoom(double zoom) async {
    await _cameraController!.setZoomLevel(zoom);
  }

  Future<void> exposure(ExposureMode mode) async {
    await _cameraController!.setExposureMode(mode);
  }

  Future<void> exposureOffset(double offset) async {
    await _cameraController!.setExposureOffset(offset);
  }

  Future<void> exposurePoint(Offset offset) async {
    await _cameraController!.setExposurePoint(offset);
  }

  Future<void> _initialize() async {
    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      if (androidInfo.version.sdkInt < 21) {
        debugPrint('Camera plugin doesn\'t support android under version 21');
        if (mounted) {
          setState(() {
            cameraState = CameraState.error;
            _cameraError = CameraError.androidVersionNotSupported;
          });
        }
        return;
      }
    }

    final description = await _getCamera(widget.cameraLensDirection);
    if (description == null) {
      cameraState = CameraState.error;
      _cameraError = CameraError.noCameraAvailable;

      return;
    }
    if (_cameraController != null) {
      _stop(true);
    }
    _cameraController = CameraController(
      description,
      widget.resolution ?? ResolutionPreset.high,
      enableAudio: false,
    );
    if (!mounted) {
      return;
    }

    try {
      _initializing = true;
      await _cameraController!.initialize();
      _initializing = false;
      await _cameraController!
          .lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (widget.zoomLevel > -1) {
        final maxZoom = (await _cameraController?.getMaxZoomLevel()) ?? 1.0;
        await _cameraController?.setZoomLevel(
            maxZoom > widget.zoomLevel ? widget.zoomLevel : maxZoom);
        await _cameraController?.setFlashMode(widget.flashMode);
      }
    } catch (ex, stack) {
      debugPrint('Can\'t initialize camera');
      debugPrint('$ex, $stack');
      if (mounted) {
        setState(() {
          cameraState = CameraState.error;
          _cameraError = CameraError.cantInitializeCamera;
        });
      }
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      cameraState = CameraState.ready;
    });
    _rotation = _rotationIntToImageRotation(
      description.sensorOrientation,
    );

    //FIXME hacky technique to avoid having black screen on some android devices
    await Future.delayed(Duration(milliseconds: 200));
    start();
  }

  @override
  void dispose() {
    if (widget.onDispose != null) {
      widget.onDispose!();
    }
    if (_cameraController != null) {
      _stop(true);
    }
    WidgetsBinding.instance?.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (cameraState == CameraState.loading) {
      return widget.loadingBuilder == null
          ? Center(child: CircularProgressIndicator())
          : widget.loadingBuilder!(context);
    }
    if (cameraState == CameraState.error) {
      return widget.errorBuilder == null
          ? Center(child: Text('$cameraState $_cameraError'))
          : widget.errorBuilder!(context, _cameraError);
    }

    var cameraPreview = _isStreaming
        ? CameraPreview(
            _cameraController!,
          )
        : _getPicture();

    if (widget.overlayBuilder != null) {
      cameraPreview = Stack(
        fit: StackFit.passthrough,
        children: [
          cameraPreview,
          (cameraController?.value.isInitialized ?? false)
              ? AspectRatio(
                  aspectRatio: _isLandscape()
                      ? cameraController!.value.aspectRatio
                      : (1 / cameraController!.value.aspectRatio),
                  child: widget.overlayBuilder!(context),
                )
              : Container(),
        ],
      );
    }
    return VisibilityDetector(
      onVisibilityChanged: (VisibilityInfo info) {
        if (info.visibleFraction == 0) {
          //invisible stop the streaming
          _isDeactivate = true;
          _stop(true);
        } else if (_isDeactivate) {
          //visible restart streaming if needed
          _isDeactivate = false;
          _start();
        }
      },
      key: _visibilityKey,
      child: cameraPreview,
    );
  }

  DeviceOrientation? _getApplicableOrientation() {
    return (cameraController?.value.isRecordingVideo ?? false)
        ? cameraController?.value.recordingOrientation
        : (cameraController?.value.lockedCaptureOrientation ??
            cameraController?.value.deviceOrientation);
  }

  bool _isLandscape() {
    return [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        .contains(_getApplicableOrientation());
  }

  void _processImage(CameraImage cameraImage) async {
    if (!_alreadyCheckingImage && mounted) {
      _alreadyCheckingImage = true;
      try {
        final results =
            await _detect<T>(cameraImage, widget.detector, _rotation!);
        widget.onResult(results);
      } catch (ex, stack) {
        debugPrint('$ex, $stack');
      }
      _alreadyCheckingImage = false;
    }
  }

  void toggle() {
    if (_isStreaming && _cameraController!.value.isStreamingImages) {
      stop();
    } else {
      start();
    }
  }

  Widget _getPicture() {
    if (_lastImage != null) {
      return Image.file(File(_lastImage!.path));
    }
    return Container();
  }
}
