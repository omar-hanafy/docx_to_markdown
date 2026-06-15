import 'dart:async';
import 'dart:typed_data';

/// An embedded DOCX image exported during conversion.
///
/// Instances are delivered to [DocxImageAssetSink] when callers want to control
/// where image bytes go. This is the recommended image path for Flutter web and
/// browser apps because the package itself does not create files, object URLs,
/// or network requests.
final class DocxImageAsset {
  /// Creates an exported image asset.
  ///
  /// The input [bytes] list is defensively copied.
  DocxImageAsset({
    required this.partPath,
    required this.suggestedFilename,
    required this.contentType,
    required Uint8List bytes,
  }) : bytes = Uint8List.fromList(bytes);

  /// The canonical OPC package path, such as `word/media/image1.png`.
  final String partPath;

  /// A stable filename suitable for writing or uploading the asset.
  final String suggestedFilename;

  /// The best known MIME type for the asset.
  ///
  /// Values come from `[Content_Types].xml` when present, then from a common
  /// extension fallback, then `application/octet-stream`.
  final String contentType;

  /// The decompressed image bytes.
  final Uint8List bytes;
}

/// Receives an embedded image and returns the Markdown image source to use.
///
/// Return a non-empty string to keep the image in Markdown. Return `null` or an
/// empty string to skip that image. The callback may store bytes locally, upload
/// them, create a browser object URL, or return a data URI.
typedef DocxImageAssetSink = FutureOr<String?> Function(DocxImageAsset asset);
