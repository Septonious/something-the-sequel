#ifdef FSH

void main() {
    /* DRAWBUFFERS:0 */
    gl_FragData[0] = vec4(0.0);
    discard;
}

#endif

#ifdef VSH

void main() {
    gl_Position = vec4(-10.0, -10.0, -10.0, 1.0);
}

#endif
