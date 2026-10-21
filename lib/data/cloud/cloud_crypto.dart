import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// AES-256-GCM 加密容器。每条元数据／文件块随机 nonce，并绑定库及对象路径。
/// 密码推导不使用四位 PIN；恢复码为 256 位随机密钥，不通过网盘传递。
class CloudCrypto {
  CloudCrypto(this.key);
  final Uint8List key;
  static Uint8List random(int count) => Uint8List.fromList(
    List.generate(count, (_) => Random.secure().nextInt(256)),
  );
  static String newRecoveryCode() =>
      base64UrlEncode(random(32)).replaceAll('=', '');
  static Uint8List parseRecoveryCode(String text) {
    try {
      final key = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(text.trim())),
      );
      if (key.length != 32) throw const FormatException();
      return key;
    } catch (_) {
      throw const FormatException('恢复码应为 43 位，请从首次建库的设备复制');
    }
  }

  Future<Uint8List> encrypt(List<int> data, String binding) {
    final secret = key;
    return Isolate.run(() async {
      final box = await AesGcm.with256bits().encrypt(
        data,
        secretKey: SecretKey(secret),
        nonce: random(12),
        aad: utf8.encode(binding),
      );
      return Uint8List.fromList([
        1,
        ...box.nonce,
        ...box.mac.bytes,
        ...box.cipherText,
      ]);
    });
  }

  Future<Uint8List> decrypt(List<int> data, String binding) {
    final secret = key;
    return Isolate.run(() async {
      if (data.length < 29 || data[0] != 1) {
        throw const FormatException('加密文件格式无效');
      }
      try {
        final plain = await AesGcm.with256bits().decrypt(
          SecretBox(
            data.sublist(29),
            nonce: data.sublist(1, 13),
            mac: Mac(data.sublist(13, 29)),
          ),
          secretKey: SecretKey(secret),
          aad: utf8.encode(binding),
        );
        return Uint8List.fromList(plain);
      } on SecretBoxAuthenticationError {
        throw const FormatException('恢复码不匹配，或云端文件校验失败');
      }
    });
  }

  Future<Uint8List> encode(Map<String, dynamic> value, String binding) =>
      encrypt(utf8.encode(jsonEncode(value)), binding);
  Future<Map<String, dynamic>> decode(List<int> value, String binding) async =>
      Map<String, dynamic>.from(
        jsonDecode(utf8.decode(await decrypt(value, binding))) as Map,
      );
}
