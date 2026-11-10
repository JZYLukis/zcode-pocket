// 仓库分层：库依赖解析在 settings.gradle.kts 的
// dependencyResolutionManagement（PREFER_PROJECT 模式）下被子项目自带
// 仓库架空——真正生效的库仓库是这里的 allprojects（google()/
// mavenCentral()；插件/构建脚本解析走 pluginManagement）。
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
