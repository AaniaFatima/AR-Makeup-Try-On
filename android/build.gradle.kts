buildscript {
    val kotlin_version = "2.1.0"
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.7.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.0")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        flatDir {
            dirs(File(rootProject.projectDir, "app/libs"))
        }
    }
}

// Custom build directory wala block delete kar diya hai taake Flutter default rasta use kare

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}