package dev.rdf.counter

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onResume() {
        super.onResume()
        android.util.Log.d("rdf", "rdf-kt-0")
    }
}
