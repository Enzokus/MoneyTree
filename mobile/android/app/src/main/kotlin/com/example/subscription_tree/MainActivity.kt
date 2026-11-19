package com.example.subscription_tree

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val sharedText = mutableListOf<String>()
    private var intakeChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        receiveText(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        intakeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "moneytree/intake")
        intakeChannel?.setMethodCallHandler { call, result ->
            if (call.method == "takeSharedText") {
                result.success(sharedText.toList())
                sharedText.clear()
            } else {
                result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        intakeChannel?.setMethodCallHandler(null)
        intakeChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receiveText(intent)
    }

    private fun receiveText(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val text = (intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
            ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text)
            ?.take(8000)?.toString()?.trim()
        if (text.isNullOrEmpty()) return
        intent.removeExtra(Intent.EXTRA_TEXT)
        intent.action = null
        sharedText.add(text)
        intakeChannel?.invokeMethod("sharedTextAvailable", null)
    }
}
