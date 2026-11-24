package dev.rdf.javalib;

public final class JavaAp {
  private JavaAp() {}

  public static String run() {
    return DaggerCar.create().wheel().name();
  }
}
