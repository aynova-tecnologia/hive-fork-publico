# hive 2.2.3 — fork da aynova para WebAssembly

Fork do [hive 2.2.3](https://pub.dev/packages/hive) (Apache 2.0) na tag `v2.2.3`,
branch `feat/web-wasm-indexeddb`. Usado **só** pelo port web do Timber Track
(`dependency_overrides` com `git` + `path: hive`). Android, iOS e Windows não usam este fork.

## Por que existe

O hive 2.2.3 (última versão publicada, 2022) só tem backend web sobre
`dart:html`, que não existe no WebAssembly (dart2wasm): lá o Hive caía no
backend stub e nenhuma box abria (token de login, configurações, versões da
sync).

## O que mudou em relação ao 2.2.3

- `lib/src/backend/js_web/`: backend IndexedDB novo, sobre `package:web`, com a
  mesma lógica e o mesmo formato do original (os dados gravados por um build
  abrem no outro). Números lidos voltam a ser `int` quando inteiros, como no
  dart2js.
- `lib/src/backend/storage_backend.dart`: `dart.library.js_interop` entra
  DEPOIS de `dart.library.html` na cadeia de imports. O dart2js continua no
  backend original, sem mudança; só o wasm usa o novo.
- `pubspec.yaml`: `sdk >=3.4.0` (exigência do `dart:js_interop`) e dependência
  `web`. Com isso, `HiveCollectionMixin` e `DelegatingListViewMixin` viram
  `abstract mixin class` (regra do Dart 3 para uso como mixin), sem mudança de
  comportamento.

Validado: 368/368 testes do hive na VM; no app, login, 1ª sync, recarga e
leitura de dados gravados por builds anteriores, em JS e em wasm.
