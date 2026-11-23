#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;

out vec4 fragColor;

void main() {
  fragColor = vec4(FlutterFragCoord().xy / uSize, 0.0, 1.0);
}
