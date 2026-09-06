import 'dart:io';

import 'package:flutter/material.dart';

import '../models/catalog_models.dart';

class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.image,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });
  final BookImage? image;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final file = image == null ? null : File(image!.localPath);
    if (file == null || !file.existsSync()) {
      return _placeholder();
    }
    return Image.file(
      file,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stack) => _placeholder(),
    );
  }

  Widget _placeholder() {
    return Image.asset(
      'assets/placeholders/work-cover-placeholder-unavailable.png',
      width: width,
      height: height,
      fit: fit,
    );
  }
}
