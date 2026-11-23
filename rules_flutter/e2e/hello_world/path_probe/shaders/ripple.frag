// Fixture fragment shader: the spoke must expose it and may include
// siblings from this directory only, never example/build output.
precision mediump float;

uniform vec2 uSize;

// Flutter shaders write an `out` color: stock compiles every shader a
// package names, and `gl_FragColor` does not compile.
out vec4 fragColor;

void main() {
  fragColor = vec4(gl_FragCoord.xy / uSize, 0.0, 1.0);
}
