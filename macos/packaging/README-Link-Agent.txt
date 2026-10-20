Ligament Link host agent for macOS
=================================

The DMG installs the app by dragging Ligament 2FA.app into Applications. When
the user chooses “Add computer” in Ligament Link, the app writes a per-user
LaunchAgent plist with restrictive permissions and registers it with launchctl.
No standalone .command script or administrator privileges are required.

The LaunchAgent runs as the logged-in user, stores the host identity in the
macOS Keychain, and starts at login. The app bundle includes the interactive
Flutter worker executable used for remote sessions. The agent can be removed by
unloading com.ligament.link-agent and deleting
~/Library/LaunchAgents/com.ligament.link-agent.plist.
