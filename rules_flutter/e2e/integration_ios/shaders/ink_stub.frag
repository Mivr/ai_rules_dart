#version 460 core

precision highp float;

uniform vec2 uCanvas;

out vec4 fragColor;

void main() {
    vec2 point = gl_FragCoord.xy / uCanvas;
    fragColor = vec4(point.x, 0.4, point.y, 1.0);
}
