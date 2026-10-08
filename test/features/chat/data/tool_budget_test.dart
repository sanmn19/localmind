import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/chat/data/tool_budget.dart';
import 'package:localmind/features/chat/data/tools/tool_event.dart';
import 'package:localmind/features/chat/data/tools/tool_definition.dart';

void main() {
  group('WebToolBudget', () {
    test('allows up to searchesPerTurn searches, denies the next one', () {
      final budget = WebToolBudget();
      const chain = 'chain-a';
      for (var i = 0; i < WebToolBudget.searchesPerTurn; i++) {
        expect(
          budget.allow(chain, isSearch: true),
          isTrue,
          reason: 'search ${i + 1}/${WebToolBudget.searchesPerTurn} must pass',
        );
        budget.record(chain, isSearch: true);
      }
      expect(
        budget.allow(chain, isSearch: true),
        isFalse,
        reason: 'search ${WebToolBudget.searchesPerTurn + 1} must be denied',
      );
    });

    test('allows up to fetchesPerTurn fetches, independently of searches', () {
      final budget = WebToolBudget();
      const chain = 'chain-a';
      for (var i = 0; i < WebToolBudget.fetchesPerTurn; i++) {
        expect(
          budget.allow(chain, isSearch: false),
          isTrue,
          reason: 'fetch ${i + 1}/${WebToolBudget.fetchesPerTurn} must pass',
        );
        budget.record(chain, isSearch: false);
      }
      expect(
        budget.allow(chain, isSearch: false),
        isFalse,
        reason: 'fetch ${WebToolBudget.fetchesPerTurn + 1} must be denied',
      );
      // The search budget is a distinct counter: recording 6 fetches must
      // not have carved into it, and a search must not consume fetches.
      expect(budget.allow(chain, isSearch: true), isTrue);
      budget.record(chain, isSearch: true);
      expect(budget.allow(chain, isSearch: false), isFalse);
    });

    test('allow() checks the limit without consuming budget', () {
      final budget = WebToolBudget();
      for (var i = 0; i < 10; i++) {
        expect(
          budget.allow('chain-a', isSearch: true),
          isTrue,
          reason: 'allow must never increment',
        );
      }
      budget.record('chain-a', isSearch: true);
      expect(budget.countsFor('chain-a').searches, 1);
    });

    test('record() consumes budget for failed executions too', () {
      // The caller records every executed call regardless of outcome.
      final budget = WebToolBudget();
      for (var i = 0; i < WebToolBudget.searchesPerTurn; i++) {
        budget.record('chain-a', isSearch: true);
      }
      expect(budget.allow('chain-a', isSearch: true), isFalse);
    });

    test('different chains hold separate budgets', () {
      final budget = WebToolBudget();
      for (var i = 0; i < WebToolBudget.searchesPerTurn; i++) {
        budget.record('chain-a', isSearch: true);
      }
      expect(budget.allow('chain-a', isSearch: true), isFalse);
      expect(budget.allow('chain-b', isSearch: true), isTrue);
      expect(budget.countsFor('chain-b'), (searches: 0, fetches: 0));
    });

    test('reset() starts a chain over', () {
      final budget = WebToolBudget();
      for (var i = 0; i < WebToolBudget.searchesPerTurn; i++) {
        budget.record('chain-a', isSearch: true);
      }
      budget.record('chain-a', isSearch: false);
      budget.nextSkipSequence('chain-a');
      budget.reset('chain-a');
      expect(budget.allow('chain-a', isSearch: true), isTrue);
      expect(budget.allow('chain-a', isSearch: false), isTrue);
      expect(budget.countsFor('chain-a'), (searches: 0, fetches: 0));
      expect(budget.nextSkipSequence('chain-a'), 1);
    });

    test('skip sequence is unique per chain and resets with the chain', () {
      final budget = WebToolBudget();
      expect(budget.nextSkipSequence('c1'), 1);
      expect(budget.nextSkipSequence('c1'), 2);
      expect(budget.nextSkipSequence('c2'), 1);
      budget.reset('c1');
      expect(budget.nextSkipSequence('c1'), 1);
    });

    test('prunes beyond the tracked-chain cap, oldest first', () {
      final budget = WebToolBudget();
      budget.record('oldest', isSearch: true);
      for (var i = 0; i < WebToolBudget.maxTrackedChains; i++) {
        budget.record('key-$i', isSearch: false);
      }
      // 'oldest' is now the 65th key and must have been evicted: it behaves
      // like a fresh chain again.
      expect(budget.allow('oldest', isSearch: true), isTrue);
      // The newest chain keeps its recorded fetch.
      expect(
        budget.countsFor('key-${WebToolBudget.maxTrackedChains - 1}').fetches,
        1,
      );
    });

    test('recently used chains survive pruning (LRU)', () {
      final budget = WebToolBudget();
      budget.record('recent', isSearch: true);
      for (var i = 0; i < WebToolBudget.maxTrackedChains - 1; i++) {
        budget.record('key-$i', isSearch: false);
      }
      // Touching 'recent' moves it to the recency end.
      expect(budget.allow('recent', isSearch: true), isTrue);
      // One more insert evicts the oldest key, not the touched one.
      budget.record('brand-new', isSearch: false);
      expect(budget.countsFor('recent').searches, 1);
      expect(budget.countsFor('key-0').fetches, 0);
    });
  });

  group('web budget failure feedback', () {
    test('failure message carries the exact used/limit copy', () {
      expect(
        webBudgetExhaustedMessage(searches: 3, fetches: 0),
        'web budget exhausted for this reply (searches 3/3, fetches 0/6). '
        'Answer with the results already fetched.',
      );
      expect(
        webBudgetExhaustedMessage(searches: 0, fetches: 6),
        'web budget exhausted for this reply (searches 0/3, fetches 6/6). '
        'Answer with the results already fetched.',
      );
    });

    test('skip-failure events are recognized by the shared prefix', () {
      ToolEvent event({required ToolEventStatus status, String? error}) =>
          ToolEvent(
            eventId: 'x',
            timestamp: DateTime.utc(2026, 10, 7),
            status: status,
            toolName: 'web.search',
            providerType: ToolProviderType.mcp,
            error: error,
          );

      final exhausted = webBudgetExhaustedMessage(searches: 3, fetches: 0);
      expect(
        isWebBudgetSkipFailure(
          event(status: ToolEventStatus.failed, error: exhausted),
        ),
        isTrue,
      );
      // Anything else (loop failures, rejections, non-failed statuses) must
      // NOT be treated as a budget skip.
      expect(
        isWebBudgetSkipFailure(event(status: ToolEventStatus.completed)),
        isFalse,
      );
      expect(
        isWebBudgetSkipFailure(
          event(status: ToolEventStatus.failed, error: 'Permission denied'),
        ),
        isFalse,
      );
      expect(
        isWebBudgetSkipFailure(event(status: ToolEventStatus.failed)),
        isFalse,
      );
    });
  });
}
