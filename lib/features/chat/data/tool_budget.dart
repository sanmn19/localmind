import 'models/message.dart';
import 'tools/tool_event.dart';

/// Start of the error text every over-drawn web tool call receives. The
/// prefix doubles as the marker that routes such failures back to the model
/// ([isWebBudgetSkipFailure]) so it can wrap the turn up instead of loop-
/// hammering an exhausted keyless vendor ring.
const webBudgetSkipErrorPrefix = 'web budget exhausted for this reply';

/// Formats the budget failure the model reads for an over-drawn call.
/// [searches] / [fetches] are the counts ALREADY consumed for the chain.
String webBudgetExhaustedMessage({
  required int searches,
  required int fetches,
}) =>
    '$webBudgetSkipErrorPrefix (searches $searches/${WebToolBudget.searchesPerTurn}, '
    'fetches $fetches/${WebToolBudget.fetchesPerTurn}). '
    'Answer with the results already fetched.';

/// True for the synthetic failed [ToolEvent]s the notifier mints when a
/// chain budget denied a web tool call. These failures — and ONLY these —
/// feed back to the model like completed results do.
bool isWebBudgetSkipFailure(ToolEvent event) =>
    event.status == ToolEventStatus.failed &&
    (event.error?.startsWith(webBudgetSkipErrorPrefix) ?? false);

/// Per-turn web-tool budgets. Keyed by the tool chain's variant group id.
/// A budget is one turn: consecutive tool rounds of the SAME assistant
/// reply share it. Counts reset when the group id changes; prune entries
/// beyond [maxTrackedChains] keys oldest-first (LRU-style recency).
///
/// [allow] checks the limits and does NOT increment; [record] increments
/// after an EXECUTION — successful or failed, an executed call consumes
/// budget. [reset] is used at chain start so every chain begins whole.
///
/// Legacy message rows without a variant group fall back to the message id
/// ([chainKeyFor]), making the budget per-message there.
class WebToolBudget {
  static const searchesPerTurn = 3; // web.search per reply
  static const fetchesPerTurn = 6; // web.fetch per reply
  static const maxTrackedChains = 64;

  final Map<String, int> _searches = {};
  final Map<String, int> _fetches = {};
  final Map<String, int> _skipSequences = {};

  /// Global recency order (oldest first) unifying the count maps for the
  /// prune step.
  final List<String> _recency = [];

  bool allow(String chainKey, {required bool isSearch}) {
    _touch(chainKey);
    final map = isSearch ? _searches : _fetches;
    return (map[chainKey] ?? 0) < (isSearch ? searchesPerTurn : fetchesPerTurn);
  }

  void record(String chainKey, {required bool isSearch}) {
    final map = isSearch ? _searches : _fetches;
    map[chainKey] = (map[chainKey] ?? 0) + 1;
    _touch(chainKey);
  }

  void reset(String chainKey) {
    _searches.remove(chainKey);
    _fetches.remove(chainKey);
    _skipSequences.remove(chainKey);
    _recency.remove(chainKey);
  }

  /// Counts already consumed by [chainKey] — used to render the budget
  /// copy in the skip failure event.
  ({int searches, int fetches}) countsFor(String chainKey) =>
      (searches: _searches[chainKey] ?? 0, fetches: _fetches[chainKey] ?? 0);

  /// Monotonic skip-failure sequence for [chainKey], so synthesized
  /// failure event ids stay unique across the rounds of one chain.
  int nextSkipSequence(String chainKey) {
    final next = (_skipSequences[chainKey] ?? 0) + 1;
    _skipSequences[chainKey] = next;
    _touch(chainKey);
    return next;
  }

  /// The chain token: consecutive tool rounds of one assistant reply share
  /// the reply's variantGroupId (each continuation round inherits it), so
  /// the group id is the budget key. Rows minted before the variant system
  /// (or synthetic rows) have no group — they key per message id instead.
  static String chainKeyFor(Message message) =>
      message.variantGroupId ?? message.id;

  /// Marks [chainKey] as recently used, then evicts beyond the cap
  /// oldest-first. In-flight chains count as in use, so they survive.
  void _touch(String chainKey) {
    _recency
      ..remove(chainKey)
      ..add(chainKey);
    while (_recency.length > maxTrackedChains) {
      final evicted = _recency.removeAt(0);
      _searches.remove(evicted);
      _fetches.remove(evicted);
      _skipSequences.remove(evicted);
    }
  }
}
