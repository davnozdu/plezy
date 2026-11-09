import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/gamescope_session.dart';

void main() {
  test('detects gamescope from the session environment', () {
    expect(isGamescopeSession({'XDG_CURRENT_DESKTOP': 'gamescope'}), isTrue);
    expect(isGamescopeSession({'GAMESCOPE_WAYLAND_DISPLAY': 'gamescope-0'}), isTrue);
    expect(isGamescopeSession({'SteamGamepadUI': '1'}), isTrue);
  });

  test('desktop sessions are not gamescope', () {
    expect(isGamescopeSession({'XDG_CURRENT_DESKTOP': 'KDE'}), isFalse);
    expect(isGamescopeSession({'GAMESCOPE_WAYLAND_DISPLAY': ''}), isFalse);
    expect(isGamescopeSession(const {}), isFalse);
  });
}
