import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/services/notification_tap_router.dart';

void main() {
  test('routes tool-approval payloads to the approval handler', () {
    var background = 0;
    var approval = 0;
    NotificationTapRouter.onBackgroundTap = (_) => background++;
    NotificationTapRouter.onToolApprovalTap = (_) => approval++;

    NotificationTapRouter.handle(
      const NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        payload: 'tool-approval|a1|c1',
        actionId: 'approve',
      ),
    );
    expect(approval, 1);
    expect(background, 0);

    NotificationTapRouter.handle(
      const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: 'bg-task-result|c1',
      ),
    );
    expect(approval, 1);
    expect(background, 1);
  });
}
