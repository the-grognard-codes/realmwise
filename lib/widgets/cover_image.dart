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
      return Container(
        width: width,
        height: height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(12),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined),
            SizedBox(height: 6),
            Text('No local cover image', textAlign: TextAlign.center),
          ],
        ),
      );
    }
    return Image.file(
      file,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stack) => Container(
        width: width,
        height: height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: const Text('Image cannot be read', textAlign: TextAlign.center),
      ),
    );
  }
}
