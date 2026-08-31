buildscript {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }

    dependencies {
        // Override AGP 9.0.1's bundled KGP 2.2.10 to meet Flutter's minimum.
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// file_picker 11 skips applying Kotlin when it detects AGP 9, even though
// its Android implementation is written in Kotlin. Apply the Kotlin Android
// plugin here so its classes are included in the plugin AAR and Flutter's
// generated registrant can register it normally.
subprojects {
    if (project.name == "file_picker") {
        pluginManager.apply("org.jetbrains.kotlin.android")
        plugins.withId("org.jetbrains.kotlin.android") {
            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
        }
    }
}

// Ensure all Android library/application subprojects compile against API 37.
// This helps avoid AAR metadata mismatches from plugins compiled with older SDKs.
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension>("android") {
            compileSdk = 37
        }
    }
    plugins.withId("com.android.application") {
        extensions.configure<com.android.build.api.dsl.ApplicationExtension>("android") {
            try {
                // AppExtension uses setCompileSdkVersion API
                this.javaClass.getMethod("setCompileSdkVersion", Int::class.java).invoke(this, 37)
            } catch (_: Exception) {
                // ignore; best-effort
            }
        }
    }
}

// Keep the app and mobile_scanner on JVM 17.
subprojects {
    if (project.name == "app") {
        plugins.withId("org.jetbrains.kotlin.jvm") {
            tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
        }
        plugins.withId("org.jetbrains.kotlin.android") {
            tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
        }
    }
    if (project.name == "mobile_scanner") {
        plugins.withId("org.jetbrains.kotlin.jvm") {
            tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
        }
        plugins.withId("org.jetbrains.kotlin.android") {
            tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// Ensure plugin modules (like file_picker) are assembled before the app's Java
// compilation so their classes are available to the Java compiler.
// No special compile ordering; rely on standard Gradle lifecycle and built-in Kotlin.
