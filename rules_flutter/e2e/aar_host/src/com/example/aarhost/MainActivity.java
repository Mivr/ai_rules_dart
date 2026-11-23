package com.example.aarhost;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;
import io.flutter.embedding.android.FlutterActivity;

/**
 * Native host activity embedding FlutterActivity from the AAR module.
 */
public class MainActivity extends Activity {
    private static final String TAG = "AarHostMainActivity";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i(TAG, "MainActivity launched, starting FlutterActivity");
        try {
            Intent intent = FlutterActivity.createDefaultIntent(this);
            startActivity(intent);
        } catch (Throwable t) {
            Log.e(TAG, "Failed to start FlutterActivity: " + t.getMessage(), t);
            throw t;
        }
    }
}
