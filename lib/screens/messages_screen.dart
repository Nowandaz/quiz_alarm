/// "Messages": what the team has sent, newest first, and the banner that
/// shows the newest unread one on the first screen.
library;

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

/// The newest unread message, on the first screen.
class MessageBanner extends StatelessWidget {
  const MessageBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<Announcement?>(
      valueListenable: Announcements.unread,
      builder: (context, a, _) {
        if (a == null) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.campaign_rounded,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a.title,
                          style: TextStyle(
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (a.body.isNotEmpty)
                          Text(
                            a.body,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSecondaryContainer,
                              height: 1.3,
                              fontSize: 13,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const MessagesScreen()),
                    ),
                    child: const Text('All messages'),
                  ),
                  if (a.link.isNotEmpty)
                    TextButton(
                      onPressed: () {
                        Announcements.open(a);
                        Announcements.markRead();
                      },
                      child: const Text('Open'),
                    ),
                  TextButton(
                    onPressed: Announcements.markRead,
                    child: const Text('OK'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
