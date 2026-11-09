// StorageBackend do Hive sobre package:web, para WebAssembly. Mesma lógica e
// mesmo formato de `backend/js/native/storage_backend_js.dart` (que usa
// dart:html): valores simples vão direto para o IndexedDB, o resto vai
// serializado num ArrayBuffer com o prefixo 0x90 0xA9.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:hive/src/backend/js_web/backend_manager.dart';
import 'package:hive/src/backend/storage_backend.dart';
import 'package:hive/src/binary/binary_reader_impl.dart';
import 'package:hive/src/binary/binary_writer_impl.dart';
import 'package:hive/src/binary/frame.dart';
import 'package:hive/src/box/keystore.dart';
import 'package:hive/src/registry/type_registry_impl.dart';
import 'package:meta/meta.dart';
import 'package:web/web.dart' as web;

/// Cuida de tudo que é IndexedDB.
class StorageBackendWeb extends StorageBackend {
  static const _bytePrefix = [0x90, 0xA9];
  final web.IDBDatabase _db;
  final HiveCipher? _cipher;

  /// Nome do object store desta box.
  final String objectStoreName;

  TypeRegistry _registry;

  /// Não faz parte da API pública.
  StorageBackendWeb(this._db, this._cipher, this.objectStoreName,
      [this._registry = TypeRegistryImpl.nullImpl]);

  @override
  String? get path => null;

  @override
  bool supportsCompaction = false;

  bool _isEncoded(Uint8List bytes) {
    return bytes.length >= _bytePrefix.length &&
        bytes[0] == _bytePrefix[0] &&
        bytes[1] == _bytePrefix[1];
  }

  /// Igual ao `encodeValue` do backend original (devolve valor Dart).
  @visibleForTesting
  dynamic encodeValue(Frame frame) {
    var value = frame.value;
    if (_cipher == null) {
      if (value == null) {
        return value;
      } else if (value is Uint8List) {
        if (!_isEncoded(value)) {
          return value.buffer;
        }
      } else if (value is num ||
          value is bool ||
          value is String ||
          value is List<num> ||
          value is List<bool> ||
          value is List<String>) {
        return value;
      }
    }

    var frameWriter = BinaryWriterImpl(_registry);
    frameWriter.writeByteList(_bytePrefix, writeLength: false);

    if (_cipher == null) {
      frameWriter.write(value);
    } else {
      frameWriter.writeEncrypted(value, _cipher);
    }

    var bytes = frameWriter.toBytes();
    var sublist = bytes.sublist(0, bytes.length);
    return sublist.buffer;
  }

  /// Igual ao `decodeValue` do backend original (recebe valor Dart).
  @visibleForTesting
  dynamic decodeValue(dynamic value) {
    if (value is ByteBuffer) {
      var bytes = Uint8List.view(value);
      if (_isEncoded(bytes)) {
        var reader = BinaryReaderImpl(bytes, _registry);
        reader.skip(2);
        if (_cipher == null) {
          return reader.read();
        } else {
          return reader.readEncrypted(_cipher);
        }
      } else {
        return bytes;
      }
    } else {
      return value;
    }
  }

  web.IDBObjectStore _store(bool escrita) => _db
      .transaction(objectStoreName.toJS, escrita ? 'readwrite' : 'readonly')
      .objectStore(objectStoreName);

  /// Chaves da box.
  @visibleForTesting
  Future<List<dynamic>> getKeys() async {
    final r = await aguardarIdb(_store(false).getAllKeys());
    return deJs(r) as List<dynamic>? ?? const [];
  }

  /// Valores da box, já decodificados.
  @visibleForTesting
  Future<Iterable<dynamic>> getValues() async {
    final r = await aguardarIdb(_store(false).getAll());
    if (r == null) return const [];
    return (r as JSArray<JSAny?>).toDart.map((v) => decodeValue(deJs(v)));
  }

  @override
  Future<int> initialize(
      TypeRegistry registry, Keystore keystore, bool lazy) async {
    _registry = registry;
    var keys = await getKeys();
    if (!lazy) {
      var i = 0;
      var values = await getValues();
      for (var value in values) {
        var key = keys[i++];
        keystore.insert(Frame(key, value), notify: false);
      }
    } else {
      for (var key in keys) {
        keystore.insert(Frame.lazy(key), notify: false);
      }
    }

    return 0;
  }

  @override
  Future<dynamic> readValue(Frame frame) async {
    final r = await aguardarIdb(_store(false).get(paraJs(frame.key)));
    return decodeValue(deJs(r));
  }

  @override
  Future<void> writeFrames(List<Frame> frames) {
    final tx = _db.transaction(objectStoreName.toJS, 'readwrite');
    final store = tx.objectStore(objectStoreName);
    final pronto = _concluir(tx);
    for (var frame in frames) {
      if (frame.deleted) {
        store.delete(paraJs(frame.key)!);
      } else {
        store.put(paraJs(encodeValue(frame)), paraJs(frame.key));
      }
    }
    return pronto;
  }

  @override
  Future<List<Frame>> compact(Iterable<Frame> frames) {
    throw UnsupportedError('Not supported');
  }

  @override
  Future<void> clear() {
    final tx = _db.transaction(objectStoreName.toJS, 'readwrite');
    final pronto = _concluir(tx);
    tx.objectStore(objectStoreName).clear();
    return pronto;
  }

  @override
  Future<void> close() {
    _db.close();
    return Future.value();
  }

  @override
  Future<void> deleteFromDisk() async {
    final idb = web.window.indexedDB;
    final nome = _db.name;

    print('Delete $nome // $objectStoreName from disk');

    if (_db.objectStoreNames.length == 1) {
      _db.close();
      await aguardarIdb(idb.deleteDatabase(nome));
    } else {
      _db.close();
      final db = await abrirIndexedDb(idb, nome, _db.version + 1, (db) {
        if (db.objectStoreNames.contains(objectStoreName)) {
          db.deleteObjectStore(objectStoreName);
        }
      });
      final vazio = db.objectStoreNames.length == 0;
      db.close();
      if (vazio) {
        await aguardarIdb(idb.deleteDatabase(nome));
      }
    }
  }

  @override
  Future<void> flush() => Future.value();
}

/// Termina quando a transação conclui; falha se ela der erro ou abortar.
Future<void> _concluir(web.IDBTransaction tx) {
  final pronto = Completer<void>();
  tx.oncomplete = ((web.Event _) {
    if (!pronto.isCompleted) pronto.complete();
  }).toJS;
  tx.onerror = ((web.Event _) {
    if (!pronto.isCompleted) pronto.completeError(erroIdb(tx.error));
  }).toJS;
  tx.onabort = ((web.Event _) {
    if (!pronto.isCompleted) pronto.completeError(erroIdb(tx.error));
  }).toJS;
  return pronto.future;
}

/// Valor Dart -> JS para o IndexedDB. ByteBuffer vira ArrayBuffer (como o
/// dart:html fazia); o resto passa por `jsify` (número, texto, bool, listas).
JSAny? paraJs(dynamic valor) {
  if (valor == null) return null;
  if (valor is ByteBuffer) return valor.toJS;
  return (valor as Object).jsify();
}

/// Valor JS do IndexedDB -> Dart, com a mesma semântica de número do dart2js:
/// no wasm todo número JS chega como `double`, então inteiros voltam a ser
/// `int` (inclusive dentro de listas e mapas). ArrayBuffer vira ByteBuffer.
dynamic deJs(JSAny? valor) {
  if (valor == null) return null;
  if (valor.isA<JSArrayBuffer>()) return (valor as JSArrayBuffer).toDart;
  return normalizarNumeros(valor.dartify());
}

/// Converte `double` inteiros e finitos em `int`, recursivamente.
@visibleForTesting
dynamic normalizarNumeros(dynamic v) {
  if (v is double) {
    if (v.isFinite && v == v.truncateToDouble()) return v.toInt();
    return v;
  }
  if (v is List) return v.map(normalizarNumeros).toList();
  if (v is Map) {
    return v.map((k, val) => MapEntry(normalizarNumeros(k), normalizarNumeros(val)));
  }
  return v;
}
