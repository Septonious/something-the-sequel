#include "/lib/common.glsl"
#ifdef FSH
uniform sampler2D colortex0;
#ifdef DDA_DEFER_ACTIVE
uniform sampler2D colortex13,colortex14,depthtex0;
#if DDA_DEFERRED >= 2 && !defined DDA_SAMPLE_PASS
uniform sampler2D colortex15;
#endif
#include "/lib/vx/voxelization.glsl"
#include "/lib/vx/ddaLighting.glsl"
#include "/lib/vx/ddaDeferredData.glsl"
// The depth guard rejects terrain metadata hidden by later opaque geometry.
bool ddaReceiver(ivec2 pixel,out vec4 pos,out vec4 data){
    pos=texelFetch(colortex13,pixel,0);data=texelFetch(colortex14,pixel,0);
    float depth=texelFetch(depthtex0,pixel,0).r;
    return data.w>=1.0 && maxOf(data.rgb)>0.0 && depth<1.0 && abs(pos.w-depth)<=1.2e-7;
}
vec3 ddaEvaluate(vec4 pos,vec4 data){
    float twoSided;vec3 normal=ddaDecodeNormal(data.w,twoSided);
    return ddaLighting(pos.xyz,normal,twoSided,true);
}
#endif
void main(){
    ivec2 pixel=ivec2(gl_FragCoord.xy);
    #ifdef DDA_SAMPLE_PASS
    /* RENDERTARGETS: 15 */
    gl_FragData[0]=vec4(0.0);
    #ifdef DDA_DEFER_ACTIVE
    #if DDA_DEFERRED == 3
    ivec2 fullPixel=min(pixel*4,textureSize(colortex13,0)-1);
    #else
    ivec2 fullPixel=min(pixel*2,textureSize(colortex13,0)-1);
    #endif
    vec4 pos,data;
    if(ddaReceiver(fullPixel,pos,data))gl_FragData[0]=vec4(ddaEvaluate(pos,data),data.w);
    #endif
    #else
    /* RENDERTARGETS: 0 */
    vec3 color=texelFetch(colortex0,pixel,0).rgb;
    #ifdef DDA_DEFER_ACTIVE
    vec4 pos,data;
    if(ddaReceiver(pixel,pos,data)){
        vec3 light;
        #if DDA_DEFERRED >= 2
        const int gridStep=DDA_DEFERRED==3?4:2;
        vec2 uv=vec2(pixel)/float(gridStep);
        ivec2 sampleBase=ivec2(floor(uv));vec2 f=fract(uv);
        float twoSided;vec3 n=ddaDecodeNormal(data.w,twoSided);
        ivec3 cell=ivec3(floor(pos.xyz+n*0.002));
        #if defined DDA_CONTINUOUS_SOFT && DDA_SOFT_SAMPLES > 0
        cell >>= 2;
        #endif
        vec3 sum=vec3(0.0),loLight=vec3(1e20),hiLight=vec3(0.0);float total=0.0;
        float footprint2=0.0;
        for(int j=0;j<4;++j){
            ivec2 o=ivec2(j&1,j>>1),spix=sampleBase+o;
            float w=(o.x==0?1.0-f.x:f.x)*(o.y==0?1.0-f.y:f.y);
            if(w<=0.0||any(greaterThanEqual(spix,textureSize(colortex15,0))))continue;
            vec4 sampleLight=texelFetch(colortex15,spix,0);
            // Alpha stores the validated receiver normal and two-sided flag.
            // The sample pass already checked depth, so do not re-read it.
            if(sampleLight.a!=data.w)continue;
            vec4 sp=texelFetch(colortex13,spix*gridStep,0);
            vec3 delta=pos.xyz-sp.xyz;
            ivec3 sampleCell=ivec3(floor(sp.xyz+n*0.002));
            #if defined DDA_CONTINUOUS_SOFT && DDA_SOFT_SAMPLES > 0
            sampleCell >>= 2;
            #endif
            if(abs(dot(delta,n))>=0.002||dot(delta,delta)>=0.0625||any(notEqual(cell,sampleCell)))continue;
            sum+=sampleLight.rgb*w;total+=w;footprint2=max(footprint2,dot(delta,delta));
            loLight=min(loLight,sampleLight.rgb);hiLight=max(hiLight,sampleLight.rgb);
        }
        // Refine high-contrast hard edges and lit/umbra transitions. In
        // soft mode ordinary penumbra gradients retain interpolation.
        float peak=maxOf(hiLight),contrast=maxOf(hiLight-loLight);
        #if defined DDA_CONTINUOUS_SOFT && DDA_SOFT_SAMPLES > 0 && defined DDA_RESOLVE_CONFIDENCE
        // Blend to exact evaluation continuously near an incompatible
        // footprint instead of switching between unrelated lighting values.
        // At fully compatible small coplanar footprints retain the cheap
        // bilinear path. Geometry rejection above remains unconditional.
        float confidence=smoothstep(0.25,0.75,total);
        float edgeRisk=smoothstep(0.0100,0.0400,footprint2)*smoothstep(max(0.002,0.20*peak),max(0.004,0.40*peak),max(contrast,0.0));
        confidence*=1.0-edgeRisk;
        if(total<=0.0||confidence<=0.001)light=ddaEvaluate(pos,data);
        else if(confidence>=0.999)light=sum/total;
        else light=mix(ddaEvaluate(pos,data),sum/total,confidence);
        #else
        #if DDA_SOFT_SAMPLES == 0
        bool refine=contrast>max(0.002,0.20*peak);
        #else
        bool refine=maxOf(loLight)<0.0001&&peak>0.002;
        #if defined DDA_CONTINUOUS_SOFT
        refine=(contrast>max(0.003,0.45*peak)) || (footprint2>0.015625 && contrast>max(0.002,0.25*peak));
        #endif
        #endif
        light=total>=0.25&&!refine?sum/total:ddaEvaluate(pos,data);
        #endif
        #else
        light=ddaEvaluate(pos,data);
        #endif
        if(maxOf(light)>0.0)color=pow(max(pow(color,vec3(2.2))+data.rgb*light,vec3(0.0)),vec3(1.0/2.2));
    }
    #endif
    gl_FragData[0]=vec4(color,1.0);
    #endif
}
#endif
#ifdef VSH
void main(){gl_Position=ftransform();}
#endif
