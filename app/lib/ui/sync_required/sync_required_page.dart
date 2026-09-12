import 'dart:io' show Platform;

import 'package:app/config/dependencies.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Plan 23 — first-launch gate when the platform's key-sync surface
/// (iCloud Keychain on iOS, Google Backup / Block Store on Android) is
/// not available. The app cannot proceed without it because the Owner
/// Ed25519 keypair has no other persistence path.
class SyncRequiredPage extends StatefulWidget {
  const SyncRequiredPage({super.key, this.retryBoot});

  /// Plan 23 (revisão) — refaz o boot completo do app (`_BootState.load`),
  /// que é quem decide o gate e quem inicializa peers, watcher de sync e
  /// conexão. Injetado pelo router; null em testes que montem a página
  /// isolada.
  final Future<void> Function()? retryBoot;

  @override
  State<SyncRequiredPage> createState() => _SyncRequiredPageState();
}

class _SyncRequiredPageState extends State<SyncRequiredPage> {
  bool _checking = false;
  bool _localFallbackFailed = false;

  Future<void> _recheck() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _localFallbackFailed = false;
    });

    // Plan 23 (revisão) — antes isso chamava `bridge.boot()` e navegava
    // pra /boot. Como o gate (`_syncAvailable`) só é recalculado dentro de
    // `_BootState.load()`, o redirect devolvia o usuário pra cá pra
    // sempre: habilitar o backup e tocar "Check again" não destravava
    // nada. Agora refazemos o boot inteiro.
    final retry = widget.retryBoot;
    if (retry != null) {
      await retry();
      if (!mounted) return;
      setState(() => _checking = false);
      // Se destravou, o próprio redirect do router leva pra frente
      // (refreshListenable em `_BootState`). Se não, continuamos aqui.
      return;
    }

    final result = await injector.get<OwnerIdentityBridge>().boot();
    if (!mounted) return;
    setState(() => _checking = false);
    if (result is! SyncUnavailableResult) {
      // Bounce through /boot so the router's redirect logic re-evaluates
      // (pairs-empty → /onboarding, pairs-non-empty → /home).
      context.go('/boot');
    }
  }

  /// Plan 23 (revisão) — opt-in explícito pela chave **local**, pra
  /// devices onde o surface de sync não existe (Android sem Google Play
  /// Services: Block Store não é nem sondável). A chave vai pro secure
  /// storage do sistema e não faz backup — trocar de aparelho exige parear
  /// de novo. Nada aqui é automático: só roda com o toque do usuário.
  Future<void> _continueWithLocalKey() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _localFallbackFailed = false;
    });

    final result = await injector
        .get<OwnerIdentityBridge>()
        .boot(allowLocalFallback: true);
    if (!mounted) return;

    if (result is SyncUnavailableResult) {
      // Nem o secure storage local aceitou a chave (Keystore
      // indisponível): não há caminho neste device.
      setState(() {
        _checking = false;
        _localFallbackFailed = true;
      });
      return;
    }

    // Boot completo: peers, watcher e conexão — o mesmo caminho do
    // "Check again" que deu certo.
    await widget.retryBoot?.call();
    if (!mounted) return;
    setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final isIOS = Platform.isIOS;
    final requirements = isIOS ? _iosRequirements : _androidRequirements;
    final why = isIOS
        ? 'Remote Pi keeps your Ed25519 owner key in iCloud Keychain so '
              'you can switch iPhones or pair your iPad without scanning '
              'a new QR.'
        : 'Remote Pi keeps your Ed25519 owner key in Google Block Store '
              'so you can restore it on a new device through Google '
              'Backup without losing your paired Pis.';

    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Icon(
                isIOS ? LucideIcons.cloudOff : LucideIcons.cloudUpload,
                color: colors.accent,
                size: 44,
              ),
              const SizedBox(height: 20),
              Text(
                'Sync required',
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                why,
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 12,
                  color: colors.muted2,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'To enable, on this device:',
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 11,
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.separated(
                  itemCount: requirements.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _RequirementCard(
                    index: i + 1,
                    requirement: requirements[i],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _checking ? null : _recheck,
                style: FilledButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: colors.onAccent,
                  disabledBackgroundColor: colors.border,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(6)),
                  ),
                ),
                child: _checking
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: colors.onAccent,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        'Check again',
                        style: TextStyle(
                          fontFamily: kMonoFamily,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
              const SizedBox(height: 18),
              // Plan 23 (revisão) — saída para devices onde o surface de
              // sync não existe (ex.: Android sem Google Play Services, em
              // que o Block Store não é sequer sondável). Opt-in explícito:
              // a chave fica só neste device.
              _LocalKeyFallback(
                isIOS: isIOS,
                enabled: !_checking,
                failed: _localFallbackFailed,
                onContinue: _continueWithLocalKey,
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// Plan 23 (revisão) — cartucho de saída "sem sync": continua com uma
/// Owner-key local, persistida no secure storage do sistema (Keystore no
/// Android). É opt-in explícito e deixa o trade-off na cara do usuário:
/// a chave não faz backup, então trocar de aparelho exige parear de novo.
class _LocalKeyFallback extends StatelessWidget {
  const _LocalKeyFallback({
    required this.isIOS,
    required this.enabled,
    required this.failed,
    required this.onContinue,
  });

  final bool isIOS;
  final bool enabled;
  final bool failed;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = TextStyle(
      fontFamily: kMonoFamily,
      fontSize: 11,
      color: colors.muted2,
      height: 1.4,
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.border),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isIOS
                ? 'Not signing in to iCloud?'
                : 'No Google services on this device?',
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Keep your key on this device instead. It is not backed up and '
            'does not follow you to a new device — you would pair your Pis '
            'again there.',
            style: mono,
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: enabled ? onContinue : null,
            style: TextButton.styleFrom(
              foregroundColor: colors.accent,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Use a local key instead',
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (failed) ...[
            const SizedBox(height: 6),
            Text(
              'Could not save a key on this device — secure storage refused '
              'the write.',
              style: mono.copyWith(color: colors.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _Requirement {
  final String title;
  final String path;
  final String? note;
  const _Requirement({required this.title, required this.path, this.note});
}

const _androidRequirements = <_Requirement>[
  _Requirement(
    title: 'Set up a screen lock',
    path: 'Settings › Security › Screen lock',
    note: 'PIN, pattern or biometrics — required by Block Store.',
  ),
  _Requirement(
    title: 'Turn on Google Backup',
    path: 'Settings › System › Backup\n'
        '(Samsung: Settings › Accounts and backup › Backup data)',
  ),
  _Requirement(
    title: 'Sign in to a Google account',
    path: 'Settings › Passwords & accounts › Add account › Google',
  ),
];

const _iosRequirements = <_Requirement>[
  _Requirement(
    title: 'Sign in to iCloud',
    path: 'Settings › [your name]',
    note: 'If you see "Sign in to your iPhone" at the top, tap it.',
  ),
  _Requirement(
    title: 'Turn on iCloud Keychain',
    path: 'Settings › [your name] › iCloud › Passwords and Keychain',
    note: 'Toggle "Sync this iPhone" on.',
  ),
];

class _RequirementCard extends StatelessWidget {
  final int index;
  final _Requirement requirement;
  const _RequirementCard({required this.index, required this.requirement});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.border),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.15),
              borderRadius: const BorderRadius.all(Radius.circular(11)),
            ),
            child: Text(
              '$index',
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 11,
                color: colors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  requirement.title,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 13,
                    color: colors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  requirement.path,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 11,
                    color: colors.muted2,
                    height: 1.4,
                  ),
                ),
                if (requirement.note != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    requirement.note!,
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 10.5,
                      color: colors.muted,
                      height: 1.4,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
