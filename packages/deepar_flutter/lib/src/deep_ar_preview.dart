import 'dart:io';
import 'package:flutter/material.dart';
import 'deep_ar_controller.dart';

/// Displays live preview with desired effects.
class DeepArPreview extends StatefulWidget {
  const DeepArPreview(this.deepArController, {Key? key, this.onViewCreated, this.alignment = Alignment.center})
      : super(key: key);
  final DeepArController deepArController;
  final Function? onViewCreated;
  final Alignment alignment;

  @override
  State<DeepArPreview> createState() => _DeepArPreviewState();
}

class _DeepArPreviewState extends State<DeepArPreview> {
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: widget.alignment,
      child: AspectRatio(
          aspectRatio: (1 / widget.deepArController.aspectRatio),
          child: Platform.isAndroid ? _androidView() : _iOSView()),
    );
  }

  Widget _iOSView() {
    return widget.deepArController.buildPreview(oniOSViewCreated: () {
      widget.onViewCreated?.call();
      setState(() {});
    });
  }

  Widget _androidView() {
    WidgetsBinding.instance
        .addPostFrameCallback((timeStamp) => widget.onViewCreated?.call());
    return widget.deepArController.isInitialized
        ? widget.deepArController.buildPreview()
        : const SizedBox.shrink();
  }
}
