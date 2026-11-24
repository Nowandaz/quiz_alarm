/// "Messages": what the team has sent, newest first, and the banner that
/// shows the newest unread one on the first screen.
library;

import 'dart:async';

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../services/announcements.dart';

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  @override
  void initState() {
    super.initState();
    // Opening the list reads everything, and looks for anything newer.
    Announcements.markRead();
    Announcements.run(force: true).then((_) => Announcements.markRead());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: ValueListenableBuilder<List<Announcement>>(
        valueListenable: Announcements.all,
        builder: (context, list, _) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No messages yet. News about new topics and updates '
                  'will show here.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final a = list[i];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.title, style: theme.textTheme.titleMedium),
                      if (a.body.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(a.body, style: theme.textTheme.bodyMedium),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            DateFormat('d MMM y').format(a.publishedAt),
                            style: theme.textTheme.bodySmall,
                          ),
                          const Spacer(),
                          if (a.link.isNotEmpty)
                            TextButton(
                              onPressed: () => Announcements.open(a),
                              child: const Text('Open'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Pops the newest unread message up over the first screen. It waits
/// while another screen (a ringing alarm, the editor) is on top.
class MessageBanner extends StatefulWidget {
  const MessageBanner({super.key});

  @override
  State<MessageBanner> createState() => _MessageBannerState();
}

class _MessageBannerState extends State<MessageBanner> {
  bool _showing = false;
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    Announcements.unread.addListener(_maybeShow);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  @override
  void dispose() {
    Announcements.unread.removeListener(_maybeShow);
    _retry?.cancel();
    super.dispose();
  }

  void _maybeShow() {
    _retry?.cancel();
    final a = Announcements.unread.value;
    if (!mounted || _showing || a == null) return;
    if (ModalRoute.of(context)?.isCurrent != true) {
      // Something else is on top: look again shortly.
      _retry = Timer(const Duration(seconds: 3), _maybeShow);
      return;
    }
    _show(a);
  }

  Future<void> _show(Announcement a) async {
    _showing = true;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.campaign_rounded),
        title: Text(a.title),
        content: a.body.isEmpty
            ? null
            : SingleChildScrollView(
                child: Text(a.body, style: const TextStyle(height: 1.35)),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'all'),
            child: const Text('All messages'),
          ),
          if (a.link.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'open'),
              child: const Text('Open'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'ok'),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    // Seen, however it was closed.
    await Announcements.markRead();
    _showing = false;
    if (!mounted) return;
    if (choice == 'open') {
      Announcements.open(a);
    } else if (choice == 'all') {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const MessagesScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
