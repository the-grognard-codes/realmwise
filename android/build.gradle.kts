buildscript {
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

// Ensure all Android library/application subprojects compile against API 36
// This helps avoid AAR metadata mismatches from plugins compiled with older SDKs.
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension>("android") {
            compileSdk = 36
        }
    }
    plugins.withId("com.android.application") {
        extensions.configure<com.android.build.api.dsl.ApplicationExtension>("android") {
            try {
                // AppExtension uses setCompileSdkVersion API
                this.javaClass.getMethod("setCompileSdkVersion", Int::class.java).invoke(this, 36)
            } catch (_: Exception) {
                // ignore; best-effort
            }
        }
    }
}

// Ensure Kotlin and Java JVM targets match to avoid compile errors.
// Use the modern compilerOptions DSL to set the Kotlin JVM target to 17.
subprojects {
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// Ensure plugin modules (like file_picker) are assembled before the app's Java
// compilation so their classes are available to the Java compiler.
// No special compile ordering; rely on standard Gradle lifecycle and built-in Kotlin.
