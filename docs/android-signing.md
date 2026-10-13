# Android release signing

Release APKs use a permanent RSA-4096 key in a password-protected PKCS#12
keystore. The alias is `ligament-release`.

The local keystore is stored outside the repository at
`~/Library/Application Support/Ligament/Signing/Android/ligament-release.p12`
with file permissions `0600`. Its credentials are stored in macOS Keychain:
service `com.ligament.android.release`, account `ligament-release`.

GitHub Actions receives one repository secret,
`ANDROID_SIGNING_PROPERTIES_BASE64`. Its value is a base64-encoded Gradle
properties file containing `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`.
The workflow writes it to the runner's private Gradle properties file and
removes signing files after the build. Signing values are not exported as
environment variables or committed to Git.

Preserve an encrypted backup of the keystore and its credentials: future APK
updates must use this same key. An APK signed by a different key cannot update
an existing installation in place. Previously debug-signed installations may
require reinstallation when switching to this release key.
