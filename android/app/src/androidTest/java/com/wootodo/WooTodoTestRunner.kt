package com.wootodo

import android.app.Application
import android.content.Context
import androidx.test.runner.AndroidJUnitRunner

/** 测试时不启动产品 Application 的提醒、Widget 与后台同步，确保 SQLite 用例完全隔离。 */
class WooTodoTestRunner : AndroidJUnitRunner() {
    override fun newApplication(
        classLoader: ClassLoader,
        className: String,
        context: Context,
    ): Application = super.newApplication(
        classLoader,
        Application::class.java.name,
        context,
    )
}
