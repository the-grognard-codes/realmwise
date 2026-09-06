import 'dart:io';

import 'package:flutter/material.dart';

import '../models/catalog_models.dart';
import '../theme/app_theme.dart';

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
    if (file == null || !_canRead(file)) {
      return _placeholder(context);
    }
    return Image.file(
      file,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stack) => _placeholder(context),
    );
  }

  bool _canRead(File file) {
    try {
      return file.existsSync();
    } on FileSystemException {
      return false;
    }
  }

  Widget _placeholder(BuildContext context) {
    final assetPath =
        Theme.of(context).extension<CoverPlaceholderTheme>()?.assetPath ??
        workCoverPlaceholderAssetPath(defaultThemeName);
    return Image.asset(assetPath, width: width, height: height, fit: fit);
  }
}
