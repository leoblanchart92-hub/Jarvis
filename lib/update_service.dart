import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdate {
  final String currentVersion, latestVersion, releaseNotes;
  final Uri apkUrl;
  final String expectedSha256;
  const AppUpdate({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    required this.apkUrl,
    required this.expectedSha256,
  });

  bool get isAvailable => _compareVersions(latestVersion, currentVersion) > 0;

  static const String _releaseApi =
      'https://api.github.com/repos/leoblanchart92-hub/Jarvis/releases/latest';

  static Future<AppUpdate?> check() async {
    final client = http.Client();
    try {
      final response = await client.get(Uri.parse(_releaseApi), headers: {
        'Accept': 'application/vnd.github+json',
        'Cache-Control': 'no-cache',
        'User-Agent': 'ASTRA-Android-Updater',
      }).timeout(const Duration(seconds: 25));
      if (response.statusCode == 404) return null;
      if (response.statusCode != 200) {
        throw Exception('GitHub répond avec HTTP ${response.statusCode}.');
      }

      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final package = await PackageInfo.fromPlatform();
      final tag = data['tag_name'] as String? ?? '';
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      final assets = data['assets'] as List<dynamic>? ?? const [];
      Map<String, dynamic>? asset;
      for (final item in assets) {
        if (item is Map<String, dynamic> && item['name'] == 'ASTRA.apk') {
          asset = item;
          break;
        }
      }
      final url = Uri.tryParse(asset?['browser_download_url'] as String? ?? '');
      final digest = (asset?['digest'] as String? ?? '').toLowerCase();
      final hash = digest.startsWith('sha256:') ? digest.substring(7) : '';
      if (!_validVersion(version) || url == null || url.scheme != 'https' ||
          url.host != 'github.com' || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw Exception('La release GitHub est invalide ou ne contient pas ASTRA.apk et son SHA-256.');
      }

      return AppUpdate(
        currentVersion: package.version,
        latestVersion: version,
        releaseNotes: data['body'] as String? ?? 'Mise à jour ASTRA.',
        apkUrl: url,
        expectedSha256: hash,
      );
    } on SocketException {
      throw Exception('Connexion Internet indisponible. Vérifie ton réseau puis réessaie.');
    } on http.ClientException {
      throw Exception('Impossible de joindre GitHub. Réessaie plus tard.');
    } on FormatException {
      throw Exception('La réponse de GitHub est illisible.');
    } finally {
      client.close();
    }
  }

  // Stream APK to disk and hash each chunk to avoid holding the large APK in RAM.
  Future<void> downloadAndInstall(void Function(double) onProgress) async {
    final client = http.Client();
    File? file;
    IOSink? fileSink;
    DigestSink? digestSink;
    ByteConversionSink? hashSink;
    try {
      final request = http.Request('GET', apkUrl)
        ..headers['Accept'] = 'application/octet-stream'
        ..headers['User-Agent'] = 'ASTRA-Android-Updater';
      final response = await client.send(request).timeout(const Duration(seconds: 90));
      if (response.statusCode != 200) {
        throw Exception('Téléchargement impossible (HTTP ${response.statusCode}).');
      }

      final dir = await getTemporaryDirectory();
      file = File('${dir.path}/ASTRA-$latestVersion.apk');
      if (await file.exists()) await file.delete();
      fileSink = file.openWrite();
      digestSink = DigestSink();
      hashSink = sha256.startChunkedConversion(digestSink);
      var received = 0;
      final total = response.contentLength ?? 0;
      await for (final chunk in response.stream.timeout(const Duration(seconds: 45))) {
        fileSink.add(chunk);
        hashSink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress((received / total).clamp(0.0, 1.0).toDouble());
      }
      hashSink.close();
      await fileSink.flush();
      await fileSink.close();
      fileSink = null;
      hashSink = null;

      final fileSize = await file.length();
      if (fileSize < 100 * 1024 || (total > 0 && fileSize != total)) {
        throw Exception('Le fichier APK semble incomplet.');
      }
      final actualHash = digestSink.value.toString();
      if (actualHash != expectedSha256) {
        throw Exception('Vérification SHA-256 échouée : APK rejeté.');
      }

      final result = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
      if (result.type != ResultType.done) {
        throw Exception(result.message.isEmpty ? 'Android n’a pas pu ouvrir l’installateur.' : result.message);
      }
    } on SocketException {
      throw Exception('Connexion interrompue pendant le téléchargement.');
    } finally {
      if (fileSink != null) await fileSink.close();
      client.close();
    }
  }

  static bool _validVersion(String v) {
    final parts = v.split('.');
    return parts.length == 3 && parts.every((part) => part.isNotEmpty && int.tryParse(part) != null);
  }

  static int _compareVersions(String a, String b) {
    final left = a.split('.').map((v) => int.tryParse(v) ?? 0).toList();
    final right = b.split('.').map((v) => int.tryParse(v) ?? 0).toList();
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final x = i < left.length ? left[i] : 0;
      final y = i < right.length ? right[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }
}
