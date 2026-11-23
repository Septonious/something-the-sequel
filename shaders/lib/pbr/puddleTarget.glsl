#if AO_TYPE > 0
/* RENDERTARGETS: 0,10,11,7 */
gl_FragData[3] = puddleData;
#else
/* RENDERTARGETS: 0,7 */
gl_FragData[1] = puddleData;
#endif
