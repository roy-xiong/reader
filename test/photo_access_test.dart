import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformService.channel, null),
  );
  test('照片通道兼容旧列表及新结果，部分失败不丢成功项，下次取消会清除旧警告', () async {
    Object result = ['old.jpg'];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          PlatformService.channel,
          (call) async => result,
        );
    final platform = PlatformService();
    expect(await platform.pickImages(), ['old.jpg']);
    expect(platform.imageImportWarning, isNull);
    result = {
      'paths': ['a.jpg', 'b.jpg'],
      'failed': 2,
    };
    expect(await platform.pickImages(), ['a.jpg', 'b.jpg']);
    expect(platform.imageImportWarning, contains('2 张照片读取失败'));
    result = {'paths': [], 'failed': 0};
    expect(await platform.pickImages(), isEmpty);
    expect(platform.imageImportWarning, isNull);
  });
  test('系统选图不强制请求相册完整权限，授权管理由单独入口发起', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformService.channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'photoAccess' => 'limited',
            'pickImages' => ['allowed.jpg'],
            _ => null,
          };
        });
    final platform = PlatformService();
    expect(await platform.photoAccess(), 'limited');
    expect(await platform.pickImages(), ['allowed.jpg']);
    expect(calls, ['photoAccess', 'pickImages']);
    await platform.managePhotoAccess();
    expect(calls.last, 'managePhotoAccess');
  });
}
