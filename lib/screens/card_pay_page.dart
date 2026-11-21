/// Paystack's card page, shown inside the app so the user never leaves it.
/// The card number is typed on Paystack's page only: this file shows the
/// page, watches where it goes, and closes it when Paystack says the
/// payment is finished. Only built on Android and iOS, where a web view
/// exists.
library;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// What to do with an address the payment page wants to go to.
enum CardPageMove { allow, block, finished }

/// Decides about [url]. Reaching [doneUrl] means Paystack is finished.
/// Apart from that the page itself may only go to https addresses, so a
/// payment page can never send the user to an unsafe page or another app.
/// Frames inside the page may also be blank: banks build their "confirm
/// it is you" step that way.
CardPageMove cardPageMove(
  String url, {
  required String doneUrl,
  bool mainFrame = true,
}) {
  if (doneUrl.isNotEmpty && url.startsWith(doneUrl)) {
    return CardPageMove.finished;
  }
  final scheme = Uri.tryParse(url)?.scheme.toLowerCase() ?? '';
  if (scheme == 'https') return CardPageMove.allow;
  if (!mainFrame && scheme == 'about') return CardPageMove.allow;
  return CardPageMove.block;
}

/// Whether this device can show a web page inside the app.
bool get canShowCardPage =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Shows Paystack's page [url] over the whole screen. True when the page
/// reached [doneUrl] (the payment was finished one way or the other),
/// false when the user closed it first.
Future<bool> showCardPage(
  BuildContext context,
  String url,
  String doneUrl,
) async {
  final done = await Navigator.push<bool>(
    context,
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => CardPayPage(url: url, doneUrl: doneUrl),
    ),
  );
  return done ?? false;
}

class CardPayPage extends StatefulWidget {
  final String url;
  final String doneUrl;
  const CardPayPage({super.key, required this.url, required this.doneUrl});

  @override
  State<CardPayPage> createState() => _CardPayPageState();
}

class _CardPayPageState extends State<CardPayPage> {
  late final WebViewController _web;

  /// How much of the page has loaded, 0 to 100.
  int _progress = 0;
  String? _error;

  /// The page is closed once only, however many signals say "finished".
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      // Paystack's page does not work without JavaScript.
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            switch (cardPageMove(
              request.url,
              doneUrl: widget.doneUrl,
              mainFrame: request.isMainFrame,
            )) {
              case CardPageMove.finished:
                _finish();
                return NavigationDecision.prevent;
              case CardPageMove.block:
                return NavigationDecision.prevent;
              case CardPageMove.allow:
                return NavigationDecision.navigate;
            }
          },
          // A second look: some redirects are not offered as a request
          // first, so the address is checked again when a page starts.
          onPageStarted: (url) {
            if (cardPageMove(url, doneUrl: widget.doneUrl) ==
                CardPageMove.finished) {
              _finish();
            } else if (mounted) {
              setState(() => _error = null);
            }
          },
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onWebResourceError: (error) {
            // Only when the page itself failed, not a picture inside it.
            if (error.isForMainFrame != true || !mounted) return;
            setState(
              () => _error =
                  'Could not load the payment page. Check your connection.',
            );
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  void _finish() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final loading = _progress < 100 && _error == null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pay by card'),
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context, false),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: loading
                ? LinearProgressIndicator(
                    value: _progress == 0 ? null : _progress / 100,
                    minHeight: 2,
                  )
                : null,
          ),
        ),
      ),
      body: SafeArea(
        child: _error == null
            ? WebViewWidget(controller: _web)
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _error = null;
                            _progress = 0;
                          });
                          _web.loadRequest(Uri.parse(widget.url));
                        },
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
