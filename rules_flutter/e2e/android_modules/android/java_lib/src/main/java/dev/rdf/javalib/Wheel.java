package dev.rdf.javalib;

import javax.inject.Inject;

public final class Wheel {
  @Inject
  Wheel() {}

  public String name() {
    return "javac";
  }
}
