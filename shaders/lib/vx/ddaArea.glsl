// Continuous 2D source coverage: clip an octagonal emitter by projected
// AABB constraints and integrate the union of the resulting silhouettes.
#if DDA_CONTINUOUS_LINES == 4
const int ddaPV=32,ddaPN=2;
#else
const int ddaPV=24,ddaPN=8;
#endif
// Private per-invocation workspaces avoid copying dynamically indexed arrays
// through the nested polygon functions on drivers that lower array parameters.
vec2 ddaPoly[ddaPV],ddaTmp[ddaPV],ddaPolyStore[ddaPV*ddaPN];
int ddaPolyCounts[ddaPN];
vec4 ddaPolyBounds[ddaPN];
float ddaCross2(vec2 a,vec2 b){return a.x*b.y-a.y*b.x;}
float ddaPolygonArea(int n){float a=0.0;for(int i=0;i<n;++i)a+=ddaCross2(ddaPoly[i],ddaPoly[(i+1)%n]);return a*0.5;}
void ddaDiskBasis(vec3 delta,out vec3 u,out vec3 v){
    vec3 n=normalize(delta);float s=n.z>=0.0?1.0:-1.0;
    float a=-1.0/(s+n.z),b=n.x*n.y*a;
    u=vec3(1.0+s*n.x*n.x*a,s*b,-s*n.x)*DDA_SOFT_RADIUS;
    v=vec3(b,s+n.y*n.y*a,-n.y)*DDA_SOFT_RADIUS;
}
void ddaClipPolygon(vec2 a,float b,inout int n){
    if(n==0)return;
    // Exact support of the regular source octagon; redundant constraints
    // and complete rejection need no dynamic polygon clipping.
    vec2 aa=abs(a);float support=max(max(aa.x,aa.y),0.70710678118*(aa.x+aa.y));
    if(b>=support)return;
    if(b<=-support){n=0;return;}
    int count=0;
    vec2 prev=ddaPoly[n-1];float dp=dot(a,prev)-b;
    for(int j=0;j<n;++j){
        vec2 cur=ddaPoly[j];float dc=dot(a,cur)-b;
        if((dp>0.0)!=(dc>0.0)&&dp!=0.0&&dc!=0.0)ddaTmp[count++]=mix(prev,cur,clamp(dp/(dp-dc),0.0,1.0));
        if(dc<=0.0)ddaTmp[count++]=cur;
        prev=cur;dp=dc;
    }
    n=count;for(int j=0;j<n;++j)ddaPoly[j]=ddaTmp[j];
}
int ddaProjectPolygon(vec3 origin,vec3 delta,vec3 u,vec3 v,vec3 lo,vec3 hi){
    const float c=0.70710678118;
    ddaPoly[0]=vec2(1,0);ddaPoly[1]=vec2(c,c);ddaPoly[2]=vec2(0,1);ddaPoly[3]=vec2(-c,c);
    ddaPoly[4]=vec2(-1,0);ddaPoly[5]=vec2(-c,-c);ddaPoly[6]=vec2(0,-1);ddaPoly[7]=vec2(c,-c);
    int n=8;vec3 l=lo-origin,h=hi-origin;
    for(int j=0;j<3;++j){
        vec2 ax=vec2(u[j],v[j]);
        if(abs(l[j])<1e-7)ddaClipPolygon(-ax,delta[j],n);
        if(abs(h[j])<1e-7)ddaClipPolygon(ax,-delta[j],n);
        if(n<3)return 0;
    }
    for(int i=0;i<3;++i){
        float nearPlane=l[i]>1e-7?l[i]:(h[i]<-1e-7?h[i]:0.0);
        if(nearPlane==0.0)continue;
        float q=delta[i]/nearPlane;vec2 m=vec2(u[i],v[i])/nearPlane;
        ddaClipPolygon(-m,q-1.0,n);if(n<3)return 0;
        for(int j=0;j<3;++j){
            vec2 ax=vec2(u[j],v[j]);
            if(l[j]<-1e-7)ddaClipPolygon(m*l[j]-ax,delta[j]-q*l[j],n);
            if(h[j]>1e-7)ddaClipPolygon(ax-m*h[j],q*h[j]-delta[j],n);
            if(n<3)return 0;
        }
    }
    return n;
}
// Each boundary segment covered by another polygon is removed before
// integrating oriented edges. Equal coincident edges have a unique owner.
#if DDA_CONTINUOUS_LINES == 3
bool ddaCoveredEdge(vec2 a,vec2 b,int j,int n,bool sameOwner,out vec2 span){
    span=vec2(0,1);vec2 d=b-a;
    vec4 bounds=ddaPolyBounds[j];
    if(any(lessThan(max(a,b),bounds.xy))||any(greaterThan(min(a,b),bounds.zw)))return false;
    for(int k=0;k<n;++k){
        vec2 q=ddaPolyStore[j*ddaPV+k],e=ddaPolyStore[j*ddaPV+(k+1)%n]-q;
        if(dot(e,e)<1e-14)continue;
        float c=ddaCross2(e,a-q),m=ddaCross2(e,d);
        if(abs(m)<1e-7){
            if(c< -1e-6 || (abs(c)<=1e-6 && dot(e,d)>0.0 && !sameOwner))return false;
        }else{
            float t=-c/m;
            if(m>0.0)span.x=max(span.x,t);else span.y=min(span.y,t);
            if(span.x>=span.y)return false;
        }
    }
    return span.y>span.x;
}
float ddaUnionArea(int n){
    float area=0.0;
    for(int i=0;i<n;++i)for(int k=0;k<ddaPolyCounts[i];++k){
        vec2 a=ddaPolyStore[i*ddaPV+k],b=ddaPolyStore[i*ddaPV+(k+1)%ddaPolyCounts[i]];
        if(dot(b-a,b-a)<1e-14)continue;
        vec2 covered[ddaIntervalLimit];int count=0;
        for(int j=0;j<n;++j){if(i==j)continue;vec2 interval;
            if(ddaCoveredEdge(a,b,j,ddaPolyCounts[j],j<i,interval))ddaAddInterval(interval,covered,count);
        }
        float visible=1.0;for(int j=0;j<count;++j)visible-=covered[j].y-covered[j].x;
        area+=ddaCross2(a,b)*clamp(visible,0.0,1.0);
    }
    return 0.5*area;
}
#else
// Union of two clipped convex silhouettes = area(A)+area(B)-area(A∩B).
// Much smaller private workspace than the general eight-polygon edge union.
float ddaUnionArea(int n){
    int count=ddaPolyCounts[0];for(int j=0;j<count;++j)ddaPoly[j]=ddaPolyStore[j];
    float a=ddaPolygonArea(count);
    int nb=ddaPolyCounts[1];float b=0.0;
    for(int j=0;j<nb;++j){vec2 q=ddaPolyStore[ddaPV+j],e=ddaPolyStore[ddaPV+(j+1)%nb];b+=ddaCross2(q,e);}
    for(int j=0;j<nb && count>=3;++j){
        vec2 q=ddaPolyStore[ddaPV+j],e=ddaPolyStore[ddaPV+(j+1)%nb]-q;
        vec2 normal=vec2(e.y,-e.x);ddaClipPolygon(normal,dot(normal,q),count);
    }
    return a+0.5*b-(count>=3?ddaPolygonArea(count):0.0);
}
#endif
bool ddaDiskTransmission(vec3 start,ivec3 cell,ivec3 target,out vec3 result){
    result=vec3(1.0);vec3 delta=vec3(target)+0.5-start;
    if(all(equal(cell,target)))return true;
    vec3 u,v;ddaDiskBasis(delta,u,v);vec3 extent=sqrt(u*u+v*v);
    vec3 ad=abs(delta);int major=ad.x>=ad.y&&ad.x>=ad.z?0:(ad.y>=ad.z?1:2);
    int ax=(major+1)%3,ay=(major+2)%3,dir=delta[major]>0.0?1:-1;
    float minD=ad[major]-extent[major],maxD=ad[major]+extent[major];
    if(minD<=1e-5)return false;
    int n=0;float singleArea=0.0;
    const float sourceArea=2.82842712475;
    ivec3 cachedBrick=ivec3(-1);uvec2 cachedMask=uvec2(0u);
    for(int k=cell[major];;k+=dir){
        float nearD=dir>0?float(k)-start[major]:start[major]-float(k+1);
        float t0=clamp(nearD/maxD,0.0,1.0),t1=clamp((nearD+1.0)/minD,0.0,1.0);
        vec3 a=delta-extent,b=delta+extent;
        ivec3 il=clamp(ivec3(floor(start+min(a*t0,a*t1)-1e-6)),ivec3(0),ddaSize-1);
        ivec3 ih=clamp(ivec3(floor(start+max(b*t0,b*t1)+1e-6)),ivec3(0),ddaSize-1);
        ivec3 p=ivec3(0);p[major]=k;
        for(int j=il[ax];j<=ih[ax];++j)for(int l=il[ay];l<=ih[ay];++l){
            p[ax]=j;p[ay]=l;if(all(equal(p,target)))continue;
            ivec3 brick=p>>2;
            if(any(notEqual(brick,cachedBrick))){cachedBrick=brick;cachedMask=texelFetch(ddaMaskSampler,brick,0).ba;}
            uint model=ddaModelPacked(p,cachedMask);if(model==0u)continue;
            vec3 base=vec3(p),upper=base+1.0;
            if(model==1u){
                int end=min(ih[ay],l|3);
                while(l<end){ivec3 next=p;next[ay]=l+1;
                    if(all(equal(next,target))||ddaModelPacked(next,cachedMask)!=1u)break;
                    ++l;upper[ay]+=1.0;
                }
            }
            int count=ddaProjectPolygon(start,delta,u,v,base,upper);
            if(count==0)continue;
            if(model>=1024u||model==288u)return false;
            int boxes=model==1u?1:int(texelFetch(ddaShapeSampler,ivec3(0,int(model),0),0).w);
            for(int q=0;q<boxes;++q){
                if(model!=1u){
                    vec3 lo=base+texelFetch(ddaShapeSampler,ivec3(2+q*2,int(model),0),0).xyz*0.0625;
                    vec3 hi=base+texelFetch(ddaShapeSampler,ivec3(3+q*2,int(model),0),0).xyz*0.0625;
                    count=ddaProjectPolygon(start,delta,u,v,lo,hi);
                }
                if(count<3)continue;
                float area=ddaPolygonArea(count);
                if(area>=sourceArea-1e-6){result=vec3(0.0);return true;}
                if(area<1e-8)continue;
                // Ignore a silhouette contained in a previously captured one.
                // This is exact and helps solid walls avoid exhausting capacity.
                bool contained=false;
                for(int m=0;m<n&&!contained;++m){
                    bool inside=true;
                    for(int e=0;e<ddaPolyCounts[m]&&inside;++e){
                        vec2 a=ddaPolyStore[m*ddaPV+e],d=ddaPolyStore[m*ddaPV+(e+1)%ddaPolyCounts[m]]-a;
                        for(int i=0;i<count;++i)if(ddaCross2(d,ddaPoly[i]-a)<-1e-7){inside=false;break;}
                    }
                    contained=inside;
                }
                if(contained)continue;
                if(n>=ddaPN)return false;
                ddaPolyCounts[n]=count;
                vec2 low=vec2(1),high=vec2(-1);
                for(int i=0;i<count;++i){vec2 q=ddaPoly[i];ddaPolyStore[n*ddaPV+i]=q;low=min(low,q);high=max(high,q);}
                ddaPolyBounds[n]=vec4(low,high);++n;singleArea=area;
            }
        }
        if(k==target[major])break;
    }
    if(n==0)return true;
    result=vec3(clamp(1.0-(n==1?singleArea:ddaUnionArea(n))/sourceArea,0.0,1.0));return true;
}
