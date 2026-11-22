/// "Flag this question for review": the small flag shown next to a
/// question in the history, and the sheet it opens (a reason, an optional
/// note, Send). Flags are kept by lib/data/flag_store.dart.
library;

import 'package:material_ui/material_ui.dart';

import '../data/flag_store.dart';
import '../models/models.dart';
import '../services/account.dart';
import '../widgets/app_widgets.dart';

/// Said to people without an account: their flag waits on the phone.
const String flagSignInNote = 'Sign in to send this to the reviewers.';

/// The flag on one question: an outline while it is not flagged, filled
/// with "Flagged for review" once it is.
class FlagButton extends StatefulWidget {
  final Question question;
  const FlagButton(this.question, {super.key});

  @override
  State<FlagButton> createState() => _FlagButtonState();
}

class _FlagButtonState extends State<FlagButton> {
  QuestionFlag? _flag;

  @override
  void initState() {
    super.initState();
    FlagStore.changes.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(FlagButton old) {
    super.didUpdateWidget(old);
    if (old.question.id != widget.question.id) _load();
  }

  @override
  void dispose() {
    FlagStore.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.question.id;
    try {
      final flag = await FlagStore.get(id);
      if (mounted && id == widget.question.id) setState(() => _flag = flag);
    } catch (e) {
      debugPrint('Could not read the flag: $e');
    }
  }

  Future<void> _tap() async {
    final flag = _flag;
    if (flag == null) return showFlagSheet(context, widget.question);
    await _showFlagged(context, flag);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_flag == null) {
      return IconButton(
        onPressed: _tap,
        visualDensity: VisualDensity.compact,
        tooltip: 'Flag this question for review',
        icon: Icon(Icons.flag_outlined, color: scheme.onSurfaceVariant),
      );
    }
    return TextButton.icon(
      onPressed: _tap,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      icon: const Icon(Icons.flag_rounded, size: 18),
      label: const Text('Flagged for review'),
    );
  }
}

/// What a tap on an existing flag shows: it can be taken back until it
/// has been sent.
Future<void> _showFlagged(BuildContext context, QuestionFlag flag) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final reason = FlagStore.reasons
      .where((r) => r.$1 == flag.reason)
      .map((r) => r.$2)
      .firstWhere((_) => true, orElse: () => 'Flagged');
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) {
      final theme = Theme.of(sheet);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Flagged for review',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(flag.note.isEmpty ? reason : '$reason\n"${flag.note}"'),
              const SizedBox(height: 8),
              Text(
                !flag.canRemove
                    ? 'It has been sent to the reviewers. Thank you.'
                    : Account.instance.isSignedIn
                    ? 'It is sent the next time the app is online.'
                    : flagSignInNote,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              if (flag.canRemove)
                OutlinedButton.icon(
                  onPressed: () async {
                    Navigator.pop(sheet);
                    final removed = await FlagStore.remove(flag.questionId);
                    messenger?.showSnackBar(
                      SnackBar(
                        content: Text(
                          removed
                              ? 'Flag removed.'
                              : 'This flag was already sent.',
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.flag_outlined),
                  label: const Text('Remove flag'),
                )
              else
                TextButton(
                  onPressed: () => Navigator.pop(sheet),
                  child: const Text('Close'),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Opens the sheet that flags [question].
Future<void> showFlagSheet(BuildContext context, Question question) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final note = TextEditingController();
  String? reason;
  var sending = false;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, refresh) {
        final theme = Theme.of(sheet);
        final scheme = theme.colorScheme;
        final signedIn = Account.instance.isSignedIn;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              22,
              0,
              22,
              20 + MediaQuery.viewInsetsOf(sheet).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Flag this question for review',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    question.questionText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  for (final (code, label) in FlagStore.reasons)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(
                        reason == code
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: reason == code
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      title: Text(label, style: theme.textTheme.bodyLarge),
                      onTap: () => refresh(() => reason = code),
                    ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: note,
                    maxLength: FlagStore.maxNote,
                    minLines: 1,
                    maxLines: 3,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Note (optional)',
                    ),
                  ),
                  if (!signedIn)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
                      child: Text(
                        flagSignInNote,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 10),
                  PrimaryButton(
                    label: 'Send',
                    icon: Icons.flag_rounded,
                    onPressed: reason == null || sending
                        ? null
                        : () async {
                            refresh(() => sending = true);
                            try {
                              await FlagStore.save(
                                questionId: question.id,
                                questionText: question.questionText,
                                reason: reason!,
                                note: note.text,
                              );
                              messenger?.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    signedIn
                                        ? 'Thank you. The question was '
                                              'flagged for review.'
                                        : 'Flag saved. $flagSignInNote',
                                  ),
                                ),
                              );
                            } catch (e) {
                              messenger?.showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'The flag could not be saved. Try again.',
                                  ),
                                ),
                              );
                            }
                            if (sheet.mounted) Navigator.pop(sheet);
                          },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
