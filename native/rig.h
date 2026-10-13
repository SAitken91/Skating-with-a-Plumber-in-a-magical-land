// Retargets the evaluated 36-bone Skate hierarchy onto Mario's 20 animated
// parts and writes the result as a one-frame SM64 animation (Euler angles per
// part plus the root translation). Same method as the GTA III rig: align the
// two rest poses, carry each mapped bone's rotation delta from the Skate T-pose,
// keep Mario's own bone lengths, and solve the legs so the ankles reach the
// Skate ankles (on the deck).
namespace rig {
struct V {float x,y,z;};
struct M {V x,y,z,p;};
static V add(V a,V b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
static V sub(V a,V b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
static V mul(V a,float s){return {a.x*s,a.y*s,a.z*s};}
static float dot(V a,V b){return a.x*b.x+a.y*b.y+a.z*b.z;}
static V cross(V a,V b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
static float len(V a){return sqrtf(dot(a,a));}
static V norm(V a){float d=len(a);return d>1e-7f?mul(a,1.f/d):V{1,0,0};}
static V vec(const M& a,V v){return add(add(mul(a.x,v.x),mul(a.y,v.y)),mul(a.z,v.z));}
static V point(const M& a,V v){return add(vec(a,v),a.p);}
static M ident(){return {{1,0,0},{0,1,0},{0,0,1},{0,0,0}};}
static M product(const M& a,const M& b){M m{};m.x=vec(a,b.x);m.y=vec(a,b.y);m.z=vec(a,b.z);m.p=add(vec(a,b.p),a.p);return m;}
static M inverse(const M& a){M m{};m.x={a.x.x,a.y.x,a.z.x};m.y={a.x.y,a.y.y,a.z.y};m.z={a.x.z,a.y.z,a.z.z};m.p=mul(vec(m,a.p),-1);return m;}
static M rotation(M a){a.p={0,0,0};a.x=norm(a.x);a.y=norm(sub(a.y,mul(a.x,dot(a.y,a.x))));V z=cross(a.x,a.y);a.z=dot(z,a.z)<0?mul(z,-1):z;return a;}
static M basis(V right,V up){M m{};m.x=norm(right);m.y=norm(sub(up,mul(m.x,dot(up,m.x))));m.z=norm(cross(m.x,m.y));return m;}
static M swing(V from,V to){
    from=norm(from);to=norm(to);V v=cross(from,to);float c=dot(from,to);
    if(c>0.99999f)return ident();
    if(c< -0.99999f){V axis=norm(cross(from,fabsf(from.x)<0.8f?V{1,0,0}:V{0,1,0}));M r{};
        r.x=sub(mul(axis,2*axis.x),V{1,0,0});r.y=sub(mul(axis,2*axis.y),V{0,1,0});r.z=sub(mul(axis,2*axis.z),V{0,0,1});return r;}
    auto apply=[&](V a){return add(add(a,cross(v,a)),mul(cross(v,cross(v,a)),1.f/(1.f+c)));};
    M r{};r.x=apply({1,0,0});r.y=apply({0,1,0});r.z=apply({0,0,1});return r;
}
static V kneeForTarget(V hip,V knee,V ankle,V target){
    float a=len(sub(knee,hip)),b=len(sub(ankle,knee));
    V axis=norm(sub(target,hip));float d=len(sub(target,hip));
    d=std::clamp(d,fabsf(a-b)+0.0001f,a+b-0.0001f);
    float along=(a*a-b*b+d*d)/(2*d),height=sqrtf(std::max(0.f,a*a-along*along));
    V bend=sub(sub(knee,hip),mul(axis,dot(sub(knee,hip),axis)));
    if(dot(bend,bend)<1e-8f)bend=cross(axis,fabsf(axis.x)<0.8f?V{1,0,0}:V{0,1,0});
    return add(hip,add(mul(axis,along),mul(norm(bend),height)));
}
// SM64 animated part rotation: column convention R = Rz(z) * Ry(y) * Rx(x).
static M fromEuler(float x,float y,float z){
    float sx=sinf(x),cx=cosf(x),sy=sinf(y),cy=cosf(y),sz=sinf(z),cz=cosf(z);
    M m=ident();
    m.x={cy*cz,cy*sz,-sy};
    m.y={sx*sy*cz-cx*sz,sx*sy*sz+cx*cz,sx*cy};
    m.z={cx*sy*cz+sx*sz,cx*sy*sz-sx*cz,cx*cy};
    return m;
}
static void toEuler(const M& m,float& x,float& y,float& z){
    float sy=std::clamp(-m.x.z,-1.f,1.f);y=asinf(sy);
    if(fabsf(sy)<0.9999f){x=atan2f(m.y.z,m.z.z);z=atan2f(m.x.y,m.x.x);}
    else{x=atan2f(-m.z.y,m.y.y);z=0;} // gimbal: fold z into x
}
static constexpr float S16=32768.f/3.14159265f;
static uint16_t angle16(float r){long v=lroundf(r*S16);return uint16_t(int16_t(((v+32768)%65536+65536)%65536-32768));}
static float fromAngle16(uint16_t v){return float(int16_t(v))/S16;}

struct Animation{int16_t flags,yTransDivisor,startFrame,loopStart,loopEnd,unusedBoneCount;uint16_t* values;uint16_t* index;uint32_t length,valuesLength,indexLength;};
static_assert(offsetof(Animation,values)==16&&offsetof(Animation,valuesLength)==36);
// Frame-0 value of channel c of an SM64 animation.
static float channel(const Animation* a,int c){
    if(!a||!a->index||!a->values||uint32_t(c*2+1)>=a->indexLength)return 0;
    uint32_t offset=a->index[c*2+1];return offset<a->valuesLength?float(int16_t(a->values[offset])):0;
}

constexpr int PARTS=20,CHANNELS=3+PARTS*3;
// Mario part (MARIO_ANIM_PART_* - 1) to Skate bone; see host bone audit:
// 1 HIPS, 5 SPINE3, 8 HEAD, 9-12 right arm, 13-16 left arm, 17-20 right leg, 21-24 left leg.
struct Map{int source,sourceChild,childPart;};
static const Map maps[PARTS]={
    {1,-1,-1},{1,-1,-1},{5,8,3},{8,-1,-1},            // root, butt, torso, head
    {-1,-1,-1},{14,15,6},{15,16,7},{16,-1,-1},          // upper left, left arm, forearm, hand
    {-1,-1,-1},{10,11,10},{11,12,11},{12,-1,-1},        // upper right, right arm, forearm, hand
    {-1,-1,-1},{21,22,14},{22,23,15},{23,24,-1},        // lower left, left thigh, leg, foot
    {-1,-1,-1},{17,18,18},{18,19,19},{19,20,-1},        // lower right, right thigh, leg, foot
};
struct Rig{
    bool ready=false;int parent[PARTS];V rest[PARTS];M bind[PARTS],localBind[PARTS],restOrientation[PARTS];
    float scale=1;bool swapSides=false;Animation* out=nullptr;
};
static Rig current;
static M fromCols(const float* f){M m{};m.x={f[0],f[1],f[2]};m.y={f[4],f[5],f[6]};m.z={f[8],f[9],f[10]};m.p={f[12],f[13],f[14]};return m;}
static float legLength(const M* b,int hip,int knee,int ankle){return len(sub(b[knee].p,b[hip].p))+len(sub(b[ankle].p,b[knee].p));}

// parent: part parent (-1 root); rest: part translations (model units);
// pose: Mario's A-pose animation; reference: Skate T-pose bones (root space).
static const char* prepare(Rig& r,const int* parent,const V* rest,const Animation* pose,const float* reference,Animation* out){
    r=Rig{};
    if(!out||!out->values||out->valuesLength<CHANNELS*2)return "output animation too small";
    if(!pose)return "no reference animation";
    M ref[36];for(int i=0;i<36;i++)ref[i]=fromCols(reference+i*16);
    for(int i=0;i<PARTS;i++){
        r.parent[i]=parent[i];r.rest[i]=rest[i];
        if(i&&(parent[i]<0||parent[i]>=i))return "part hierarchy is not depth-first";
        M local=fromEuler(fromAngle16(uint16_t(channel(pose,3+i*3))),fromAngle16(uint16_t(channel(pose,4+i*3))),fromAngle16(uint16_t(channel(pose,5+i*3))));
        local.p=rest[i];
        r.bind[i]=i?product(r.bind[parent[i]],local):local;
        r.localBind[i]=local;
    }
    // Which of Mario's "left" parts is on the skater's left (+X when facing +Z)?
    r.swapSides=r.bind[5].p.x<r.bind[9].p.x;
    float marioLeg=legLength(r.bind,13,14,15),skateLeg=legLength(ref,21,22,23);
    if(marioLeg<1||skateLeg<0.1f)return "degenerate leg lengths";
    r.scale=marioLeg/skateLeg;
    auto source=[&](int i,int which){int s=which==0?maps[i].source:maps[i].sourceChild;
        if(s<0||!r.swapSides)return s;
        static const int mirror[36]={0,1,2,3,4,5,6,7,8,13,14,15,16,9,10,11,12,21,22,23,24,17,18,19,20,25,26,27,28,29,30,31,33,32,35,34};
        return mirror[s];};
    int armR=9,armL=5,head=3,waist=0;
    if(r.swapSides)std::swap(armR,armL);
    M targetBasis=basis(sub(r.bind[armR].p,r.bind[armL].p),sub(r.bind[head].p,r.bind[waist].p));
    M sourceBasis=basis(sub(ref[10].p,ref[14].p),sub(ref[8].p,ref[1].p));
    M alignment=product(sourceBasis,inverse(targetBasis));
    for(int i=0;i<PARTS;i++){
        r.restOrientation[i]=product(alignment,rotation(r.bind[i]));
        int s=source(i,0),sc=source(i,1);
        if(s<0||sc<0)continue;
        V target;
        if(maps[i].childPart>=0)target=sub(r.bind[maps[i].childPart].p,r.bind[i].p);
        else target=V{0,-0.35f,1}; // feet have no toe part: toes point forward
        target=vec(alignment,target);
        V src=sub(ref[sc].p,ref[s].p);
        if(dot(target,target)>0.0001f&&dot(src,src)>1e-6f)r.restOrientation[i]=product(swing(target,src),r.restOrientation[i]);
    }
    r.out=out;
    // Two-frame animation: channel c keeps frames 0 and 1 at values[c*2], values[c*2+1].
    // Alternating the frame each tick gives coopdx's renderer a previous and a
    // current pose to blend between (it interpolates within one animation).
    if(!out->index||out->indexLength<uint32_t(CHANNELS*2))return "output animation index too small";
    for(int c=0;c<CHANNELS;c++){out->index[c*2]=2;out->index[c*2+1]=uint16_t(c*2);}
    r.ready=true;
    return nullptr;
}
// bones/reference: Skate root-space matrices. Writes the pose into r.out.
static void solve(const Rig& r,const float* bones,const float* reference,int slot){
    if(!r.ready)return;
    M pose[36],ref[36];
    for(int i=0;i<36;i++){pose[i]=fromCols(bones+i*16);ref[i]=fromCols(reference+i*16);}
    auto source=[&](int s){if(s<0||!r.swapSides)return s;
        static const int mirror[36]={0,1,2,3,4,5,6,7,8,13,14,15,16,9,10,11,12,21,22,23,24,17,18,19,20,25,26,27,28,29,30,31,33,32,35,34};
        return mirror[s];};
    M world[PARTS];
    for(int i=0;i<PARTS;i++){
        int s=source(maps[i].source),p=r.parent[i];
        if(s<0){world[i]=p>=0?product(world[p],r.localBind[i]):r.bind[i];continue;}
        M delta=product(rotation(pose[s]),inverse(rotation(ref[s])));
        world[i]=product(delta,r.restOrientation[i]);
        world[i].p=p<0?mul(pose[source(1)].p,r.scale):point(world[p],r.rest[i]);
    }
    // Two-bone IK: Mario's ankles to the (scaled) Skate ankles.
    const int legs[2][3]={{13,14,15},{17,18,19}};const int ankles[2]={23,19};
    for(int side=0;side<2;side++){
        int hip=legs[side][0],knee=legs[side][1],foot=legs[side][2];
        V target=mul(pose[source(ankles[side])].p,r.scale);
        V oldKnee=world[knee].p,oldFoot=world[foot].p;
        V newKnee=kneeForTarget(world[hip].p,oldKnee,oldFoot,target);
        M upper=swing(sub(oldKnee,world[hip].p),sub(newKnee,world[hip].p));
        V hp=world[hip].p;world[hip]=product(upper,world[hip]);world[hip].p=hp;
        M lower=swing(sub(oldFoot,oldKnee),sub(target,newKnee));
        V footRest=world[foot].p;(void)footRest;
        M kneeRot=product(lower,product(upper,world[knee]));kneeRot.p=newKnee;world[knee]=kneeRot;
        world[foot].p=point(world[knee],r.rest[foot]);
    }
    uint16_t* v=r.out->values+(slot&1);
    V t=sub(world[0].p,r.rest[0]);
    v[0]=uint16_t(int16_t(std::clamp(lroundf(t.x),-32767L,32767L)));
    v[2]=uint16_t(int16_t(std::clamp(lroundf(t.y),-32767L,32767L)));
    v[4]=uint16_t(int16_t(std::clamp(lroundf(t.z),-32767L,32767L)));
    for(int i=0;i<PARTS;i++){
        int p=r.parent[i];
        M local=p<0?rotation(world[i]):product(inverse(rotation(world[p])),rotation(world[i]));
        float x,y,z;toEuler(local,x,y,z);
        v[(3+i*3)*2]=angle16(x);v[(4+i*3)*2]=angle16(y);v[(5+i*3)*2]=angle16(z);
    }
}
}
