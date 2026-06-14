// ooxml_package.dart
//
// Production-grade OOXML (DOCX) package reader for Dart.
//
// Responsibilities:
// - Open .docx (zip) from file / bytes (streaming or in-memory)
// - Normalize/lookup parts efficiently
// - Load XML parts with caching + good error messages
// - Parse OPC relationships (.rels) for any source part
// - Resolve relationship targets correctly (relative -> absolute part path)
// - Extract media (word/media/*) to a directory (optional)
//
// Notes:
// - Uses posix paths for OPC part names regardless of platform.
// - Supports both Transitional and Strict OOXML variants by matching
//   relationship type suffixes (e.g. endsWith('/relationships/styles')).
//
// Dependencies:
//   archive: ^4.x
//   xml: ^6.x
//   path: ^1.9.x
//   collection: ^1.18.x (optional but handy)

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// Thrown when the .docx package is missing critical parts or cannot be read.
class DocxPackageException implements Exception {
  /// Creates an exception with a descriptive [message] and optional [part] path.
  DocxPackageException(this.message, {this.part});

  /// Human-readable description of what went wrong.
  final String message;

  /// The OPC part path where the error occurred, if applicable.
  ///
  /// For example, `"word/document.xml"` or `"_rels/.rels"`.
  final String? part;

  @override
  String toString() => part == null
      ? 'DocxPackageException: $message'
      : 'DocxPackageException($part): $message';
}

/// Thrown when an XML part exists but cannot be parsed.
class DocxXmlParseException extends DocxPackageException {
  /// Creates an exception for XML parse failure in the given [part].
  ///
  /// The [inner] exception contains the underlying parse error details.
  DocxXmlParseException({required String part, required this.inner})
    : super('Failed to parse XML', part: part);

  /// The underlying parse exception (typically from the `xml` package).
  final Object inner;

  @override
  String toString() => 'DocxXmlParseException($part): $inner';
}

/// Relationship type suffixes for matching OOXML relationships.
///
/// OOXML relationship types are URIs that differ between Transitional and
/// Strict variants. Matching by suffix (e.g., `/relationships/styles`)
/// works for both variants without hardcoding the full URI.
class DocxRelTypeSuffix {
  /// Suffix for the main document relationship.
  static const officeDocument = '/relationships/officeDocument';

  /// Suffix for the styles.xml relationship.
  static const styles = '/relationships/styles';

  /// Suffix for the numbering.xml relationship (list definitions).
  static const numbering = '/relationships/numbering';

  /// Suffix for the comments.xml relationship.
  static const comments = '/relationships/comments';

  /// Suffix for the footnotes.xml relationship.
  static const footnotes = '/relationships/footnotes';

  /// Suffix for the endnotes.xml relationship.
  static const endnotes = '/relationships/endnotes';

  /// Suffix for header part relationships.
  static const header = '/relationships/header';

  /// Suffix for footer part relationships.
  static const footer = '/relationships/footer';

  /// Suffix for external hyperlink relationships.
  static const hyperlink = '/relationships/hyperlink';

  /// Suffix for embedded image relationships.
  static const image = '/relationships/image';
}

/// A single OPC relationship parsed from a `.rels` file.
///
/// Relationships link a source part to a target (internal part or external URL).
/// The [resolvedTarget] provides the canonical path for internal targets.
class DocxRelationship {
  /// Creates a relationship with all required fields.
  DocxRelationship({
    required this.id,
    required this.type,
    required this.target,
    required this.isExternal,
    required this.resolvedTarget,
  });

  /// e.g. "rId5"
  final String id;

  /// Full relationship type URI.
  final String type;

  /// Raw Target attribute value.
  final String target;

  /// True if TargetMode="External" OR target contains a URI scheme.
  final bool isExternal;

  /// For internal rels: normalized part path (e.g. "word/media/image1.png")
  /// For external rels: same as [target] (e.g. "https://example.com").
  final String resolvedTarget;

  @override
  String toString() =>
      'DocxRelationship(id=$id, external=$isExternal, type=$type, target=$target, resolved=$resolvedTarget)';
}

/// A collection of relationships for a single source part.
///
/// Each part in an OPC package can have associated relationships stored in
/// a corresponding `.rels` file. This class provides efficient lookup by
/// relationship ID and type suffix filtering.
class DocxRelationships {
  /// Creates a relationships collection for the given [sourcePartPath].
  DocxRelationships({
    required this.sourcePartPath,
    required Map<String, DocxRelationship> byId,
  }) : byId = Map.unmodifiable(byId);

  /// The *source part* that owns this relationship set.
  /// For package root relationships, this is '' (empty).
  final String sourcePartPath;

  /// All relationships in this collection, keyed by relationship ID.
  ///
  /// The map is unmodifiable. Use [resolveTargetById] for convenient lookup.
  final Map<String, DocxRelationship> byId;

  /// Returns all relationships whose type ends with [suffix].
  ///
  /// Use [DocxRelTypeSuffix] constants for common relationship types.
  Iterable<DocxRelationship> whereTypeSuffix(String suffix) =>
      byId.values.where((r) => r.type.endsWith(suffix));

  /// Returns the first relationship whose type ends with [suffix], or `null`.
  ///
  /// Use [DocxRelTypeSuffix] constants for common relationship types.
  DocxRelationship? firstWhereTypeSuffix(String suffix) =>
      byId.values.firstWhereOrNull((r) => r.type.endsWith(suffix));

  /// Resolves a relationship ID to its target path or URL.
  ///
  /// Returns the [DocxRelationship.resolvedTarget] for the given [rId],
  /// or `null` if no such relationship exists.
  String? resolveTargetById(String rId) => byId[rId]?.resolvedTarget;
}

/// Manages the lifecycle of a DOCX (OPC) package and its parts.
///
/// Core concept: parts are connected by relationships. Paths must be resolved
/// relative to the source part, not the package root. This class guarantees:
/// - Canonical POSIX paths for all parts.
/// - Correct relationship resolution per OPC rules.
/// - Lazy, cached XML parsing for efficiency.
class DocxPackage {
  DocxPackage._({required this._archive, this._inputStream}) {
    _indexArchiveFiles();
    _validatePackageShape();
  }

  final Archive _archive;
  final InputFileStream? _inputStream; // non-null when opened in streaming mode
  bool _closed = false;

  // Maximum number of XML documents to cache (prevents unbounded memory growth)
  static const _maxXmlCacheEntries = 50;

  // Fast part lookup
  final Map<String, ArchiveFile> _filesByCanonicalName = {};

  // XML parse cache (key: canonical part path)
  final Map<String, Object /* XmlDocument | _XmlParseFailure */> _xmlCache = {};

  // Relationships cache (key: canonical sourcePartPath)
  final Map<String, DocxRelationships> _relsCache = {};

  // Resolved main document part path cache
  String? _mainDocumentPartPath;

  // Resolved commonly-used part paths (from document relationships)
  String? _stylesPartPath;
  String? _numberingPartPath;
  String? _commentsPartPath;
  String? _footnotesPartPath;
  String? _endnotesPartPath;

  /// Open a .docx from disk.
  ///
  /// If [streaming] is true, uses archive_io InputFileStream to avoid reading
  /// the entire zip into memory. You should call [close] when done.
  static Future<DocxPackage> openFile(
    String filePath, {
    bool streaming = false,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw DocxPackageException('File not found: $filePath');
    }
    if (!filePath.toLowerCase().endsWith('.docx')) {
      throw DocxPackageException('Only .docx files are supported.');
    }

    if (!streaming) {
      final bytes = await file.readAsBytes();
      return openBytes(bytes);
    }

    // Streaming mode
    final input = InputFileStream(filePath);
    try {
      final archive = ZipDecoder().decodeStream(input);
      return DocxPackage._(archive: archive, inputStream: input);
    } on DocxPackageException {
      await input.close();
      rethrow;
    } catch (e) {
      // Ensure we don't leak file handles on failure
      await input.close();
      throw DocxPackageException(
        'Invalid DOCX/ZIP package: $e',
        part: filePath,
      );
    }
  }

  /// Open a .docx from bytes (in-memory).
  static DocxPackage openBytes(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      return DocxPackage._(archive: archive);
    } on DocxPackageException {
      rethrow;
    } catch (e) {
      throw DocxPackageException('Invalid DOCX/ZIP package: $e');
    }
  }

  /// Close any underlying file handles and free cached memory.
  ///
  /// Safe to call multiple times.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    // Close files (relevant for streaming mode).
    // Ignore close failures so close() is best-effort.
    for (final f in _archive.files) {
      try {
        await f.close();
      } catch (_) {}
    }

    // Close zip input stream if used.
    if (_inputStream != null) {
      try {
        await _inputStream.close();
      } catch (_) {}
    }

    _filesByCanonicalName.clear();
    _xmlCache.clear();
    _relsCache.clear();
  }

  /// True if this instance was opened using streaming IO.
  bool get isStreaming => _inputStream != null;

  /// List all part paths in the archive (canonical posix paths).
  Iterable<String> get partNames sync* {
    _ensureOpen();
    yield* _filesByCanonicalName.keys;
  }

  /// Returns `true` if the package contains a part at the given path.
  bool hasPart(String partPath) {
    _ensureOpen();
    return _filesByCanonicalName.containsKey(_canonicalPartPath(partPath));
  }

  /// Returns the canonical posix part path used internally by this package.
  String canonicalizePartPath(String partPath) => _canonicalPartPath(partPath);

  /// Main document part path as defined by package relationships (/_rels/.rels),
  /// falling back to word/document.xml when needed.
  String get mainDocumentPartPath {
    _ensureOpen();
    if (_mainDocumentPartPath != null) return _mainDocumentPartPath!;

    // Parse package root relationships to find officeDocument relationship.
    final rootRels = relationshipsForPackageRoot();
    final officeRel = rootRels.firstWhereTypeSuffix(
      DocxRelTypeSuffix.officeDocument,
    );

    if (officeRel != null && !officeRel.isExternal) {
      final candidate = _canonicalPartPath(officeRel.resolvedTarget);
      if (hasPart(candidate)) {
        _mainDocumentPartPath = candidate;
        return candidate;
      }
    }

    // Fallback
    const fallback = 'word/document.xml';
    if (hasPart(fallback)) {
      _mainDocumentPartPath = fallback;
      return fallback;
    }

    throw DocxPackageException(
      'Could not locate main document part. Missing officeDocument rel and no word/document.xml fallback.',
      part: '_rels/.rels',
    );
  }

  /// The canonical path to styles.xml, resolved via relationships.
  ///
  /// Returns `null` if the styles part is missing from the package.
  String? get stylesPartPath {
    _ensureOpen();
    return _stylesPartPath ??=
        _partFromDocumentRelType(DocxRelTypeSuffix.styles) ??
        _existingFallback('word/styles.xml');
  }

  /// The canonical path to numbering.xml (list definitions), resolved via relationships.
  ///
  /// Returns `null` if the numbering part is missing from the package.
  String? get numberingPartPath {
    _ensureOpen();
    return _numberingPartPath ??=
        _partFromDocumentRelType(DocxRelTypeSuffix.numbering) ??
        _existingFallback('word/numbering.xml');
  }

  /// The canonical path to comments.xml, resolved via relationships.
  ///
  /// Returns `null` if the comments part is missing from the package.
  String? get commentsPartPath {
    _ensureOpen();
    return _commentsPartPath ??=
        _partFromDocumentRelType(DocxRelTypeSuffix.comments) ??
        _existingFallback('word/comments.xml');
  }

  /// The canonical path to footnotes.xml, resolved via relationships.
  ///
  /// Returns `null` if the footnotes part is missing from the package.
  String? get footnotesPartPath {
    _ensureOpen();
    return _footnotesPartPath ??=
        _partFromDocumentRelType(DocxRelTypeSuffix.footnotes) ??
        _existingFallback('word/footnotes.xml');
  }

  /// The canonical path to endnotes.xml, resolved via relationships.
  ///
  /// Returns `null` if the endnotes part is missing from the package.
  String? get endnotesPartPath {
    _ensureOpen();
    return _endnotesPartPath ??=
        _partFromDocumentRelType(DocxRelTypeSuffix.endnotes) ??
        _existingFallback('word/endnotes.xml');
  }

  /// Loads and returns the parsed main document XML.
  ///
  /// Throws [DocxXmlParseException] if the XML is malformed.
  XmlDocument? get documentXml => loadXml(mainDocumentPartPath);

  /// Loads and returns the parsed styles.xml, or `null` if missing.
  XmlDocument? get stylesXml =>
      stylesPartPath == null ? null : loadXml(stylesPartPath!);

  /// Loads and returns the parsed numbering.xml, or `null` if missing.
  XmlDocument? get numberingXml =>
      numberingPartPath == null ? null : loadXml(numberingPartPath!);

  /// Loads and returns the parsed comments.xml, or `null` if missing.
  XmlDocument? get commentsXml =>
      commentsPartPath == null ? null : loadXml(commentsPartPath!);

  /// Loads and returns the parsed footnotes.xml, or `null` if missing.
  XmlDocument? get footnotesXml =>
      footnotesPartPath == null ? null : loadXml(footnotesPartPath!);

  /// Loads and returns the parsed endnotes.xml, or `null` if missing.
  XmlDocument? get endnotesXml =>
      endnotesPartPath == null ? null : loadXml(endnotesPartPath!);

  /// Loads and parses an XML part by its path.
  ///
  /// Behavior:
  /// - Returns `null` if the part does not exist.
  /// - Caches parsed [XmlDocument] on success.
  /// - Throws [DocxXmlParseException] if bytes exist but XML is invalid.
  ///
  /// Failures are cached to avoid repeated parse attempts on broken files.
  XmlDocument? loadXml(String partPath) {
    _ensureOpen();
    final key = _canonicalPartPath(partPath);

    final cached = _xmlCache[key];
    if (cached is XmlDocument) return cached;
    if (cached is _XmlParseFailure) {
      throw DocxXmlParseException(part: key, inner: cached.error);
    }

    final bytes = readPartBytes(key);
    if (bytes == null) return null;

    try {
      // Allow malformed UTF-8 so we can still parse most documents and fail only on XML issues.
      final xmlText = utf8.decode(bytes, allowMalformed: true);
      final doc = XmlDocument.parse(xmlText);
      // Evict oldest entry if cache is full (simple FIFO eviction)
      if (_xmlCache.length >= _maxXmlCacheEntries) {
        _xmlCache.remove(_xmlCache.keys.first);
      }
      _xmlCache[key] = doc;
      return doc;
    } catch (e) {
      // Evict oldest entry if cache is full
      if (_xmlCache.length >= _maxXmlCacheEntries) {
        _xmlCache.remove(_xmlCache.keys.first);
      }
      _xmlCache[key] = _XmlParseFailure(e);
      throw DocxXmlParseException(part: key, inner: e);
    }
  }

  /// Try-load XML part:
  /// - null if missing or parse error.
  /// - No exceptions.
  XmlDocument? tryLoadXml(String partPath) {
    try {
      return loadXml(partPath);
    } catch (_) {
      return null;
    }
  }

  /// Read a part as decompressed bytes.
  ///
  /// Returns null if the part doesn't exist.
  Uint8List? readPartBytes(String partPath) {
    _ensureOpen();
    final key = _canonicalPartPath(partPath);
    final file = _filesByCanonicalName[key];
    if (file == null) return null;
    // ArchiveFile.readBytes() returns decompressed bytes (and may cache internally).
    return file.readBytes();
  }

  /// Read a part as text (defaults to UTF-8 with allowMalformed).
  ///
  /// Returns null if missing.
  String? readPartText(String partPath, {Encoding encoding = utf8}) {
    final bytes = readPartBytes(partPath);
    if (bytes == null) return null;

    if (encoding == utf8) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    return encoding.decode(bytes);
  }

  /// Get relationships for the package root.
  ///
  /// Source part path is '' (empty) which represents the package root.
  DocxRelationships relationshipsForPackageRoot() => relationshipsForPart('');

  /// Gets relationships for a given *source part* (not the `.rels` path).
  ///
  /// Example:
  /// - sourcePartPath: "word/document.xml"
  /// - rels part:       "word/_rels/document.xml.rels"
  ///
  /// How it works:
  /// 1. Computes the `.rels` path for the source part.
  /// 2. Parses the relationships file if present.
  /// 3. Resolves internal targets to canonical package paths.
  DocxRelationships relationshipsForPart(String sourcePartPath) {
    _ensureOpen();
    final source = _canonicalSourcePartPath(sourcePartPath);

    final cached = _relsCache[source];
    if (cached != null) return cached;

    final relsPart = _relsPartPathForSource(source);
    final xml = tryLoadXml(relsPart);

    final map = <String, DocxRelationship>{};

    if (xml != null) {
      for (final el in xml.findAllElements('Relationship')) {
        final id = el.getAttribute('Id');
        final type = el.getAttribute('Type');
        final target = el.getAttribute('Target');

        if (id == null || type == null || target == null) continue;

        final targetMode = el.getAttribute('TargetMode');
        final isExternal = _isExternalTarget(target, targetMode);

        final resolved = isExternal
            ? target
            : _resolveTargetPath(source, target);

        map[id] = DocxRelationship(
          id: id,
          type: type,
          target: target,
          isExternal: isExternal,
          resolvedTarget: resolved,
        );
      }
    }

    final rels = DocxRelationships(sourcePartPath: source, byId: map);
    _relsCache[source] = rels;
    return rels;
  }

  /// Resolve a relationship target by rId for a given *source part*.
  ///
  /// Returns:
  /// - external URL (unchanged) for external targets
  /// - canonical internal part path for internal targets
  /// - null if missing
  String? resolveRelTarget(String sourcePartPath, String rId) {
    final rels = relationshipsForPart(sourcePartPath);
    return rels.resolveTargetById(rId);
  }

  /// Convenience wrapper for [resolveRelTarget] using the main document part.
  String? resolveDocumentRelTarget(String rId) {
    return resolveRelTarget(mainDocumentPartPath, rId);
  }

  /// Extract all files under word/media/ to [outputDir].
  ///
  /// Returns a mapping:
  ///   internalPartPath -> returnedPath
  ///
  /// - If [returnFullPath] is false, returnedPath is a relative filename.
  /// - If [returnFullPath] is true, returnedPath is the full output path.
  ///
  /// If [overwrite] is false, collisions are resolved by appending _{n}.
  Future<Map<String, String>> extractMediaToDirectory(
    String outputDir, {
    bool overwrite = false,
    bool returnFullPath = false,
    String? filenamePrefix,
  }) async {
    _ensureOpen();

    final dir = Directory(outputDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final out = <String, String>{};

    final mediaEntries = _filesByCanonicalName.entries.where((e) {
      final name = e.key;
      return name.startsWith('word/media/') && !e.value.isDirectory;
    });

    int globalCounter = 0;

    for (final entry in mediaEntries) {
      final partPath = entry.key;
      final file = entry.value;

      // Flatten hierarchy: preserve extension, but ensure uniqueness.
      globalCounter++;
      final ext = p.posix.extension(partPath);
      final originalNameNoExt = p.posix.basenameWithoutExtension(partPath);

      // Construct a name that is likely stable but unique.
      // We append a counter to handle duplicates from different folders if any,
      // or if overwrite=false and file exists (handled below).
      // However, to strictly follow the instruction "Ensure unique image filenames across subfolders":
      // We can just use the counter if we don't care about the original name,
      // or append the counter.

      final prefix = (filenamePrefix == null || filenamePrefix.isEmpty)
          ? ''
          : filenamePrefix;
      final baseName = '$prefix${originalNameNoExt}_$globalCounter$ext';

      var outName = baseName;
      var outPath = p.join(outputDir, outName);

      // Handle local filesystem collisions (if overwrite is false)
      if (!overwrite) {
        int localCounter = 0;
        while (File(outPath).existsSync()) {
          localCounter++;
          outName = _appendSuffixBeforeExtension(baseName, '_$localCounter');
          outPath = p.join(outputDir, outName);
        }
      }

      final outputStream = OutputFileStream(outPath);
      try {
        // Stream out decompressed file content. freeMemory helps keep RAM stable.
        file.writeContent(outputStream, freeMemory: true);
      } finally {
        await outputStream.close();
      }

      out[partPath] = returnFullPath ? outPath : outName;
    }

    return out;
  }

  // -------------------------
  // Internals
  // -------------------------

  void _ensureOpen() {
    if (_closed) {
      throw DocxPackageException('DocxPackage is closed.');
    }
  }

  void _indexArchiveFiles() {
    _filesByCanonicalName.clear();
    for (final f in _archive.files) {
      // Canonicalize path to avoid lookup bugs on Windows or odd zip writers.
      final key = _canonicalPartPath(f.name);
      _filesByCanonicalName[key] = f;
    }
  }

  void _validatePackageShape() {
    if (!_filesByCanonicalName.containsKey('[Content_Types].xml')) {
      throw DocxPackageException(
        'Invalid DOCX package: missing [Content_Types].xml',
        part: '[Content_Types].xml',
      );
    }
  }

  String? _existingFallback(String partPath) {
    final canonical = _canonicalPartPath(partPath);
    return hasPart(canonical) ? canonical : null;
  }

  /// Resolve a common part path (styles/numbering/etc) by looking up a relationship
  /// from the main document part.
  String? _partFromDocumentRelType(String typeSuffix) {
    final docPart = mainDocumentPartPath;
    final rels = relationshipsForPart(docPart);
    final rel = rels.firstWhereTypeSuffix(typeSuffix);
    if (rel == null || rel.isExternal) return null;

    final candidate = _canonicalPartPath(rel.resolvedTarget);
    return hasPart(candidate) ? candidate : null;
  }

  static String _appendSuffixBeforeExtension(String name, String suffix) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '$name$suffix';
    return '${name.substring(0, dot)}$suffix${name.substring(dot)}';
  }

  /// Canonicalize OPC part paths:
  /// - uses forward slashes
  /// - removes leading '/'
  /// - normalizes '..' and '.'
  String _canonicalPartPath(String partPath) {
    var s = partPath.replaceAll('\\', '/').trim();
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    // Prevent empty => treat as root (only used for source part paths)
    if (s.isEmpty) return '';
    return p.posix.normalize(s);
  }

  /// Canonicalize source part path:
  /// - '' represents package root
  /// - otherwise canonical part path
  String _canonicalSourcePartPath(String sourcePartPath) {
    final s = _canonicalPartPath(sourcePartPath);
    return s; // '' allowed
  }

  /// Compute the .rels part path for a given *source part*.
  String _relsPartPathForSource(String sourcePartPath) {
    if (sourcePartPath.isEmpty) {
      return '_rels/.rels';
    }
    final dir = p.posix.dirname(sourcePartPath);
    final base = p.posix.basename(sourcePartPath);
    return p.posix.join(dir, '_rels', '$base.rels');
  }

  bool _isExternalTarget(String target, String? targetMode) {
    if (targetMode != null && targetMode.toLowerCase() == 'external') {
      return true;
    }
    final uri = Uri.tryParse(target);
    return uri != null && uri.hasScheme;
  }

  /// Resolves internal relationship targets to canonical part paths.
  ///
  /// OPC rule: targets are resolved relative to the *source part's* directory,
  /// except for package root relationships where [sourcePartPath] is ''.
  ///
  /// Example:
  /// - source: `word/document.xml` (dir: `word/`)
  /// - target: `media/image1.png`
  /// - result: `word/media/image1.png`
  String _resolveTargetPath(String sourcePartPath, String target) {
    var t = target.replaceAll('\\', '/').trim();

    // If the relationship target is absolute within the package, it may start with '/'
    if (t.startsWith('/')) {
      t = t.substring(1);
      return _canonicalPartPath(t);
    }

    // For package root (sourcePartPath == ''), resolve relative to root.
    final baseDir = sourcePartPath.isEmpty
        ? ''
        : p.posix.dirname(sourcePartPath);
    final resolved = p.posix.normalize(p.posix.join(baseDir, t));
    return _canonicalPartPath(resolved);
  }
}

class _XmlParseFailure {
  _XmlParseFailure(this.error);
  final Object error;
}
