import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/xboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _inviteController = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  bool _sending = false;
  int _countdown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _inviteController.dispose();
    super.dispose();
  }

  bool get _canSendCode =>
      !_sending && _countdown == 0 && _emailController.text.contains('@');

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (!email.contains('@')) {
      context.showSnackBar(appLocalizations.emptyTip(appLocalizations.xbEmail));
      return;
    }
    setState(() => _sending = true);
    try {
      await ref.read(xboardSessionProvider.notifier).sendEmailVerify(email);
      if (!mounted) return;
      context.showSnackBar(appLocalizations.xbSendCode);
      setState(() => _countdown = 60);
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return timer.cancel();
        setState(() => _countdown = _countdown - 1);
        if (_countdown <= 0) timer.cancel();
      });
    } on XboardException catch (error) {
      if (mounted) context.showSnackBar(error.message);
    } catch (error) {
      if (mounted) context.showSnackBar(error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || code.isEmpty || password.length < 8) {
      context.showSnackBar(
        appLocalizations.emptyTip('${appLocalizations.xbEmail}/8+'),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      await ref.read(xboardSessionProvider.notifier).register(
            email: email,
            password: password,
            emailCode: code,
            inviteCode: _inviteController.text.trim(),
          );
      if (mounted) Navigator.of(context).pop();
    } on XboardException catch (error) {
      if (mounted) context.showSnackBar(error.message);
    } catch (error) {
      if (mounted) context.showSnackBar(error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: appLocalizations.xbRegister,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            const SizedBox(height: 16),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: appLocalizations.xbEmail,
                prefixIcon: const Icon(Icons.mail_outline_rounded),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: appLocalizations.xbEmailCode,
                      prefixIcon: const Icon(Icons.verified_outlined),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonal(
                  onPressed: _canSendCode ? _sendCode : null,
                  child: Text(
                    _countdown > 0
                        ? '$_countdown s'
                        : (_sending ? '...' : appLocalizations.xbSendCode),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: appLocalizations.xbPassword,
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _inviteController,
              decoration: InputDecoration(
                labelText: appLocalizations.xbInviteCodeOptional,
                prefixIcon: const Icon(Icons.card_giftcard_rounded),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _loading ? null : _submit,
              child: _loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(appLocalizations.xbRegister),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(appLocalizations.xbHasAccount),
            ),
          ],
        ),
      ),
    );
  }
}
