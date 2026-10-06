import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/providers/tooling_providers.dart';

/// Always-mounted host that keeps the in-process web MCP server in step
/// with the web tools setting.
///
/// [webServerRegistrationProvider] is side-effect-only and only runs while
/// watched. Mounting this host next to the other root hosts guarantees the
/// provider is watched from the first shell frame, so the `local://web`
/// server registers right after a process restart instead of waiting for
/// the MCP tools screen to be opened.
class WebServerRegistrationHost extends ConsumerWidget {
  const WebServerRegistrationHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(webServerRegistrationProvider);
    return child;
  }
}
