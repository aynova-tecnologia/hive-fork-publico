// Backend IndexedDB do Hive para WebAssembly (dart2wasm), sobre package:web.
//
// O backend original (`backend/js/native`) usa dart:html/dart:indexed_db, que
// não existem no dart2wasm. Em `storage_backend.dart` este arquivo vem DEPOIS
// do `dart.library.html` na cadeia de imports condicionais: o dart2js continua
// usando o backend original, sem mudança; só o wasm (que não tem dart:html)
// chega aqui. Mesmo formato no IndexedDB (banco por box, store 'box'), então
// os dados gravados por um build abrem no outro.
import 'dart:async';
import 'dart:js_interop';

import 'package:hive/hive.dart';
import 'package:hive/src/backend/js_web/storage_backend_web.dart';
import 'package:hive/src/backend/storage_backend.dart';
import 'package:web/web.dart' as web;

/// Abre bancos IndexedDB (mesmo contrato do backend original).
class BackendManager implements BackendManagerInterface {
  /// Mesmo ponto de entrada do `js/backend_manager.dart`.
  static BackendManagerInterface select(
          [HiveStorageBackendPreference? backendPreference]) =>
      BackendManager();

  web.IDBFactory get _idb => web.window.indexedDB;

  @override
  Future<StorageBackend> open(String name, String? path, bool crashRecovery,
      HiveCipher? cipher, String? collection) async {
    // compatibilidade com o formato antigo
    final databaseName = collection ?? name;
    final objectStoreName = collection == null ? 'box' : name;

    var db = await abrirIndexedDb(_idb, databaseName, 1, (db) {
      if (!db.objectStoreNames.contains(objectStoreName)) {
        db.createObjectStore(objectStoreName);
      }
    });

    // se o store não existe, reabre o banco com versão nova para criá-lo
    if (!db.objectStoreNames.contains(objectStoreName)) {
      print(
          'Creating objectStore $objectStoreName in database $databaseName...');
      final versao = db.version + 1;
      db.close();
      db = await abrirIndexedDb(_idb, databaseName, versao, (db) {
        if (!db.objectStoreNames.contains(objectStoreName)) {
          db.createObjectStore(objectStoreName);
        }
      });
    }

    print('Got object store $objectStoreName in database $databaseName.');

    return StorageBackendWeb(db, cipher, objectStoreName);
  }

  @override
  Future<void> deleteBox(String name, String? path, String? collection) async {
    print('Delete $name // $collection from disk');

    final databaseName = collection ?? name;
    final objectStoreName = collection == null ? 'box' : name;

    if (collection == null) {
      await aguardarIdb(_idb.deleteDatabase(databaseName));
    } else {
      final db = await abrirIndexedDb(_idb, databaseName, 1, (db) {
        if (db.objectStoreNames.contains(objectStoreName)) {
          db.deleteObjectStore(objectStoreName);
        }
      });
      final vazio = db.objectStoreNames.length == 0;
      db.close();
      if (vazio) {
        await aguardarIdb(_idb.deleteDatabase(databaseName));
      }
    }
  }

  @override
  Future<bool> boxExists(String name, String? path, String? collection) async {
    final databaseName = collection ?? name;
    final objectStoreName = collection == null ? 'box' : name;
    // https://stackoverflow.com/a/17473952
    try {
      var existe = true;
      if (collection == null) {
        final req = _idb.open(databaseName, 1);
        final pronto = Completer<void>();
        req.onupgradeneeded = ((web.IDBVersionChangeEvent _) {
          // o banco não existia: aborta a criação e responde "não existe"
          existe = false;
          req.transaction?.abort();
        }).toJS;
        req.onsuccess = ((web.Event _) {
          (req.result as web.IDBDatabase).close();
          if (!pronto.isCompleted) pronto.complete();
        }).toJS;
        req.onerror = ((web.Event e) {
          e.preventDefault();
          if (!pronto.isCompleted) pronto.completeError(erroIdb(req.error));
        }).toJS;
        await pronto.future;
      } else {
        final db = await abrirIndexedDb(_idb, collection, 1, (db) {
          existe = db.objectStoreNames.contains(objectStoreName);
        });
        existe = db.objectStoreNames.contains(objectStoreName);
        db.close();
      }
      return existe;
    } catch (_) {
      return false;
    }
  }
}

/// Abre [nome] na [versao]; [aoAtualizar] roda no `upgradeneeded`.
Future<web.IDBDatabase> abrirIndexedDb(web.IDBFactory idb, String nome,
    int versao, void Function(web.IDBDatabase db) aoAtualizar) {
  final req = idb.open(nome, versao);
  final pronto = Completer<web.IDBDatabase>();
  req.onupgradeneeded = ((web.IDBVersionChangeEvent _) {
    aoAtualizar(req.result as web.IDBDatabase);
  }).toJS;
  req.onsuccess = ((web.Event _) {
    if (!pronto.isCompleted) pronto.complete(req.result as web.IDBDatabase);
  }).toJS;
  req.onerror = ((web.Event _) {
    if (!pronto.isCompleted) pronto.completeError(erroIdb(req.error));
  }).toJS;
  return pronto.future;
}

/// Espera um pedido do IndexedDB e devolve o `result`.
Future<JSAny?> aguardarIdb(web.IDBRequest req) {
  final pronto = Completer<JSAny?>();
  req.onsuccess = ((web.Event _) {
    if (!pronto.isCompleted) pronto.complete(req.result);
  }).toJS;
  req.onerror = ((web.Event _) {
    if (!pronto.isCompleted) pronto.completeError(erroIdb(req.error));
  }).toJS;
  return pronto.future;
}

/// Erro legível a partir do DOMException do IndexedDB.
Object erroIdb(web.DOMException? e) => e == null
    ? StateError('IndexedDB: erro sem detalhe')
    : StateError('IndexedDB: ${e.name}: ${e.message}');
