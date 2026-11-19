#if defined GI
/* RENDERTARGETS: 0,9,10,11,13,7 */
gl_FragData[5] = puddleData;
#elif AO_TYPE > 0 && defined SCREEN_SPACE_SHADOWS
/* RENDERTARGETS: 0,9,10,11,7 */
gl_FragData[4] = puddleData;
#elif AO_TYPE > 0
/* RENDERTARGETS: 0,10,11,7 */
gl_FragData[3] = puddleData;
#elif defined SCREEN_SPACE_SHADOWS
/* RENDERTARGETS: 0,9,7 */
gl_FragData[2] = puddleData;
#else
/* RENDERTARGETS: 0,7 */
gl_FragData[1] = puddleData;
#endif
