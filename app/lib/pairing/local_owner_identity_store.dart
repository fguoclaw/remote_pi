import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

/// Plan 23 (revisão) — store **local** da Owner-key, sem sync.
///
/// Existe para um caso que o plan 23 original não cobria: devices **sem
/// Google Play Services**, onde o Block Store não é sequer sondável
/// (`isSyncAvailable()` falha antes de qualquer leitura) e o app travava
/// na tela `/sync-required` sem saída. Ex.: tablets e-ink Android 12
/// (Onyx BOOX T10C).
///
/// Backing store: [FlutterSecureStorage] — no Android é
/// EncryptedSharedPreferences sobre o Keystore do sistema, que **não**
/// depende de GMS. É o mesmo store que o app já usa para peers,
/// preferences e dismiss de update.
///
/// Trade-off aceito ao optar por este caminho (e é opt-in explícito na
/// tela `/sync-required`, nunca automático): a chave **não** viaja entre
/// devices. Trocou de aparelho ou reinstalou → pareia de novo.
///
/// Regra de convergência ("local wins"): enquanto existir uma identidade
/// local, ela é autoritativa neste device. Se o surface de sync virar
/// utilizável depois, `OwnerIdentityBridge` empurra a chave local para o
/// platform store — as duas pontas convergem, em vez de virar duas
/// identidades para o mesmo humano (a divergência silenciosa que o plan
/// 23 queria evitar).
class LocalOwnerIdentityStore implements OwnerIdentityStore {
  /// Chave própria, prefixada pra não colidir com as chaves que o
  /// `PairingStorage` e o `Preferences` escrevem no mesmo store.
  static const storageKey = 'dev.remotepi.owner.identity:local';

  final FlutterSecureStorage _secure;

  LocalOwnerIdentityStore([FlutterSecureStorage? secure])
      : _secure = secure ?? const FlutterSecureStorage();

  @override
  Future<OwnerIdentity?> load() async {
    final String? encoded;
    try {
      encoded = await _secure.read(key: storageKey);
    } catch (e) {
      throw PlatformFailure('secure_storage_read', e.toString());
    }
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return OwnerIdentity.fromBlob(base64Decode(encoded));
    } on FormatException {
      // Blob truncado/ilegível: trata como ausente (uma chave nova é
      // gerada) em vez de brickar o boot — neste device este store é a
      // única saída possível.
      return null;
    }
  }

  @override
  Future<void> save(OwnerIdentity identity) async {
    try {
      await _secure.write(
        key: storageKey,
        value: base64Encode(identity.toBlob()),
      );
    } catch (e) {
      throw PlatformFailure('secure_storage_write', e.toString());
    }
  }

  @override
  Future<void> delete() async {
    try {
      await _secure.delete(key: storageKey);
    } catch (e) {
      throw PlatformFailure('secure_storage_delete', e.toString());
    }
  }

  /// Nada sincroniza aqui — stream vazio. O bridge instala o watcher do
  /// platform store de qualquer forma; quando a sessão está em modo
  /// local, ele ignora os eventos (chave local é autoritativa).
  @override
  Stream<OwnerIdentity> watch() => const Stream<OwnerIdentity>.empty();

  /// Este store nunca sincroniza: sempre `false`. Não é erro — é a
  /// resposta honesta, e o motivo de ele só ser usado como fallback
  /// depois do opt-in explícito.
  @override
  Future<bool> isSyncAvailable() async => false;
}
