// Regression tests for OwnerIdentityBridge's watch listener — see
// plan/24-fix-app-publish-race (follow-up). The platform plugins
// emit their current blob the moment we subscribe, which used to
// race against boot()'s population of `_current` and trigger a
// spurious `wipeAll` of the freshly-loaded peer set.

import 'dart:async';
import 'dart:typed_data';

import 'package:app/pairing/local_owner_identity_store.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }
  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);
  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(_store);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Fallback local que não consegue persistir (Keystore indisponível,
/// secure storage quebrado).
class _BrokenLocalStore implements OwnerIdentityStore {
  @override
  Future<OwnerIdentity?> load() async {
    throw const PlatformFailure('secure_storage_read', 'boom');
  }

  @override
  Future<void> save(OwnerIdentity identity) async {
    throw const PlatformFailure('secure_storage_write', 'boom');
  }

  @override
  Future<void> delete() async {
    throw const PlatformFailure('secure_storage_delete', 'boom');
  }

  @override
  Stream<OwnerIdentity> watch() => const Stream<OwnerIdentity>.empty();

  @override
  Future<bool> isSyncAvailable() async => false;
}

Future<OwnerIdentity> _freshIdentity() async {
  final kp = await Ed25519().newKeyPair();
  final pub = await kp.extractPublicKey();
  final sk = await kp.extractPrivateKeyBytes();
  return OwnerIdentity(
    ownerPk: Uint8List.fromList(pub.bytes),
    ownerSk: Uint8List.fromList(sk),
  );
}

/// Reproduces the issue #39 shape: the pre-flight reports "unavailable"
/// (on iOS the old ubiquity-token check was ALWAYS false in App Store
/// builds) while the real read/write path works fine — iCloud Keychain
/// needs no entitlement.
class _FalsePreflightStore implements OwnerIdentityStore {
  final InMemoryOwnerIdentityStore _inner;
  _FalsePreflightStore(this._inner);

  @override
  Future<bool> isSyncAvailable() async => false;
  @override
  Future<OwnerIdentity?> load() => _inner.load();
  @override
  Future<void> save(OwnerIdentity identity) => _inner.save(identity);
  @override
  Future<void> delete() => _inner.delete();
  @override
  Stream<OwnerIdentity> watch() => _inner.watch();
}

void main() {
  group('OwnerIdentityBridge.boot — issue #39 (pre-flight must not gate)', () {
    test('boot succeeds when pre-flight is false but load/save work', () async {
      // Fresh install: no stored identity, pre-flight lies "unavailable".
      final store = _FalsePreflightStore(InMemoryOwnerIdentityStore());
      final bridge = OwnerIdentityBridge(
        store,
        PairingStorage(_FakeSecureStorage()),
      );

      final result = await bridge.boot();

      expect(result, isA<IdentityReady>());
      expect((result as IdentityReady).generated, isTrue);
      expect(bridge.currentOwnerPk, isNotNull);
    });

    test('boot loads an existing identity even with a false pre-flight',
        () async {
      final id = await _freshIdentity();
      final store = _FalsePreflightStore(InMemoryOwnerIdentityStore(initial: id));
      final bridge = OwnerIdentityBridge(
        store,
        PairingStorage(_FakeSecureStorage()),
      );

      final result = await bridge.boot();

      expect(result, isA<IdentityReady>());
      expect((result as IdentityReady).generated, isFalse);
      expect(bridge.currentOwnerPk, id.ownerPk);
    });

    test(
        'boot still gates when the real load/save path throws '
        'SyncUnavailable (Android Block Store parity)', () async {
      final store = InMemoryOwnerIdentityStore(syncAvailable: false);
      final bridge = OwnerIdentityBridge(
        store,
        PairingStorage(_FakeSecureStorage()),
      );

      final result = await bridge.boot();

      expect(result, isA<SyncUnavailableResult>());
      expect(bridge.currentOwnerPk, isNull);
    });
  });

  group('plan/23 revisão — fallback de chave local (device sem sync)', () {
    test('boot() normal NUNCA cria chave local sozinho', () async {
      final local = LocalOwnerIdentityStore(_FakeSecureStorage());
      final bridge = OwnerIdentityBridge(
        InMemoryOwnerIdentityStore(syncAvailable: false),
        PairingStorage(_FakeSecureStorage()),
        localStore: local,
      );

      final result = await bridge.boot();

      expect(result, isA<SyncUnavailableResult>());
      expect(bridge.currentOwnerPk, isNull);
      expect(bridge.usesLocalFallback, isFalse);
      expect(await local.load(), isNull,
          reason: 'sem opt-in explícito nada é persistido localmente');
    });

    test('boot(allowLocalFallback: true) gera e persiste a chave local',
        () async {
      final secure = _FakeSecureStorage();
      final local = LocalOwnerIdentityStore(secure);
      final bridge = OwnerIdentityBridge(
        InMemoryOwnerIdentityStore(syncAvailable: false),
        PairingStorage(_FakeSecureStorage()),
        localStore: local,
      );

      final result = await bridge.boot(allowLocalFallback: true);

      expect(result, isA<IdentityReady>());
      expect((result as IdentityReady).generated, isTrue);
      expect(bridge.usesLocalFallback, isTrue);
      expect(bridge.source, OwnerIdentitySource.local);
      final persisted = await local.load();
      expect(persisted, isNotNull);
      expect(persisted!.ownerPk, bridge.currentOwnerPk);
    });

    test('aberturas seguintes do app usam a chave local sem novo opt-in',
        () async {
      final secure = _FakeSecureStorage();
      final local = LocalOwnerIdentityStore(secure);
      // Primeiro opt-in (processo anterior).
      final first = OwnerIdentityBridge(
        InMemoryOwnerIdentityStore(syncAvailable: false),
        PairingStorage(_FakeSecureStorage()),
        localStore: local,
      );
      final firstResult = await first.boot(allowLocalFallback: true);
      final pk = first.currentOwnerPk!;

      // Novo processo: boot normal, platform store continua fora.
      final second = OwnerIdentityBridge(
        InMemoryOwnerIdentityStore(syncAvailable: false),
        PairingStorage(_FakeSecureStorage()),
        localStore: local,
      );
      final secondResult = await second.boot();

      expect(firstResult, isA<IdentityReady>());
      expect(secondResult, isA<IdentityReady>());
      expect((secondResult as IdentityReady).generated, isFalse,
          reason: 'a chave veio do store local, não foi gerada de novo');
      expect(second.usesLocalFallback, isTrue);
      expect(second.currentOwnerPk, pk, reason: 'mesma identidade, sem QR novo');
    });

    test('local wins: identidade local vence a do platform store e converge '
        'empurrando ela pra cima', () async {
      final localId = await _freshIdentity();
      final platformId = await _freshIdentity();
      final secure = _FakeSecureStorage();
      final local = LocalOwnerIdentityStore(secure);
      await local.save(localId);
      final platform = InMemoryOwnerIdentityStore(initial: platformId);
      final bridge = OwnerIdentityBridge(
        platform,
        PairingStorage(_FakeSecureStorage()),
        localStore: local,
      );

      final result = await bridge.boot();

      expect((result as IdentityReady).identity.ownerPk, localId.ownerPk);
      expect(bridge.usesLocalFallback, isTrue);
      // Convergência: o platform store passou a ter a MESMA chave, em vez
      // de virar uma segunda identidade pro mesmo humano.
      expect((await platform.load())!.ownerPk, localId.ownerPk);
    });

    test('platform indisponível não impede o boot local (convergência é '
        'best-effort)', () async {
      final localId = await _freshIdentity();
      final local = LocalOwnerIdentityStore(_FakeSecureStorage());
      await local.save(localId);
      final bridge = OwnerIdentityBridge(
        InMemoryOwnerIdentityStore(syncAvailable: false),
        PairingStorage(_FakeSecureStorage()),
        localStore: local,
      );

      final result = await bridge.boot();

      expect(result, isA<IdentityReady>());
      expect(bridge.currentOwnerPk, localId.ownerPk);
    });

    test('secure storage local quebrado não derruba o boot (volta pro gate)',
        () async {
      final bridge = OwnerIdentityBridge(
        InMemoryOwnerIdentityStore(syncAvailable: false),
        PairingStorage(_FakeSecureStorage()),
        localStore: _BrokenLocalStore(),
      );

      expect(await bridge.boot(), isA<SyncUnavailableResult>());
      expect(
        await bridge.boot(allowLocalFallback: true),
        isA<SyncUnavailableResult>(),
        reason: 'nem a chave local persistiu: não há caminho neste device',
      );
    });

    test('source = local: chave diferente vinda do platform NÃO substitui a '
        'local nem apaga os peers', () async {
      final localId = await _freshIdentity();
      final local = LocalOwnerIdentityStore(_FakeSecureStorage());
      await local.save(localId);
      final platform = InMemoryOwnerIdentityStore(syncAvailable: false);
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-precious',
        sessionName: 'pi',
        relayUrl: 'https://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));
      final bridge = OwnerIdentityBridge(platform, storage, localStore: local);
      await bridge.boot(); // local wins

      var resets = 0;
      bridge.startWatching(onReset: () async => resets++);

      // O sync "fica bom" e entrega OUTRA chave (ex.: veio de um restore
      // de outro device).
      platform.syncAvailable = true;
      await platform.save(await _freshIdentity());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bridge.currentOwnerPk, localId.ownerPk);
      expect(await storage.listPeers(), hasLength(1),
          reason: 'chave local é autoritativa: nada de wipe');
      expect(resets, 0);
    });
  });

  group('LocalOwnerIdentityStore', () {
    test('roundtrip save → load preserva os 64 bytes', () async {
      final store = LocalOwnerIdentityStore(_FakeSecureStorage());
      final id = await _freshIdentity();

      await store.save(id);
      final loaded = await store.load();

      expect(loaded, isNotNull);
      expect(loaded!.ownerPk, id.ownerPk);
      expect(loaded.ownerSk, id.ownerSk);
    });

    test('sem valor persistido → null (primeira abertura)', () async {
      expect(await LocalOwnerIdentityStore(_FakeSecureStorage()).load(),
          isNull);
    });

    test('blob corrompido → null em vez de exceção', () async {
      final secure = _FakeSecureStorage();
      await secure.write(
        key: LocalOwnerIdentityStore.storageKey,
        value: 'nao-e-base64-64-bytes',
      );
      final store = LocalOwnerIdentityStore(secure);

      expect(await store.load(), isNull);
    });

    test('delete limpa o valor', () async {
      final store = LocalOwnerIdentityStore(_FakeSecureStorage());
      await store.save(await _freshIdentity());

      await store.delete();

      expect(await store.load(), isNull);
    });

    test('nunca sincroniza: watch() vazio e isSyncAvailable() false', () async {
      final store = LocalOwnerIdentityStore(_FakeSecureStorage());

      expect(await store.watch().isEmpty, isTrue);
      expect(await store.isSyncAvailable(), isFalse);
    });
  });

  group('OwnerIdentityBridge.startWatching — initial emit race fix', () {
    test(
        'subscribing BEFORE boot() does NOT wipe peers (initial emit adopted '
        'silently)', () async {
      // Reproduce the production race: router calls startWatching
      // fire-and-forget before boot() has populated _current. The
      // store emits the existing blob immediately; without the fix
      // this would clear peers + trigger onReset.
      final id = await _freshIdentity();
      final store = InMemoryOwnerIdentityStore(initial: id);
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-precious',
        sessionName: 'pi',
        relayUrl: 'https://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));
      final bridge = OwnerIdentityBridge(store, storage);

      var resetCalls = 0;
      bridge.startWatching(onReset: () async => resetCalls++);

      // Force the initial-emit through the in-memory store. The
      // production iOS/Android plugins do this from onListen; the
      // in-memory fake exposes the same shape via a save() that
      // echoes through the broadcast controller.
      await store.save(id);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The peer survives — no wipe happened.
      final peers = await storage.listPeers();
      expect(peers, hasLength(1));
      expect(peers.single.remoteEpk, 'epk-precious');
      // No reset callback was invoked.
      expect(resetCalls, 0);
    });

    test(
        'after the initial emit was adopted, a *different* owner_pk DOES '
        'wipe + reset', () async {
      // Confirm the regression fix didn't soften the legitimate
      // "Owner key rotated via sync" path.
      final first = await _freshIdentity();
      final second = await _freshIdentity();
      final store = InMemoryOwnerIdentityStore(initial: first);
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-old',
        sessionName: 'pi',
        relayUrl: 'https://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));
      final bridge = OwnerIdentityBridge(store, storage);

      final resetCompleter = Completer<void>();
      bridge.startWatching(onReset: () async {
        if (!resetCompleter.isCompleted) resetCompleter.complete();
      });

      // First emit (initial) — adopted silently.
      await store.save(first);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await storage.listPeers(), hasLength(1),
          reason: 'initial emit must not wipe');

      // Now a real key rotation — different bytes. wipeAll fires.
      await store.save(second);
      await resetCompleter.future.timeout(const Duration(seconds: 1));
      expect(await storage.listPeers(), isEmpty,
          reason: 'real key rotation must wipe');
    });

    test('same-pk re-emit after adoption is a noop (no wipe, no reset)',
        () async {
      final id = await _freshIdentity();
      final store = InMemoryOwnerIdentityStore(initial: id);
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-stable',
        sessionName: 'pi',
        relayUrl: 'https://r',
        pairedAt: '2026-05-15T10:30:00Z',
      ));
      final bridge = OwnerIdentityBridge(store, storage);
      var resets = 0;
      bridge.startWatching(onReset: () async => resets++);

      await store.save(id); // initial-emit adoption
      await store.save(id); // same-pk echo — must be ignored
      await store.save(id);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await storage.listPeers(), hasLength(1));
      expect(resets, 0);
    });
  });
}
