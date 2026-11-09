import 'dart:io';

/// Whether Plezy runs inside a gamescope session (Steam Deck / ROG Ally Game
/// Mode on SteamOS, Bazzite and similar), where the window is the whole screen
/// and there is no window manager to resize or fullscreen it by hand.
bool isGamescopeSession([Map<String, String>? environment]) {
  if (!Platform.isLinux && environment == null) return false;
  final env = environment ?? Platform.environment;
  if (env['XDG_CURRENT_DESKTOP']?.toLowerCase() == 'gamescope') return true;
  if ((env['GAMESCOPE_WAYLAND_DISPLAY'] ?? '').isNotEmpty) return true;
  return env['SteamGamepadUI'] == '1';
}
