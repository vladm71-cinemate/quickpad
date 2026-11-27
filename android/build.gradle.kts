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

// file_picker 8.x жёстко задаёт compileSdk 34, а flutter_plugin_android_lifecycle
// требует compileSdk >= 36 (AAR metadata check). Выравниваем compileSdk для всех модулей.
subprojects {
    afterEvaluate {
        when (val ext = extensions.findByName("android")) {
            is com.android.build.gradle.LibraryExtension -> ext.compileSdk = 36
            is com.android.build.gradle.BaseAppModuleExtension -> ext.compileSdk = 36
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
