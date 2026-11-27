// Rotate north-facing local boxes clockwise, preserving min/max corners.
void ddaRotate(inout vec3 lo,inout vec3 hi,int d) {
    if(d==1) { vec2 a=lo.xz,b=hi.xz; lo.xz=vec2(16.0-b.y,a.x); hi.xz=vec2(16.0-a.y,b.x); }
    else if(d==2) { vec2 a=lo.xz;lo.xz=16.0-hi.xz;hi.xz=16.0-a; }
    else if(d==3) { vec2 a=lo.xz,b=hi.xz;lo.xz=vec2(a.y,16.0-b.x);hi.xz=vec2(b.y,16.0-a.x); }
}
// Numbered models are generated from state groups. Return false for unused
// primitive slots. All complex geometry is evaluated through one box loop.
bool ddaPrimitive(uint s,int i,out vec3 lo,out vec3 hi) {
    lo=vec3(0);hi=vec3(16);
    if(s==2u) {hi.y=15;return i==0;}
    if(s==3u||s==4u) {if(s==3u)hi.y=8;else lo.y=8;return i==0;}
    if(s>=5u&&s<=10u) {
        if(s==5u)hi.y=3;else if(s==6u)lo.y=13;
        else {lo.z=13;ddaRotate(lo,hi,int(s)-7);}
        return i==0;
    }
    if(s>=16u&&s<64u) {
        int mask=int(s)&15;bool bars=s>=48u;
        if(i==0) {lo.xz=vec2(bars?7:6);hi.xz=vec2(bars?9:10);return true;}
        int d=bars?i-1:(i-1)/2;
        if(d>=4||(mask&(1<<d))==0)return false;
        float w=1.0;
        lo=vec3(8-w,bars?0:((i&1)==1?6:12),0);
        hi=vec3(8+w,bars?16:((i&1)==1?9:15),bars?8:9);
        ddaRotate(lo,hi,d);return true;
    }
    if(s>=64u&&s<104u) {
        int v=int(s)-64;bool top=v>=20;int d=(v%20)/5;int type=v%5;
        if(i==0){if(top)lo.y=8;else hi.y=8;return true;}
        // Facing is the direction of the raised half. Inner corners add a
        // quarter on the left/right; outer corners retain only a quarter.
        if(i>2|| (i==2&&type!=1&&type!=2))return false;
        lo.y=top?0:8;hi.y=top?8:16;
        if(i==1){hi.z=8;if(type==3)hi.x=8;else if(type==4)lo.x=8;}
        else {lo.z=8;if(type==1)hi.x=8;else lo.x=8;}
        ddaRotate(lo,hi,d);return true;
    }
    if(s>=104u&&s<266u) {
        int v=int(s)-104;int mask=v%81;
        if(i==0){lo.xz=vec2(4);hi.xz=vec2(12);return v>=81;}
        int d=i-1;if(d>=4)return false;
        int divisor=d==0?1:d==1?3:d==2?9:27;int h=(mask/divisor)%3;
        if(h==0)return false;
        lo=vec3(5,0,0);hi=vec3(11,h==1?14:16,8);ddaRotate(lo,hi,d);return true;
    }
    if(s>=266u&&s<282u) {
        int v=int(s)-266,d=(v+2)&3;bool op=(v&4)!=0;float yoff=(v&8)!=0?3:0;
        // Default vanilla gate model faces south; rotate to the state facing.
        if(i<2){lo=vec3(i==0?0:14,5,7);hi=vec3(i==0?2:16,16,9);}
        else if(!op){
            if(i==2){lo=vec3(6,6,7);hi=vec3(10,15,9);}
            else if(i<=4){lo=vec3(2,i==3?6:12,7);hi=vec3(14,i==3?9:15,9);}
            else return false;
        } else if(i<4) {lo=vec3(i==2?0:14,6,13);hi=vec3(i==2?2:16,15,15);}
        else if(i<8){bool left=i<6;bool lower=(i&1)==0;lo=vec3(left?0:14,lower?6:12,9);hi=vec3(left?2:16,lower?9:15,13);}
        else return false;
        lo.y-=yoff;hi.y-=yoff;ddaRotate(lo,hi,d);return true;
    }
    if(s>=282u&&s<286u) {
        // Alpha-cutout ladder approximated by narrow rails and rungs on the
        // actual model plane. The thin optical sheet avoids receiver burial.
        if(i<2){lo=vec3(i==0?2:12,0,15.19);hi=vec3(i==0?4:14,16,15.21);}
        else if(i<6){float y=float((i-2)*4+1);lo=vec3(4,y,15.19);hi=vec3(12,y+2,15.21);}
        else return false;
        ddaRotate(lo,hi,int(s)-282);return true;
    }
    if(s==286u||s==287u) {
        if(i<4){lo.xz=vec2((i&1)==0?0:14,(i&2)==0?0:14);hi.xz=lo.xz+2;return true;}
        if(i<8){lo=vec3(2,14,0);hi=vec3(14,16,2);ddaRotate(lo,hi,i-4);return true;}
        if(i<14){ // Approximate woven cutout with a thin grid, not an opaque slab.
            int v=i-8;float k=float((v%3)*4+3);
            lo=vec3(2,15.99,k);hi=vec3(14,16,k+1);
            if(v>=3){lo.xz=lo.zx;hi.xz=hi.zx;}return true;
        }
        if(i<18&&s==287u){lo=vec3(2,0,0);hi=vec3(14,2,2);ddaRotate(lo,hi,i-14);return true;}
        return false;
    }
    return false;
}
int ddaPrimitiveCount(uint s) {
    if(s>=16u&&s<48u)return 9;
    if(s>=48u&&s<64u)return 5;
    if(s>=64u&&s<104u)return 3;
    if(s>=104u&&s<266u)return 5;
    if(s>=266u&&s<282u)return ((s-266u)&4u)!=0u?8:5;
    if(s>=282u&&s<286u)return 6;
    if(s==286u)return 14;
    if(s==287u)return 18;
    return 1;
}
