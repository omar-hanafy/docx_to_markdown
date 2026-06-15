import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Whether local filesystem and streaming ZIP operations are available.
bool get supportsFileIo => false;

/// A ZIP archive opened by the platform layer.
class OpenedArchive {
  /// Creates an opened archive wrapper.
  OpenedArchive({required this.archive, required this.isStreaming});

  /// The decoded archive.
  final Archive archive;

  /// Whether the archive is backed by a streaming file input.
  final bool isStreaming;

  /// Releases platform resources associated with this archive.
  Future<void> close() async {}
}

/// Returns whether [path] exists as a local file.
bool fileExistsSync(String path) => throw UnsupportedError(
  'Local file access is not supported on this platform.',
);

/// Reads a local file into memory.
Future<Uint8List> readFileBytes(String path) => throw UnsupportedError(
  'Local file access is not supported on this platform.',
);

/// Opens a local DOCX file as a streaming ZIP archive.
Future<OpenedArchive> openArchiveStream(String path) => throw UnsupportedError(
  'Streaming local files is not supported on this platform.',
);

/// Ensures that a local directory exists.
Future<void> ensureDirectory(String path) => throw UnsupportedError(
  'Local directory access is not supported on this platform.',
);

/// Returns whether [path] exists as a local output file.
bool outputFileExistsSync(String path) => throw UnsupportedError(
  'Local file access is not supported on this platform.',
);

/// Writes [file] to a local output path.
Future<void> writeArchiveFile(String outputPath, ArchiveFile file) =>
    throw UnsupportedError(
      'Local file writing is not supported on this platform.',
    );
