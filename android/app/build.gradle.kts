import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// VULN-28: release-подпись Android (раньше release ВСЕГДА подписывался
// debug-ключом). Секреты передаются из CI переменными окружения или
// Gradle-свойствами (-Pname=value). Требуются ВСЕ 4 значения:
//   ANDROID_KEYSTORE_PASSWORD — пароль хранилища ключей
//   ANDROID_KEY_ALIAS         — алиас ключа
//   ANDROID_KEY_PASSWORD      — пароль ключа
// и сам keystore одним из способов:
//   ANDROID_KEYSTORE_BASE64   — содержимое keystore (jks) в base64, ИЛИ
//   ANDROID_KEYSTORE_FILE     — путь к файлу keystore на диске
// Когда секреты появятся в .github/workflows/build_clients.yml, этот
// скрипт подхватит их из env без правок здесь (env → providers
// .environmentVariable ниже). См. fallback-логику в buildTypes.release
// (A-4): без секретов release-сборка ПАДАЕТ, debug-подпись — только через
// явный люк LIGAMENT_ALLOW_DEBUG_SIGNING=1.
class ReleaseSigningInfo(
    val storeFile: File,
    val storePassword: String,
    val keyAlias: String,
    val keyPassword: String,
)

fun signingSecret(name: String): String? =
    providers.gradleProperty(name)
        .orElse(providers.environmentVariable(name))
        .orNull
        ?.takeIf { it.isNotBlank() }

val releaseStorePassword = signingSecret("ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingSecret("ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingSecret("ANDROID_KEY_PASSWORD")

val releaseKeystoreFile: File? = run {
    if (releaseStorePassword == null || releaseKeyAlias == null || releaseKeyPassword == null) {
        return@run null
    }
    val base64 = signingSecret("ANDROID_KEYSTORE_BASE64")
    if (base64 != null) {
        try {
            val target = File(
                layout.buildDirectory.get().asFile,
                "tmp_signing/release_from_env.keystore",
            )
            target.parentFile?.mkdirs()
            target.writeBytes(Base64.getDecoder().decode(base64))
            target
        } catch (e: IllegalArgumentException) {
            logger.warn("release-signing: ANDROID_KEYSTORE_BASE64 не декодировался (${e.message}); используется debug-подпись")
            null
        }
    } else {
        signingSecret("ANDROID_KEYSTORE_FILE")?.let(::File)?.takeIf { it.isFile }
    }
}

val releaseSigning: ReleaseSigningInfo? =
    if (releaseKeystoreFile != null && releaseStorePassword != null &&
        releaseKeyAlias != null && releaseKeyPassword != null
    ) {
        ReleaseSigningInfo(releaseKeystoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
    } else {
        null
    }

android {
    namespace = "com.ligament.twofa.authenticator"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.ligament.twofa.authenticator"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    releaseSigning?.let { signing ->
        signingConfigs {
            create("release") {
                storeFile = signing.storeFile
                storePassword = signing.storePassword
                keyAlias = signing.keyAlias
                keyPassword = signing.keyPassword
            }
        }
    }

    buildTypes {
        release {
            // A-4 (аудит 2026-10-12): фолбэк на общеизвестный debug-ключ
            // убран — release-APK, подписанный им, подделывается при
            // sideload-«обновлении». Без секретов подписи release-сборка
            // падает с GradleException. Явный люк для локальной отладки:
            //   LIGAMENT_ALLOW_DEBUG_SIGNING=1
            // (переменная окружения или -PLIGAMENT_ALLOW_DEBUG_SIGNING=1 /
            // строка в ~/.gradle/gradle.properties) — подписывает debug-
            // ключом осознанно, НЕ для публикации.
            val debugSigningExplicitlyAllowed =
                signingSecret("LIGAMENT_ALLOW_DEBUG_SIGNING") == "1"
            signingConfig = if (releaseSigning != null) {
                signingConfigs.getByName("release")
            } else if (debugSigningExplicitlyAllowed) {
                logger.warn(
                    "release-signing: секреты подписи не заданы, LIGAMENT_ALLOW_DEBUG_SIGNING=1 — " +
                        "release подписывается DEBUG-ключом (только для локальной отладки!)",
                )
                signingConfigs.getByName("debug")
            } else {
                throw GradleException(
                    "Отказ сборки release: секреты подписи Android не заданы, а debug-подпись не разрешена явно.\n" +
                        "Release-APK не может подписываться общеизвестным debug-ключом (подделка «обновления» при sideload, аудит A-4).\n" +
                        "Как настроить секреты: передайте ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD\n" +
                        "и ANDROID_KEYSTORE_BASE64 (keystore в base64) или ANDROID_KEYSTORE_FILE (путь к файлу) —\n" +
                        "переменными окружения или Gradle-свойствами (-Pname=value); полный список — в шапке android/app/build.gradle.kts.\n" +
                        "Для локальной сборки с debug-подписью (НЕ для публикации!) явно разрешите её:\n" +
                        "  export LIGAMENT_ALLOW_DEBUG_SIGNING=1   # или: ~/.gradle/gradle.properties → LIGAMENT_ALLOW_DEBUG_SIGNING=1",
                )
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
