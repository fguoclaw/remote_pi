import 'dart:async';
import 'dart:typed_data';

import 'package:app/pairing/storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:remote_pi_identity/remote_pi_identity.dart';

/// Outcome of a `bridge.boot()` call. The router uses this to decide
/// between "show sync-required gate" and "boot normally".
sealed class OwnerIdentityBootResult {
  const OwnerIdentityBootResult();
}

/// Platform key-sync surface is off — caller must surface the
/// platform-specific config instructions and *not* generate a local
/// identity (would silently diverge with sync later).
final class SyncUnavailableResult extends OwnerIdentityBootResult {
  const SyncUnavailableResult();
}

/// Either loaded from sync or freshly generated. Carries the
/// 32-byte public key so callers can stash it before challenge-response
/// time; the private key stays on-disk to avoid keeping it in heap.
final class IdentityReady extends OwnerIdentityBootResult {
  final OwnerIdentity identity;
  /// True when this run generated the keypair instead of loading it.
  /// Surfaced for telemetry / "fresh install" UX decisions.
  final bool generated;
  const IdentityReady(this.identity, {required this.generated});
}

/// Plan 23 (revisão) — de onde veio a Owner-key em uso nesta sessão.
enum OwnerIdentitySource {
  /// Nada bootado ainda.
  none,

  /// Platform store (iCloud Keychain / Block Store) — caminho do plan/23.
  synced,

  /// Fallback local ([LocalOwnerIdentityStore]): device cujo surface de
  /// sync não é utilizável (ex.: Android sem Google Play Services). Só
  /// acontece depois do opt-in explícito na tela `/sync-required`.
  local,
}

/// Bridge between the `remote_pi_identity` plugin and the rest of the
/// app. Responsibilities:
///
/// - Boot-time decision: sync available? identity present?
/// - `currentIdentity` getter for callers that need the Owner-sk for
///   relay challenge-response (production transport factory).
/// - Watch-on-sync hook: when the platform delivers a different
///   Owner-key (restored on a new device, owner re-installed elsewhere),
///   wipe local peer/room caches because the previous device's
///   `remote_epk` set is meaningless against a fresh identity.
class OwnerIdentityBridge extends ChangeNotifier {
  final OwnerIdentityStore _store;
  final PairingStorage _pairing;

  /// Plan 23 (revisão) — fallback local, usado **só** quando o platform
  /// store não é utilizável. Null desliga o fallback (testes/debug).
  final OwnerIdentityStore? _localStore;

  final Ed25519 _ed25519 = Ed25519();

  OwnerIdentity? _current;
  OwnerIdentitySource _source = OwnerIdentitySource.none;

  /// True quando a chave local foi criada neste processo (primeiro
  /// opt-in). O `generated` do [IdentityReady] usa isto pra que a
  /// primeira abertura caia no onboarding, igual ao caminho com sync.
  bool _localGeneratedThisRun = false;

  StreamSubscription<OwnerIdentity>? _watchSub;
  bool _disposed = false;

  OwnerIdentityBridge(this._store, this._pairing, {OwnerIdentityStore? localStore})
      : _localStore = localStore;

  OwnerIdentity? get currentIdentity => _current;

  /// Plan 23 (revisão) — a sessão está rodando com chave local (sem sync).
  bool get usesLocalFallback => _source == OwnerIdentitySource.local;

  /// De onde veio a Owner-key em uso.
  OwnerIdentitySource get source => _source;

  /// Public key of the currently-loaded Owner identity (or null when
  /// the bridge hasn't booted yet). Surfaces this for the router's
  /// guard logic.
  Uint8List? get currentOwnerPk => _current?.ownerPk;

  /// Load (or generate) the Owner identity.
  /// Idempotent — repeated calls are cheap once `_current` is populated.
  ///
  /// Ordem de preferência (plan/23 revisão — "local wins"):
  ///  1. uma identidade **local** já persistida: autoritativa neste
  ///     device. O platform store não pode substituí-la depois (ver
  ///     [startWatching]) — se ele estiver utilizável, a chave local sobe
  ///     pra lá (convergência) em vez de nascer uma segunda identidade.
  ///  2. o platform store, exatamente como no plan/23 original.
  ///  3. com [allowLocalFallback], gera e persiste uma chave local quando
  ///     o platform store não é utilizável. Esse flag só é passado pela
  ///     tela `/sync-required`, depois do usuário escolher abertamente
  ///     seguir sem backup — o boot normal **nunca** cria chave local.
  ///
  /// The `isSyncAvailable()` pre-flight is deliberately NOT a gate here
  /// (issue #39): on iOS it used to mirror the ubiquity token, which is
  /// always nil without an iCloud entitlement, so every App Store user
  /// hard-locked on "Sync required" regardless of their iCloud Keychain
  /// state. The real capability check is the load/save path — the store
  /// throws [SyncUnavailable] when the platform sync surface genuinely
  /// can't hold the key (e.g. Android Block Store without backup), and
  /// only that verdict sends the router to /sync-required.
  Future<OwnerIdentityBootResult> boot({bool allowLocalFallback = false}) async {
    final local = await _loadLocal();
    if (local != null) {
      _current = local;
      _source = OwnerIdentitySource.local;
      // Best-effort: se o sync virou utilizável desde o opt-in, empurra a
      // chave local pra lá (convergência). Falha aqui (sync ainda off) é
      // esperada e silenciosa.
      await convergeToPlatform();
      return IdentityReady(local, generated: _localGeneratedThisRun);
    }

    try {
      final loaded = await _store.load();
      if (loaded != null) {
        _current = loaded;
        _source = OwnerIdentitySource.synced;
        return IdentityReady(loaded, generated: false);
      }
    } on SyncUnavailable {
      if (allowLocalFallback) return _generateLocalIdentity();
      return const SyncUnavailableResult();
    } on IdentityStoreError {
      // Load failed — fall through and generate a fresh identity.
    }

    try {
      final generated = await _generateAndSave();
      _current = generated;
      _source = OwnerIdentitySource.synced;
      return IdentityReady(generated, generated: true);
    } on SyncUnavailable {
      if (allowLocalFallback) return _generateLocalIdentity();
      return const SyncUnavailableResult();
    }
  }

  /// Plan 23 (revisão) — empurra a identidade local para o platform
  /// store, quando ele estiver utilizável. Retorna `true` se convergiu
  /// nesta chamada. Sem efeito quando a sessão não está em modo local.
  Future<bool> convergeToPlatform() async {
    if (_source != OwnerIdentitySource.local) return false;
    final id = _current;
    if (id == null) return false;
    try {
      await _store.save(id);
      return true;
    } on IdentityStoreError {
      return false;
    }
  }

  /// Leitura do fallback local, tolerante a falha: se o secure storage
  /// não responder, o fallback simplesmente não é uma opção aqui e o
  /// caminho do platform store decide (nunca derruba o boot).
  Future<OwnerIdentity?> _loadLocal() async {
    final store = _localStore;
    if (store == null) return null;
    try {
      return await store.load();
    } on IdentityStoreError {
      return null;
    }
  }

  /// Cria a chave local (opt-in). Falha só se o próprio secure storage
  /// não persistir — nesse caso não há caminho e a tela de sync continua.
  Future<OwnerIdentityBootResult> _generateLocalIdentity() async {
    final store = _localStore;
    if (store == null) return const SyncUnavailableResult();
    try {
      final kp = await _ed25519.newKeyPair();
      final pub = await kp.extractPublicKey();
      final priv = await kp.extractPrivateKeyBytes();
      final id = OwnerIdentity(
        ownerPk: Uint8List.fromList(pub.bytes),
        ownerSk: Uint8List.fromList(priv),
      );
      await store.save(id);
      _current = id;
      _source = OwnerIdentitySource.local;
      _localGeneratedThisRun = true;
      return IdentityReady(id, generated: true);
    } on IdentityStoreError {
      return const SyncUnavailableResult();
    }
  }

  Future<OwnerIdentity> _generateAndSave() async {
    final kp = await _ed25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    final priv = await kp.extractPrivateKeyBytes();
    final id = OwnerIdentity(
      ownerPk: Uint8List.fromList(pub.bytes),
      ownerSk: Uint8List.fromList(priv),
    );
    await _store.save(id);
    return id;
  }

  /// Rehydrate a `SimpleKeyPair` from the cached Owner identity. Used
  /// at challenge-response time — callers must have already gone
  /// through [boot] (otherwise [currentIdentity] would still be null
  /// and this throws `StateError`).
  Future<SimpleKeyPair> requireKeyPair() async {
    final id = _current;
    if (id == null) {
      throw StateError(
        'OwnerIdentityBridge.requireKeyPair() called before boot() — '
        'router should have gated this path on IdentityReady.',
      );
    }
    return _ed25519.newKeyPairFromSeed(id.ownerSk);
  }

  /// Subscribe to platform sync events. When the incoming Owner-pk
  /// differs from [_current], the bridge:
  ///   1. wipes [PairingStorage] (peers + rooms) — stale handles.
  ///   2. caches the new identity.
  ///   3. calls [onReset] so the host can force a fresh router boot.
  ///
  /// Same-pk events are dropped — re-saves of identical content (echo
  /// from our own write) shouldn't reset state.
  ///
  /// Initial-emit race: both the iOS plugin (`KeychainSyncStore`
  /// onListen → emitIfChanged) and the Android plugin (initial
  /// `store.load()` on subscribe) push the current blob to the event
  /// channel as soon as we `.listen()`. If we subscribed before
  /// [boot] populated `_current`, that initial emit would look like
  /// a "different owner_pk" (because current is null) and trigger a
  /// spurious `wipeAll`. That cleared the freshly-paired peer set,
  /// and a downstream `_maybeAdoptLegacyRoom` (driven by an incoming
  /// `room_announced`) would then re-publish v=N+1 with members=[],
  /// causing the pi-extension to self-revoke ~60s later.
  ///
  /// Defence: when `_current` is null at observation time, treat the
  /// event as the platform's initial-snapshot and *adopt without
  /// wiping*. The host should also order calls so `startWatching`
  /// runs after `boot()` whenever possible, but this guard makes the
  /// bridge correct even when the order is reversed (e.g. router
  /// boot is fire-and-forget).
  void startWatching({required Future<void> Function() onReset}) {
    _watchSub?.cancel();
    _watchSub = _store.watch().listen((incoming) async {
      // Plan 23 (revisão, "local wins"): enquanto a sessão rodar com
      // chave local, ela é autoritativa neste device. Uma chave diferente
      // vinda do platform store não pode substituí-la — isso rotacionaria
      // a identidade e órfãoaria os pareamentos do usuário. A convergência
      // vai no sentido oposto: `convergeToPlatform()` empurra a chave
      // local pra cima.
      if (_source == OwnerIdentitySource.local) return;
      final current = _current;
      if (current == null) {
        _current = incoming;
        return;
      }
      if (_bytesEqual(current.ownerPk, incoming.ownerPk)) {
        return;
      }
      _current = incoming;
      await _pairing.wipeAll();
      await onReset();
    }, onError: (Object e) {
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _watchSub?.cancel();
    _watchSub = null;
    super.dispose();
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
