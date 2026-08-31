import 'package:bett_box/common/common.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:bett_box/xboard/xboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ForgetPage extends ConsumerStatefulWidget {
  const ForgetPage({super.key});

  @override
  ConsumerState<ForgetPage> createState() => _ForgetPageState();
}

class _ForgetPageState extends ConsumerState<ForgetPage> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (!email.contains('@')) {
      context.showSnackBar(appLocalizations.emptyTip(appLocalizations.xbEmail));
      return;
    }
    try {
      await ref.read(xboardSessionProvider.notifier).sendEmailVerify(email);
      if (mounted) context.showSnackBar(appLocalizations.xbSendCode);
    } on XboardException catch (error) {
      if (mounted) context.showSnackBar(error.message);
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
      await ref.read(xboardAuthRepositoryProvider).forget(
            email: email,
            emailCode: code,
            password: password,
          );
      if (mounted) {
        context.showSnackBar(appLocalizations.success);
        Navigator.of(context).pop();
      }
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
      title: appLocalizations.xbResetPassword,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            const SizedBox(height: 16),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
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
                  onPressed: _sendCode,
                  child: Text(appLocalizations.xbSendCode),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: appLocalizations.xbNewPassword,
                prefixIcon: const Icon(Icons.lock_outline_rounded),
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
                  : Text(appLocalizations.xbResetPassword),
            ),
          ],
        ),
      ),
    );
  }
}
