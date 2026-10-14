// SM64 Coop Deluxe skating bridge. Loaded as discord_game_sdk.dll (exports are
// forwarded to discord_game_sdk_real.dll). It hooks coopdx's Lua (lua_pcallk,
// located through coop.map) to register sk_* functions for the sm64-skate Lua
// mod, and connects that mod to the Rust skate host through shared memory.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <xinput.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <unordered_map>
#include <algorithm>
#include <cctype>
#include <cstddef>
#include "rig.h"

// Exports forwarded to the original Discord SDK, renamed discord_game_sdk_real.dll.
#pragma comment(linker,"/export:DiscordCreate=discord_game_sdk_real.DiscordCreate")
#pragma comment(linker,"/export:DiscordVersion=discord_game_sdk_real.DiscordVersion")

// ---------------------------------------------------------------- logging
static char root[MAX_PATH];
static void log(const char* format,...){
    char path[MAX_PATH];sprintf_s(path,"%s\\skate\\bridge.log",root);
    FILE* f=nullptr;if(fopen_s(&f,path,"a")||!f)return;
    SYSTEMTIME t;GetLocalTime(&t);fprintf(f,"%02d:%02d:%02d.%03d ",t.wHour,t.wMinute,t.wSecond,t.wMilliseconds);
    va_list a;va_start(a,format);vfprintf(f,format,a);va_end(a);fputc('\n',f);fclose(f);
}

// ---------------------------------------------------------------- Lua 5.3 API (static in coopdx)
struct lua_State;
using lua_CFunction=int(*)(lua_State*);
using lua_KFunction=int(*)(lua_State*,int,intptr_t);
namespace lua {
    int (*gettop)(lua_State*);
    void (*settop)(lua_State*,int);
    int (*type)(lua_State*,int);
    double (*tonumberx)(lua_State*,int,int*);
    long long (*tointegerx)(lua_State*,int,int*);
    int (*toboolean)(lua_State*,int);
    const char* (*tolstring)(lua_State*,int,size_t*);
    size_t (*rawlen)(lua_State*,int);
    void (*pushnil)(lua_State*);
    void (*pushnumber)(lua_State*,double);
    void (*pushinteger)(lua_State*,long long);
    const char* (*pushstring)(lua_State*,const char*);
    void (*pushboolean)(lua_State*,int);
    void (*pushcclosure)(lua_State*,lua_CFunction,int);
    int (*rawgeti)(lua_State*,int,long long);
    void (*rawseti)(lua_State*,int,long long);
    void (*createtable)(lua_State*,int,int);
    void (*setfield)(lua_State*,int,const char*);
    void (*setglobal)(lua_State*,const char*);
    int (*checkstack)(lua_State*,int);
    int (*pcallk)(lua_State*,int,int,int,intptr_t,lua_KFunction);
    void* (*touserdata)(lua_State*,int);
}
static double num(lua_State* L,int i,double fallback=0){int ok=0;double v=lua::tonumberx(L,i,&ok);return ok&&std::isfinite(v)?v:fallback;}
static long long integer(lua_State* L,int i,long long fallback=0){int ok=0;long long v=lua::tointegerx(L,i,&ok);return ok?v:fallback;}
static void field(lua_State* L,const char* k,double v){lua::pushnumber(L,v);lua::setfield(L,-2,k);}
static void fieldi(lua_State* L,const char* k,long long v){lua::pushinteger(L,v);lua::setfield(L,-2,k);}
static void fields(lua_State* L,const char* k,const char* v){lua::pushstring(L,v);lua::setfield(L,-2,k);}
static void array(lua_State* L,const char* k,const float* v,int n){
    lua::createtable(L,n,0);for(int i=0;i<n;i++){lua::pushnumber(L,v[i]);lua::rawseti(L,-2,i+1);}lua::setfield(L,-2,k);
}

// coop.map lists the statically linked Lua symbols as .text offsets.
static std::unordered_map<std::string,uintptr_t> symbols;
static bool loadMap(){
    char path[MAX_PATH];sprintf_s(path,"%s\\coop.map",root);
    FILE* f=nullptr;if(fopen_s(&f,path,"r")||!f){log("coop.map missing");return false;}
    auto base=reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    auto nt=reinterpret_cast<IMAGE_NT_HEADERS*>(base+reinterpret_cast<IMAGE_DOS_HEADER*>(base)->e_lfanew);
    auto sec=IMAGE_FIRST_SECTION(nt);uintptr_t text=0;
    for(int i=0;i<nt->FileHeader.NumberOfSections;i++)if(!memcmp(sec[i].Name,".text",6))text=uintptr_t(base)+sec[i].VirtualAddress;
    char line[512];
    while(fgets(line,sizeof line,f)){
        if(strncmp(line,"(sec1)",6))continue;
        char* hex=strstr(line,")0x");if(!hex)continue;
        char* name=nullptr;unsigned long long offset=strtoull(hex+1,&name,16);
        while(*name==' ')name++;
        char* end=name+strcspn(name,"\r\n");*end=0;
        symbols[name]=text+uintptr_t(offset);
    }
    fclose(f);return text!=0;
}
template<class T>static bool bind(T& slot,const char* name){
    auto it=symbols.find(name);if(it==symbols.end()){log("missing symbol %s",name);return false;}
    slot=reinterpret_cast<T>(it->second);return true;
}

// ---------------------------------------------------------------- shared memory with the host
constexpr uint32_t MAGIC=0x34364d53,VERSION=1;
constexpr size_t HEADER=8192,MAX_TRI=100000,MAP_SIZE=HEADER+MAX_TRI*36;
static HANDLE mapping,mutex,child;static uint32_t* shared;
static uint32_t result[2048];
static std::vector<float> geometry;static uint32_t geometryRevision=0,sentRevision=0;
static uint32_t heartbeat=0,tuningRevision=0;static float tuning[14];static bool tuningDirty=false;
static float& sf(uint32_t* p,int i){return reinterpret_cast<float*>(p)[i];}
static double preciseSeconds(){static LARGE_INTEGER f{};if(!f.QuadPart)QueryPerformanceFrequency(&f);LARGE_INTEGER c;QueryPerformanceCounter(&c);return double(c.QuadPart)/double(f.QuadPart);}
static bool hostRunning(){return child&&WaitForSingleObject(child,0)==WAIT_TIMEOUT;}
static bool startHost(){
    if(hostRunning())return true;
    if(child){CloseHandle(child);child=nullptr;log("Host exited, restarting");}
    wchar_t name[100];
    if(!shared){
        swprintf_s(name,L"Local\\SM64_Skate_%lu",GetCurrentProcessId());
        mapping=CreateFileMappingW(INVALID_HANDLE_VALUE,nullptr,PAGE_READWRITE,0,DWORD(MAP_SIZE),name);if(!mapping)return false;
        shared=static_cast<uint32_t*>(MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,MAP_SIZE));if(!shared)return false;
        swprintf_s(name,L"Local\\SM64_Skate_Mutex_%lu",GetCurrentProcessId());mutex=CreateMutexW(nullptr,FALSE,name);if(!mutex)return false;
    }
    memset(shared,0,MAP_SIZE);shared[0]=MAGIC;shared[1]=VERSION;shared[2]=GetCurrentProcessId();
    sentRevision=0;memset(result,0,sizeof result);
    if(tuningRevision){shared[40]=tuningRevision;memcpy(shared+41,tuning,sizeof tuning);}
    char exe[MAX_PATH],ini[MAX_PATH],assets[MAX_PATH],command[1024],output[MAX_PATH];
    sprintf_s(exe,"%s\\skate\\sm64-skate-host.exe",root);sprintf_s(ini,"%s\\skate\\settings.ini",root);
    GetPrivateProfileStringA("Skate","Assets","",assets,MAX_PATH,ini);
    if(!assets[0]){log("Missing Assets setting in %s",ini);return false;}
    sprintf_s(command,"\"%s\" \"%s\" --ipc %lu",exe,assets,GetCurrentProcessId());
    sprintf_s(output,"%s\\skate\\host.log",root);
    SECURITY_ATTRIBUTES security{sizeof security,nullptr,TRUE};
    HANDLE out=CreateFileA(output,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
    STARTUPINFOA si{};si.cb=sizeof si;si.dwFlags=STARTF_USESTDHANDLES|STARTF_USESHOWWINDOW;si.wShowWindow=SW_HIDE;si.hStdOutput=out;si.hStdError=out;
    PROCESS_INFORMATION pi{};
    bool ok=CreateProcessA(exe,command,nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,root,&si,&pi)!=0;
    if(out!=INVALID_HANDLE_VALUE)CloseHandle(out);
    if(!ok){log("Host launch failed %lu",GetLastError());return false;}
    child=pi.hProcess;CloseHandle(pi.hThread);log("Host started: %s",command);return true;
}

// ---------------------------------------------------------------- input
static bool focused(){DWORD pid=0;GetWindowThreadProcessId(GetForegroundWindow(),&pid);return pid==GetCurrentProcessId();}
static bool keyDown(int vk){return focused()&&(GetAsyncKeyState(vk)&0x8000)!=0;}
using XGet=DWORD(WINAPI*)(DWORD,XINPUT_STATE*);static XGet xget;
static bool readPad(XINPUT_STATE& s){
    if(!xget)for(auto dll:{"xinput1_4.dll","xinput1_3.dll","xinput9_1_0.dll"})if(auto h=LoadLibraryA(dll)){xget=reinterpret_cast<XGet>(GetProcAddress(h,"XInputGetState"));if(xget)break;}
    if(!xget)return false;
    for(DWORD i=0;i<4;i++){memset(&s,0,sizeof s);if(xget(i,&s)==ERROR_SUCCESS)return true;}
    return false;
}

// ---------------------------------------------------------------- Lua functions
static int sk_version(lua_State* L){lua::pushinteger(L,3);return 1;}
static int sk_log(lua_State* L){const char* s=lua::tolstring(L,1,nullptr);log("lua: %s",s?s:"(nil)");return 0;}
static int sk_time(lua_State* L){lua::pushnumber(L,preciseSeconds());return 1;}
static int sk_start(lua_State* L){lua::pushboolean(L,startHost());return 1;}
static int sk_running(lua_State* L){lua::pushboolean(L,hostRunning());return 1;}
static int sk_key(lua_State* L){lua::pushboolean(L,keyDown(int(integer(L,1))));return 1;}
static int sk_focused(lua_State* L){lua::pushboolean(L,focused());return 1;}
// buttons, lt, rt, lx, ly, rx, ry (raw XInput), or nil without a controller.
static int sk_pad(lua_State* L){
    XINPUT_STATE s;if(!readPad(s)){lua::pushnil(L);return 1;}
    bool f=focused();auto& g=s.Gamepad;
    lua::pushinteger(L,f?g.wButtons:0);lua::pushinteger(L,f?g.bLeftTrigger:0);lua::pushinteger(L,f?g.bRightTrigger:0);
    lua::pushinteger(L,f?g.sThumbLX:0);lua::pushinteger(L,f?g.sThumbLY:0);lua::pushinteger(L,f?g.sThumbRX:0);lua::pushinteger(L,f?g.sThumbRY:0);
    return 7;
}
// sk_geometry(flat, triangles): flat holds 9 numbers per triangle, Skate space metres.
static int sk_geometry(lua_State* L){
    long long count=integer(L,2);
    if(lua::type(L,1)!=5||count<=0||count>=(long long)MAX_TRI){lua::pushboolean(L,0);return 1;}
    geometry.resize(size_t(count)*9);
    for(long long i=0;i<count*9;i++){lua::rawgeti(L,1,i+1);geometry[size_t(i)]=float(num(L,-1,NAN));lua::settop(L,-2);}
    for(float v:geometry)if(!std::isfinite(v)){geometry.clear();lua::pushboolean(L,0);return 1;}
    geometryRevision++;log("Geometry revision %u: %lld triangles",geometryRevision,count);
    lua::pushboolean(L,1);return 1;
}
static int sk_tuning(lua_State* L){
    if(lua::type(L,1)!=5)return 0;
    for(int i=0;i<14;i++){lua::rawgeti(L,1,i+1);tuning[i]=float(num(L,-1,i>=12?0:1));lua::settop(L,-2);}
    tuningRevision++;tuningDirty=true;return 0;
}
// sk_frame(desired, epoch, x, y, z, heading, ui, aspect, keyboard, engineY): one exchange per game frame.
// The controller is forwarded to the host here. Y is the engine's own on/off-board
// button but the mod uses Y for Mario's on/off, so the engine only sees Y when the
// mod asks for it (engineY), e.g. to get a carrying skater back on the board.
static int sk_frame(lua_State* L){
    if(!shared){lua::pushboolean(L,0);return 1;}
    bool desired=lua::toboolean(L,1)!=0;uint32_t epoch=uint32_t(integer(L,2));
    float spawn[4]={float(num(L,3)),float(num(L,4)),float(num(L,5)),float(num(L,6))};
    bool ui=lua::toboolean(L,7)!=0;float aspect=float(num(L,8,1.333));bool keyboard=lua::toboolean(L,9)!=0;
    bool engineY=lua::toboolean(L,10)!=0;
    XINPUT_STATE pad{};bool padPresent=readPad(pad);
    if(!focused())pad.Gamepad=XINPUT_GAMEPAD{}; // idle while another window has focus
    uint16_t padButtons=uint16_t((pad.Gamepad.wButtons&~XINPUT_GAMEPAD_Y)|(engineY?XINPUT_GAMEPAD_Y:0));
    uint32_t keys=0;
    if(desired&&keyboard&&!ui){
        if(keyDown('W'))keys|=1;if(keyDown('S'))keys|=2;if(keyDown('A'))keys|=4;if(keyDown('D'))keys|=8;
        if(keyDown('K'))keys|=16;if(keyDown('Q'))keys|=32;if(keyDown('E'))keys|=64;
    }
    double now=preciseSeconds();
    bool sendGeometry=desired&&geometryRevision!=sentRevision&&!geometry.empty();
    if(WaitForSingleObject(mutex,sendGeometry?20:2)==WAIT_OBJECT_0){
        shared[3]=desired;shared[4]=epoch;shared[7]=++heartbeat;shared[8]=keys;shared[16]=ui;
        memcpy(shared+14,&now,sizeof now);
        for(int i=0;i<4;i++)sf(shared,10+i)=spawn[i];
        sf(shared,23)=aspect;
        shared[17]=(padPresent||engineY)?1u:0u;shared[18]=padButtons;shared[19]=pad.Gamepad.bLeftTrigger|(pad.Gamepad.bRightTrigger<<8);
        shared[20]=uint16_t(pad.Gamepad.sThumbLX)|(uint32_t(uint16_t(pad.Gamepad.sThumbLY))<<16);
        shared[21]=uint16_t(pad.Gamepad.sThumbRX)|(uint32_t(uint16_t(pad.Gamepad.sThumbRY))<<16);
        shared[22]=pad.dwPacketNumber^(engineY?0x40000000u:0u);
        if(tuningDirty){shared[40]=tuningRevision;memcpy(shared+41,tuning,sizeof tuning);tuningDirty=false;}
        if(sendGeometry){
            shared[1599]=0;shared[5]=geometryRevision;shared[6]=uint32_t(geometry.size()/9);
            memcpy(reinterpret_cast<uint8_t*>(shared)+HEADER,geometry.data(),geometry.size()*sizeof(float));
            sentRevision=geometryRevision;
        }
        ReleaseMutex(mutex);
        // Wait (briefly) until the host has simulated up to this frame, so the
        // pose belongs to this tick rather than an older one.
        double deadline=now+(desired?0.012:0.0);
        for(;;){
            bool done=false;
            if(WaitForSingleObject(mutex,2)==WAIT_OBJECT_0){
                done=shared[37]==heartbeat||shared[33]!=1||!desired;
                memcpy(result,shared,sizeof result);ReleaseMutex(mutex);
            }
            if(done||preciseSeconds()>deadline||!hostRunning())break;
            YieldProcessor();Sleep(0);
        }
    }
    lua::pushboolean(L,1);return 1;
}
static const char* text(int byteOffset,int max){
    static char buffer[3][260];static int slot=0;char* b=buffer[slot=(slot+1)%3];
    memcpy(b,reinterpret_cast<const char*>(result)+byteOffset,max);b[max-1]=0;return b;
}
// Latest published pose: table with status, epoch, tick, state, error, root, board, velocity, camera, score.
static int sk_pose(lua_State* L){
    lua::checkstack(L,8);lua::createtable(L,0,24);
    const float* f=reinterpret_cast<const float*>(result);
    fieldi(L,"published",result[32]);fieldi(L,"status",result[33]);fieldi(L,"epoch",result[34]);fieldi(L,"tick",result[35]);
    fields(L,"state",text(512,64));fields(L,"error",text(768,256));
    array(L,"root",f+64,16);array(L,"board",f+80,16);array(L,"velocity",f+96,3);
    if(result[117]){array(L,"camera",f+104,13);}
    fieldi(L,"tricks",result[832]);fieldi(L,"landed",result[833]);fieldi(L,"bailed",result[834]);
    field(L,"live",f[835]);field(L,"multiplier",f[836]);field(L,"banked",f[837]);fieldi(L,"flags",result[838]);field(L,"line",f[839]);
    fields(L,"trick",text(840*4,64));
    fieldi(L,"bones",result[36]);fieldi(L,"host",hostRunning());
    return 1;
}
// sk_bones(reference): 36*16 floats, current pose (or the retarget reference).
static int sk_bones(lua_State* L){
    if(result[36]!=36){lua::pushnil(L);return 1;}
    const float* f=reinterpret_cast<const float*>(result)+(lua::toboolean(L,1)?1024:256);
    lua::createtable(L,576,0);for(int i=0;i<576;i++){lua::pushnumber(L,f[i]);lua::rawseti(L,-2,i+1);}
    return 1;
}
// Small text files in skate\data for markers, replays and dropped objects.
static bool dataPath(lua_State* L,char* out){
    const char* name=lua::tolstring(L,1,nullptr);if(!name||!*name||strlen(name)>64)return false;
    for(const char* c=name;*c;c++)if(!isalnum(uint8_t(*c))&&*c!='-'&&*c!='_')return false;
    char dir[MAX_PATH];sprintf_s(dir,"%s\\skate\\data",root);CreateDirectoryA(dir,nullptr);
    sprintf_s(out,MAX_PATH,"%s\\%s.txt",dir,name);return true;
}
static int sk_write(lua_State* L){
    char path[MAX_PATH];size_t n=0;const char* s=lua::tolstring(L,2,&n);
    if(!s||!dataPath(L,path)){lua::pushboolean(L,0);return 1;}
    FILE* f=nullptr;if(fopen_s(&f,path,"wb")||!f){lua::pushboolean(L,0);return 1;}
    fwrite(s,1,n,f);fclose(f);lua::pushboolean(L,1);return 1;
}
static int sk_read(lua_State* L){
    char path[MAX_PATH];if(!dataPath(L,path)){lua::pushnil(L);return 1;}
    FILE* f=nullptr;if(fopen_s(&f,path,"rb")||!f){lua::pushnil(L);return 1;}
    std::string s;char b[4096];size_t n;while((n=fread(b,1,sizeof b,f))>0)s.append(b,n);fclose(f);
    lua::pushstring(L,s.c_str());return 1;
}


// ---------------------------------------------------------------- Mario retarget
// coopdx passes structs to Lua as userdata whose first field is the C pointer.
static void* cpointer(lua_State* L,int i){
    if(lua::type(L,i)!=7)return nullptr;
    auto p=static_cast<void**>(lua::touserdata(L,i));return p?*p:nullptr;
}
static bool readable(const void* p,size_t n){
    MEMORY_BASIC_INFORMATION m{};if(!p||!VirtualQuery(p,&m,sizeof m)||m.State!=MEM_COMMIT)return false;
    if(m.Protect&(PAGE_NOACCESS|PAGE_GUARD))return false;
    return uintptr_t(p)+n<=uintptr_t(m.BaseAddress)+m.RegionSize;
}
static rig::Animation* animation(lua_State* L,int i){
    auto a=static_cast<rig::Animation*>(cpointer(L,i));
    if(!a||!readable(a,sizeof *a))return nullptr;
    if(a->values&&!readable(a->values,a->valuesLength*2))return nullptr;
    if(a->index&&!readable(a->index,a->indexLength*2))return nullptr;
    return a;
}
// sk_anim_info(anim) -> valuesLength, indexLength, yTransDivisor
static int sk_anim_info(lua_State* L){
    auto a=animation(L,1);if(!a){lua::pushnil(L);return 1;}
    lua::pushinteger(L,a->valuesLength);lua::pushinteger(L,a->indexLength);lua::pushinteger(L,a->yTransDivisor);return 3;
}
// sk_rig(parents[20], rest[60], referenceAnim, outputAnim) -> true | error text
static int sk_rig(lua_State* L){
    if(result[36]!=36){lua::pushstring(L,"no skeleton from the host yet");return 1;}
    int parent[rig::PARTS];rig::V rest[rig::PARTS];
    for(int i=0;i<rig::PARTS;i++){
        lua::rawgeti(L,1,i+1);parent[i]=int(integer(L,-1,-1));lua::settop(L,-2);
        float t[3];for(int k=0;k<3;k++){lua::rawgeti(L,2,i*3+k+1);t[k]=float(num(L,-1));lua::settop(L,-2);}
        rest[i]={t[0],t[1],t[2]};
    }
    auto pose=animation(L,3),out=animation(L,4);
    const char* error=rig::prepare(rig::current,parent,rest,pose,reinterpret_cast<const float*>(result)+1024,out);
    if(error){log("Rig: %s",error);lua::pushstring(L,error);return 1;}
    log("Rig ready: scale %.2f model units per metre, sides %s",rig::current.scale,rig::current.swapSides?"swapped":"direct");
    lua::pushboolean(L,1);return 1;
}
// sk_rig_apply(slot) or sk_rig_apply(bones, slot) writes the current Skate pose (or a 576-number table) into the output animation.
static int sk_rig_apply(lua_State* L){
    if(!rig::current.ready||result[36]!=36){lua::pushboolean(L,0);return 1;}
    const float* reference=reinterpret_cast<const float*>(result)+1024;
    if(lua::type(L,1)==5){
        static float bones[576];
        for(int i=0;i<576;i++){lua::rawgeti(L,1,i+1);bones[i]=float(num(L,-1));lua::settop(L,-2);}
        rig::solve(rig::current,bones,reference,int(integer(L,2)));
    }else rig::solve(rig::current,reinterpret_cast<const float*>(result)+256,reference,int(integer(L,1)));
    lua::pushboolean(L,1);return 1;
}
// sk_anim_get(anim, slot) / sk_anim_set(anim, values, slot): one frame of the
// two-frame pose animation (63 channel values), for replays.
static int sk_anim_get(lua_State* L){
    auto a=animation(L,1);int slot=int(integer(L,2))&1;
    if(!a||!a->values||a->valuesLength<rig::CHANNELS*2){lua::pushnil(L);return 1;}
    lua::createtable(L,rig::CHANNELS,0);
    for(int c=0;c<rig::CHANNELS;c++){lua::pushinteger(L,int16_t(a->values[c*2+slot]));lua::rawseti(L,-2,c+1);}
    return 1;
}
static int sk_anim_set(lua_State* L){
    auto a=animation(L,1);int slot=int(integer(L,3))&1;
    if(!a||!a->values||a->valuesLength<rig::CHANNELS*2||lua::type(L,2)!=5){lua::pushboolean(L,0);return 1;}
    for(int c=0;c<rig::CHANNELS;c++){lua::rawgeti(L,2,c+1);a->values[c*2+slot]=uint16_t(int16_t(integer(L,-1)));lua::settop(L,-2);}
    lua::pushboolean(L,1);return 1;
}

// ---------------------------------------------------------------- lua_pcallk hook
static void* registeredGlobal=nullptr;
static void registerFunctions(lua_State* L){
    void* global=*reinterpret_cast<void**>(reinterpret_cast<uint8_t*>(L)+0x18);
    if(global==registeredGlobal)return;
    registeredGlobal=global;
    struct{const char* name;lua_CFunction fn;}list[]={
        {"sk_version",sk_version},{"sk_log",sk_log},{"sk_time",sk_time},{"sk_start",sk_start},{"sk_running",sk_running},
        {"sk_key",sk_key},{"sk_focused",sk_focused},{"sk_pad",sk_pad},{"sk_geometry",sk_geometry},{"sk_tuning",sk_tuning},
        {"sk_frame",sk_frame},{"sk_pose",sk_pose},{"sk_bones",sk_bones},{"sk_write",sk_write},{"sk_read",sk_read},
        {"sk_anim_info",sk_anim_info},{"sk_rig",sk_rig},{"sk_rig_apply",sk_rig_apply},{"sk_anim_get",sk_anim_get},{"sk_anim_set",sk_anim_set},
    };
    for(auto& e:list){lua::pushcclosure(L,e.fn,0);lua::setglobal(L,e.name);}
    log("Registered skate functions for Lua state %p",global);
}
using PcallFn=int(*)(lua_State*,int,int,int,intptr_t,lua_KFunction);
static PcallFn originalPcall;
static int hookedPcall(lua_State* L,int nargs,int nresults,int errfunc,intptr_t ctx,lua_KFunction k){
    registerFunctions(L);
    return originalPcall(L,nargs,nresults,errfunc,ctx,k);
}
// lua_pcallk prologue in coopdx 1.5.1 (MinGW): push r14/rdi/rsi/rbx; sub rsp,48h;
// xor eax,eax; mov r14,[rsp+98h]. All position independent, so it is copied as is.
static const uint8_t PROLOGUE[19]={0x41,0x56,0x57,0x56,0x53,0x48,0x83,0xEC,0x48,0x31,0xC0,0x4C,0x8B,0xB4,0x24,0x98,0x00,0x00,0x00};
static bool installHook(){
    auto target=reinterpret_cast<uint8_t*>(lua::pcallk);
    if(memcmp(target,PROLOGUE,sizeof PROLOGUE)){log("lua_pcallk prologue differs; skate bridge disabled");return false;}
    auto tramp=static_cast<uint8_t*>(VirtualAlloc(nullptr,64,MEM_COMMIT|MEM_RESERVE,PAGE_EXECUTE_READWRITE));
    if(!tramp)return false;
    memcpy(tramp,PROLOGUE,sizeof PROLOGUE);
    uint8_t* j=tramp+sizeof PROLOGUE;j[0]=0xFF;j[1]=0x25;*reinterpret_cast<uint32_t*>(j+2)=0;*reinterpret_cast<uint64_t*>(j+6)=uint64_t(target+sizeof PROLOGUE);
    originalPcall=reinterpret_cast<PcallFn>(tramp);
    DWORD old;if(!VirtualProtect(target,16,PAGE_EXECUTE_READWRITE,&old))return false;
    target[0]=0x48;target[1]=0xB8;*reinterpret_cast<uint64_t*>(target+2)=uint64_t(&hookedPcall);target[10]=0xFF;target[11]=0xE0;
    VirtualProtect(target,16,old,&old);FlushInstructionCache(GetCurrentProcess(),target,16);
    return true;
}
static void initialise(){
    GetModuleFileNameA(nullptr,root,MAX_PATH);if(char* s=strrchr(root,'\\'))*s=0;
    char dir[MAX_PATH];sprintf_s(dir,"%s\\skate",root);CreateDirectoryA(dir,nullptr);
    log("Bridge loaded into %s",root);
    if(!loadMap())return;
    bool ok=bind(lua::gettop,"lua_gettop")&&bind(lua::settop,"lua_settop")&&bind(lua::type,"lua_type")&&bind(lua::tonumberx,"lua_tonumberx")
        &&bind(lua::tointegerx,"lua_tointegerx")&&bind(lua::toboolean,"lua_toboolean")&&bind(lua::tolstring,"lua_tolstring")&&bind(lua::rawlen,"lua_rawlen")
        &&bind(lua::pushnil,"lua_pushnil")&&bind(lua::pushnumber,"lua_pushnumber")&&bind(lua::pushinteger,"lua_pushinteger")&&bind(lua::pushstring,"lua_pushstring")
        &&bind(lua::pushboolean,"lua_pushboolean")&&bind(lua::pushcclosure,"lua_pushcclosure")&&bind(lua::rawgeti,"lua_rawgeti")&&bind(lua::rawseti,"lua_rawseti")
        &&bind(lua::createtable,"lua_createtable")&&bind(lua::setfield,"lua_setfield")&&bind(lua::setglobal,"lua_setglobal")&&bind(lua::checkstack,"lua_checkstack")
        &&bind(lua::pcallk,"lua_pcallk")&&bind(lua::touserdata,"lua_touserdata");
    if(!ok)return;
    log(installHook()?"lua_pcallk hooked":"Hook failed");
}
BOOL WINAPI DllMain(HINSTANCE,DWORD reason,LPVOID){
    if(reason==DLL_PROCESS_ATTACH)initialise();
    if(reason==DLL_PROCESS_DETACH&&child){TerminateProcess(child,0);}
    return TRUE;
}
