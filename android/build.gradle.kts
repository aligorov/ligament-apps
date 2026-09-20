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
    if (project.path != ":app") {
        if (!project.state.executed) {
            project.afterEvaluate {
                val android = project.extensions.findByName("android")
                if (android != null) {
                    try {
                        val method = android.javaClass.getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                        method.invoke(android, 36)
                    } catch (_: Throwable) {
                        try {
                            val method = android.javaClass.getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType)
                            method.invoke(android, 36)
                        } catch (_: Throwable) {}
                    }
                }
            }
        }
    }
    tasks.matching { it.name.contains("AarMetadata") }.configureEach {
        enabled = false
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
