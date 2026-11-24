package com.example.federated_greeting_android

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class FederatedGreetingAndroidPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        System.setProperty("rules_flutter.federated_greeting.default_attached", "true")
        channel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            "rules_flutter/federated_greeting",
        )
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        if (call.method == "getGreeting") {
            if (System.getProperty("rules_flutter.federated_greeting.alt_attached") == "true") {
                result.error("DUPLICATE_IMPL", "Both default and alt implementations were registered", null)
            } else {
                result.success("Hello from default federated Android plugin!")
            }
        } else {
            result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        System.clearProperty("rules_flutter.federated_greeting.default_attached")
        channel.setMethodCallHandler(null)
    }
}
