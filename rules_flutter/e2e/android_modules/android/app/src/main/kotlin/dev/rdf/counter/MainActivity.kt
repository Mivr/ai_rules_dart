package dev.rdf.counter

import dev.rdf.javalib.JavaAp
import dev.rdf.kaptlib.Kapt
import dev.rdf.ksplib.Json
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onResume() {
        super.onResume()
        // One line per library module, so that a run shows the generated code at work.
        android.util.Log.d("rdf", "rdf-modules ksp=" + Json.roundTrip())
        android.util.Log.d("rdf", "rdf-modules label=" + Json.label(this))
        android.util.Log.d("rdf", "rdf-modules kapt=" + Kapt.run())
        android.util.Log.d("rdf", "rdf-modules javac=" + JavaAp.run())
        android.util.Log.d("rdf", "rdf-modules asset=" + assets.open("hello.txt").bufferedReader().readText().trim())
        android.util.Log.d("rdf", "rdf-modules libasset=" + assets.open("lib.txt").bufferedReader().readText().trim())
        android.util.Log.d("rdf", "rdf-kt-0")
    }
}
