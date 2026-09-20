import 'package:shared_preferences/shared_preferences.dart';

/// Persisted connection details, so pairing survives an app restart.
///
/// Deliberately the only thing this app stores. There is no local database and no cached library:
/// the desktop is the source of truth for everything except "which server, and am I allowed in".
class Store {
  static const _kUrl = 'base_url';
  static const _kToken = 'token';

  static Future<({String? url, String? token})> load() async {
    final p = await SharedPreferences.getInstance();
    return (url: p.getString(_kUrl), token: p.getString(_kToken));
  }

  static Future<void> save(String url, String token) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kUrl, url);
    await p.setString(_kToken, token);
  }

  /// Forget the pairing. Called on an explicit disconnect and when the desktop rejects the token
  /// (it was revoked there), so the app does not sit on a credential that cannot work.
  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kUrl);
    await p.remove(_kToken);
  }
}
