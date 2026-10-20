Ligament Link host agent for macOS — packaging status
====================================================

The DMG currently supports installing the main application by dragging
Ligament 2FA.app into Applications. It does not install or register the Link
host agent. The former standalone .command flow is intentionally not shipped:
macOS Gatekeeper blocks those unsigned scripts, and a native signed/notarized
agent registration flow has not yet been implemented.

The Link host agent requires the logged-in user's LaunchAgent session, Keychain
access, and Screen Recording permission. Do not distribute the agent as usable
until its native installation, signing, notarization, launch, and removal flows
are implemented and tested on macOS.
