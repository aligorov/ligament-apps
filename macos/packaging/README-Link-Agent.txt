Ligament Link host agent for macOS
==================================

The host agent runs only in the logged-in user's LaunchAgent session. It uses
the macOS Keychain for its device identity and needs macOS Screen Recording
permission before interactive screen sharing can work.

To install or update Ligament Authenticator:
  1. Drag Ligament 2FA.app into /Applications.
  2. Double-click Install-Link-Agent.command from this disk image.
  3. Approve the Terminal prompt if macOS asks.

To remove the per-user background agent, double-click
Remove-Link-Agent.command. Removing the app does not automatically revoke the
agent identity on the server; revoke the host in the Ligament admin console.

This package does not grant Screen Recording permission automatically. Grant
it in System Settings > Privacy & Security > Screen & System Audio Recording,
then restart the host agent. Exact wording can differ by macOS release.
