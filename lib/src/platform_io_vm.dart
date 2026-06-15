import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

/// Whether local filesystem and streaming ZIP operations are available.
bool get supportsFileIo => true;

/// A ZIP archive opened by the platform layer.
class OpenedArchive {
  /// Creates an opened archive wrapper.
  OpenedArchive._(this.archive, this._inputStream) : isStreaming = true;

  final InputFileStream? _inputStream;

  /// The decoded archive.
  final Archive archive;

  /// Whether the archive is backed by a streaming file input.
  final bool isStreaming;

  /// Releases platform resources associated with this archive.
  Future<void> close() async {
    if (_inputStream == null) return;
    await _inputStream.close();
  }
}

/// Returns whether [path] exists as a local file.
bool fileExistsSync(String path) => File(path).existsSync();

/// Reads a local file into memory.
Future<Uint8List> readFileBytes(String path) => File(path).readAsBytes();

/// Opens a local DOCX file as a streaming ZIP archive.
Future<OpenedArchive> openArchiveStream(String path) async {
  final input = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    return OpenedArchive._(archive, input);
  } catch (_) {
    await input.close();
    rethrow;
  }
}

/// Ensures that a local directory exists.
Future<void> ensureDirectory(String path) async {
  final dir = Directory(path);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
}

/// Returns whether [path] exists as a local output file.
bool outputFileExistsSync(String path) => File(path).existsSync();

/// Writes [file] to a local output path.
Future<void> writeArchiveFile(String outputPath, ArchiveFile file) async {
  final outputStream = OutputFileStream(outputPath);
  try {
    file.writeContent(outputStream, freeMemory: true);
  } finally {
    await outputStream.close();
  }
}
