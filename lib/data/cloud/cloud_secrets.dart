import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 仅连接凭据和恢复密钥进入安全存储；普通书架快照及同步文件不包含这些秘密。
class CloudSecrets {
  static const _storage = FlutterSecureStorage(
    // 测试 DMG 使用 ad-hoc 签名，无共享钥匙串需求；传统 Keychain 不要求开发者描述文件。
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  Future<String?> read() => _storage.read(key: 'reader.nutstore.connection.v1');
  Future<void> write(String value) async {
    await _storage.write(key: 'reader.nutstore.connection.v1', value: value);
    if (await read() != value) throw const FormatException('设备安全存储写入失败，未保存连接');
  }

  Future<void> delete() =>
      _storage.delete(key: 'reader.nutstore.connection.v1');
}
