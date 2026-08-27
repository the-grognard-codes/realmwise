import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingPropertiesFile = rootProject.file("key.properties")
val signingProperties = Properties()
val hasSigningProperties = signingPropertiesFile.isFile
if (hasSigningProperties) {
    signingPropertiesFile.inputStream().use(signingProperties::load)
}

fun signingProperty(name: String): String? = signingProperties.getProperty(name)?.takeIf { it.isNotBlank() }

gradle.taskGraph.whenReady {
    val releaseTaskRequested = allTasks.any { task ->
        task.name.contains("release", ignoreCase = true) || task.name.startsWith("bundle", ignoreCase = true)
    }
    if (releaseTaskRequested) {
        if (!hasSigningProperties) {
            throw GradleException("Missing ${signingPropertiesFile.path}; release builds require signing credentials.")
        }
        val missingProperty = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            .firstOrNull { signingProperty(it) == null }
        if (missingProperty != null) {
            throw GradleException("Missing or blank '$missingProperty' in ${signingPropertiesFile.path}; release builds require all signing credentials.")
        }
        val configuredStoreFile = file(signingProperty("storeFile")!!)
        if (!configuredStoreFile.isFile) {
            throw GradleException("Signing keystore not found: ${configuredStoreFile.path}; check 'storeFile' in ${signingPropertiesFile.path}.")
        }
    }
}

android {
    namespace = "com.realmwise.rpg.tracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.realmwise.rpg.tracker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            signingProperty("storeFile")?.let { storeFile = file(it) }
            storePassword = signingProperty("storePassword")
            keyAlias = signingProperty("keyAlias")
            keyPassword = signingProperty("keyPassword")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        debug {
            // Android Google authorization uses package/signing identity; this
            // is only a stable token-store namespace, not an OAuth client ID.
            buildConfigField("String", "GOOGLE_DRIVE_CLIENT_ID", "\"android-debug\"")
            buildConfigField("String", "MICROSOFT_ONEDRIVE_CLIENT_ID", "\"f689c4d7-5fc4-4a50-aee5-da175b97e113\"")
            buildConfigField("String", "MICROSOFT_ONEDRIVE_TENANT", "\"consumers\"")
            buildConfigField("String", "MICROSOFT_ONEDRIVE_REDIRECT_URI", "\"msauth://com.realmwise.rpg.tracker/lQr%2BytyRuU%2BDmVt6MLoUjjTG9wo%3D\"")
            buildConfigField("String", "DROPBOX_CLIENT_ID", "\"qiiuadba0azgtr7\"")
            manifestPlaceholders["oneDriveRedirectPath"] = "/lQr+ytyRuU+DmVt6MLoUjjTG9wo="
        }
        release {
            signingConfig = signingConfigs.getByName("release")
            // Android Google authorization uses package/signing identity; this
            // is only a stable token-store namespace, not an OAuth client ID.
            buildConfigField("String", "GOOGLE_DRIVE_CLIENT_ID", "\"android-release\"")
            buildConfigField("String", "MICROSOFT_ONEDRIVE_CLIENT_ID", "\"1b24f572-c129-4e3c-9afa-d51781afe96c\"")
            buildConfigField("String", "MICROSOFT_ONEDRIVE_TENANT", "\"consumers\"")
            buildConfigField("String", "MICROSOFT_ONEDRIVE_REDIRECT_URI", "\"msauth://com.realmwise.rpg.tracker/hu33S0PdJMD%2FBlOPVgFheEvptH8%3D\"")
            buildConfigField("String", "DROPBOX_CLIENT_ID", "\"pujnhj60xv194u6\"")
            manifestPlaceholders["oneDriveRedirectPath"] = "/hu33S0PdJMD/BlOPVgFheEvptH8="
        }
    }
}

dependencies {
    // Google Identity Services for Android AuthorizationClient.
    implementation("com.google.android.gms:play-services-auth:21.6.0")
}

flutter {
    source = "../.."
}
