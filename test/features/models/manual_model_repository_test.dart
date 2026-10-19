import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/features/models/data/manual_model_repository.dart';
import 'package:localmind/features/models/data/manual_model_store.dart';
import 'package:localmind/features/models/data/models/manual_model.dart';

ManualModel _model(String serverId, String modelId, [String? displayName]) =>
    ManualModel(
      serverId: serverId,
      modelId: modelId,
      displayName: displayName,
      createdAt: DateTime(2026, 10, 19),
    );

void main() {
  test('add persists once; duplicate (serverId, modelId) is rejected', () {
    final repo = ManualModelRepository(InMemoryManualModelStore());

    expect(repo.add(_model('s1', 'm1')), isTrue);
    expect(repo.add(_model('s1', 'm1')), isFalse);
    expect(repo.listForServer('s1'), hasLength(1));
  });

  test('remove and removeAllForServer scope by server', () {
    final repo = ManualModelRepository(InMemoryManualModelStore())
      ..add(_model('s1', 'm1'))
      ..add(_model('s1', 'm2'))
      ..add(_model('s2', 'm1'));

    expect(repo.remove('s1', 'm1'), isTrue);
    expect(repo.listForServer('s1').map((m) => m.modelId), ['m2']);

    repo.removeAllForServer('s1');
    expect(repo.listForServer('s1'), isEmpty);
    expect(repo.listForServer('s2'), hasLength(1));
  });

  test('ids are trimmed; a blank id is rejected', () {
    final repo = ManualModelRepository(InMemoryManualModelStore());

    expect(repo.add(_model('s1', '  m1 ')), isTrue);
    expect(repo.listForServer('s1').single.modelId, 'm1');
    expect(repo.add(_model('s1', '   ')), isFalse);
  });

  test('model ids are case-sensitive: m1 and M1 are distinct', () {
    final repo = ManualModelRepository(InMemoryManualModelStore());

    expect(repo.add(_model('s1', 'm1')), isTrue);
    expect(repo.add(_model('s1', 'M1')), isTrue);
    expect(repo.listForServer('s1'), hasLength(2));
  });

  test('display names are trimmed and blank ones become null', () {
    final repo = ManualModelRepository(InMemoryManualModelStore())
      ..add(_model('s1', 'm1', '  My Model  '))
      ..add(_model('s1', 'm2', '   '));

    final rows = repo.listForServer('s1');
    expect(rows.firstWhere((m) => m.modelId == 'm1').displayName, 'My Model');
    expect(rows.firstWhere((m) => m.modelId == 'm2').displayName, isNull);
  });
}
