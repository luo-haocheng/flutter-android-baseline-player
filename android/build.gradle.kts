allprojects {
    repositories {
        // Flutter 引擎产物（io.flutter:*）走国内镜像，避免直连 Google 存储时下载卡死。
        // 这样即使 IDE 里没有设置 FLUTTER_STORAGE_BASE_URL 环境变量也能正常同步/编译。
        // 不需要国内镜像时，删掉下面这一行即可。
        maven { url = uri("https://storage.flutter-io.cn/download.flutter.io") }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
