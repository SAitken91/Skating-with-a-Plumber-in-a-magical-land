use skate_host::bridge::{Session,Controls,ControllerTransport,InputFrame,Pose,PreparedCollision};
use skate_host::tuning::TrainerTuning;
use bevy_math::{Mat3,Mat4,Vec3};
use std::{ffi::c_void,path::Path,time::{Duration,Instant}};
// Protocol shared with native/bridge.cpp (u32 word indices, Skate space: metres, Y up).
// In:  3 desired, 4 epoch, 5 geometry revision, 6 triangle count, 7 heartbeat, 8 keyboard bits,
//      10..12 spawn, 13 heading (radians), 14..15 clock (f64), 16 UI open, 23 aspect,
//      40 tuning revision, 41..54 tuning, 1599 rail count, 1600.. rails (6 floats each).
// Out: 32 published, 33 status, 34 epoch, 35 tick, 36 bone count, 64 root, 80 board, 96 velocity,
//      104..116 camera (position, basis columns, fov), 117 camera valid, 256 bones, 832 score,
//      1024 reference bones; text: state at byte 512, error at byte 768, trick name at byte 3360.
pub const MAGIC:u32=0x34364d53;
pub const VERSION:u32=1;
const HEADER:usize=8192;
const MAX_TRI:usize=100000;
const MAP_SIZE:usize=HEADER+MAX_TRI*36;
const TUNING_REVISION:usize=40;
const RAIL_COUNT:usize=1599;const RAIL_BASE:usize=1600;const MAX_RAILS:usize=64;
type Handle=*mut c_void;
#[link(name="kernel32")]
unsafe extern "system" {
    fn OpenFileMappingW(access:u32,inherit:i32,name:*const u16)->Handle;
    fn MapViewOfFile(mapping:Handle,access:u32,hi:u32,lo:u32,size:usize)->*mut c_void;
    fn OpenMutexW(access:u32,inherit:i32,name:*const u16)->Handle;
    fn WaitForSingleObject(handle:Handle,ms:u32)->u32;
    fn ReleaseMutex(handle:Handle)->i32;
    fn CloseHandle(handle:Handle)->i32;
    fn UnmapViewOfFile(view:*const c_void)->i32;
    fn OpenProcess(access:u32,inherit:i32,pid:u32)->Handle;
}
#[link(name="winmm")]
unsafe extern "system" {fn timeBeginPeriod(ms:u32)->u32;}
struct Connection {map:Handle,mutex:Handle,ptr:*mut u32,process:Handle,seen:std::cell::Cell<u32>}
struct Snapshot {header:[u32;2048],triangles:Option<Vec<[[f32;3];3]>>,rails:Vec<Vec<[f32;3]>>}
fn wide(s:&str)->Vec<u16>{s.encode_utf16().chain(Some(0)).collect()}
impl Connection {
    fn open(pid:u32)->Result<Self,String>{unsafe{
        let map=OpenFileMappingW(0xf001f,0,wide(&format!("Local\\SM64_Skate_{pid}")).as_ptr());
        if map.is_null(){return Err("Cannot open bridge mapping".into());}
        let mutex=OpenMutexW(0x100001,0,wide(&format!("Local\\SM64_Skate_Mutex_{pid}")).as_ptr());
        let ptr=MapViewOfFile(map,0xf001f,0,0,MAP_SIZE) as *mut u32;
        let process=OpenProcess(0x100000,0,pid);
        if mutex.is_null()||ptr.is_null()||process.is_null(){return Err("Cannot connect to bridge".into());}
        if *ptr!=MAGIC||*ptr.add(1)!=VERSION{return Err("Bridge version mismatch".into());}
        Ok(Self{map,mutex,ptr,process,seen:std::cell::Cell::new(0)})
    }}
    fn read(&self,previous_geometry:u32,read_geometry:bool)->Option<Snapshot>{unsafe{
        if WaitForSingleObject(self.mutex,2)!=0{return None;}
        let mut header=[0;2048];std::ptr::copy_nonoverlapping(self.ptr,header.as_mut_ptr(),2048);
        let triangles=if read_geometry&&header[5]!=previous_geometry&&header[6]>0&&(header[6] as usize)<MAX_TRI {
            let count=header[6] as usize;
            Some(std::slice::from_raw_parts((self.ptr as *const u8).add(HEADER) as *const [[f32;3];3],count).to_vec())
        }else{None};
        let mut rails=Vec::new();
        if triangles.is_some(){
            for i in 0..(header[RAIL_COUNT] as usize).min(MAX_RAILS){
                let v:Vec<f32>=(0..6).map(|k|f32::from_bits(header[RAIL_BASE+i*6+k])).collect();
                if v.iter().all(|x|x.is_finite()){rails.push(vec![[v[0],v[1],v[2]],[v[3],v[4],v[5]]]);}
            }
        }
        ReleaseMutex(self.mutex);Some(Snapshot{header,triangles,rails})
    }}
    fn publish(&self,status:u32,epoch:u32,error:&str){
        self.publish_pose(status,epoch,0,Mat4::IDENTITY,Mat4::IDENTITY,Vec3::ZERO,if status==3{"Error"}else{"Ready"},error,None,None,None)
    }
    fn publish_pose(&self,status:u32,epoch:u32,tick:u32,root:Mat4,board:Mat4,velocity:Vec3,state:&str,error:&str,skeleton:Option<(&[Mat4],&[Mat4])>,camera:Option<(Vec3,Mat3,f32)>,score:Option<&ScorePublication>){unsafe{
        if WaitForSingleObject(self.mutex,5)!=0{return;}
        let p=self.ptr;
        if let Some(sc)=score {sc.write(p);}
        *p.add(117)=0;
        if let Some((position,basis,fov))=camera {
            if position.is_finite()&&basis.is_finite()&&fov.is_finite(){
                for (i,v) in position.to_array().iter().chain(basis.to_cols_array().iter()).chain(std::iter::once(&fov)).enumerate(){*p.add(104+i)=v.to_bits();}
                *p.add(117)=1;
            }
        }
        *p.add(32)=1;*p.add(33)=status;*p.add(34)=epoch;*p.add(35)=tick;*p.add(37)=self.seen.get();
        for (i,v) in root.to_cols_array().iter().enumerate(){*p.add(64+i)=v.to_bits();}
        for (i,v) in board.to_cols_array().iter().enumerate(){*p.add(80+i)=v.to_bits();}
        for (i,v) in velocity.to_array().iter().enumerate(){*p.add(96+i)=v.to_bits();}
        *p.add(36)=0;
        if let Some((bones,reference))=skeleton {
            if bones.len()==36&&reference.len()==36 {
                for (offset,matrices) in [(256,bones),(1024,reference)] {
                    for (bone,matrix) in matrices.iter().enumerate(){
                        for (i,v) in matrix.to_cols_array().iter().enumerate(){*p.add(offset+bone*16+i)=v.to_bits();}
                    }
                }
                *p.add(36)=36;
            }
        }
        for (offset,text,max) in [(512,state,64),(768,error,256)] {
            let dest=(p as *mut u8).add(offset);std::ptr::write_bytes(dest,0,max);
            let b=text.as_bytes();std::ptr::copy_nonoverlapping(b.as_ptr(),dest,b.len().min(max-1));
        }
        ReleaseMutex(self.mutex);
    }}
    fn alive(&self)->bool{unsafe{WaitForSingleObject(self.process,0)==258}}
}
impl Drop for Connection{fn drop(&mut self){unsafe{UnmapViewOfFile(self.ptr.cast());CloseHandle(self.map);CloseHandle(self.mutex);CloseHandle(self.process);}}}
/// Combo block, words 832..=839: trick/land/bail counters, live score, multiplier,
/// last banked score, flags (active, switch, fakie, nollie), line score; trick name text at word 840.
#[derive(Default)]
struct ScorePublication {tricks:u32,landed:u32,bailed:u32,live:f32,multiplier:f32,banked:f32,flags:u32,line:f32,name:String,active:bool}
impl ScorePublication {
    fn observe(&mut self,s:&skate_host::scoring_runtime::ScoreInfo){
        if s.new_trick {self.tricks=self.tricks.wrapping_add(1);self.name=s.trick_name.clone();}
        if self.active&&!s.sequence_active {
            if s.bailed {self.bailed=self.bailed.wrapping_add(1);} else {self.landed=self.landed.wrapping_add(1);self.banked=self.live*self.multiplier.max(1.);}
        }
        self.active=s.sequence_active;self.live=s.sequence_score;self.multiplier=s.multiplier;self.line=s.line;
        self.flags=u32::from(s.sequence_active)|u32::from(s.switch)<<1|u32::from(s.fakie)<<2|u32::from(s.nollie)<<3;
    }
    unsafe fn write(&self,ptr:*mut u32){unsafe{
        let words=[self.tricks,self.landed,self.bailed,self.live.to_bits(),self.multiplier.to_bits(),self.banked.to_bits(),self.flags,self.line.to_bits()];
        for (i,w) in words.iter().enumerate(){*ptr.add(832+i)=*w;}
        let dest=(ptr as *mut u8).add(840*4);std::ptr::write_bytes(dest,0,64);
        let b=self.name.as_bytes();std::ptr::copy_nonoverlapping(b.as_ptr(),dest,b.len().min(63));
    }}
}
fn f(header:&[u32],index:usize)->f32{f32::from_bits(header[index])}
/// Controller forwarded by the bridge (Y already filtered), words 17..22.
fn forwarded_pad(header:&[u32])->Option<InputFrame>{
    if header[17]==0{return None;}
    let split=|v:u32|[v as u16 as i16,(v>>16) as u16 as i16];
    Some(InputFrame::from_pad(header[18] as u16,[header[19] as u8,(header[19]>>8) as u8],split(header[20]),split(header[21]),header[22]))
}
fn frame_time(header:&[u32])->f64{f64::from_bits(header[14] as u64|((header[15] as u64)<<32))}
pub fn tuning_from_words(words:&[u32])->TrainerTuning{
    let v=|i:usize|{let x=f32::from_bits(words[i]);if x.is_finite(){x.clamp(0.,10.)}else{1.}};
    TrainerTuning{pop:v(0),boneless:v(1),grind_pop:v(2),offboard_jump:v(3),push_speed:v(4),push_power:v(5),
        braking:v(6),steering:v(7),turn_power:v(8),grip:v(9),wobble:v(10),manual_drag:v(11),hold_fakie:words[12]!=0,hall_of_meat:words.get(13).is_some_and(|w|*w!=0)}
}
fn blend_matrix(a:Mat4,b:Mat4,alpha:f32)->Mat4{
    let (sa,ra,ta)=a.to_scale_rotation_translation();let (sb,rb,tb)=b.to_scale_rotation_translation();
    Mat4::from_scale_rotation_translation(sa.lerp(sb,alpha),ra.slerp(rb,alpha).normalize(),ta.lerp(tb,alpha))
}
pub fn render_pose(previous:&Pose,current:&Pose,alpha:f32)->Pose{
    let mut pose=current.clone();
    if previous.bones.len()!=current.bones.len()||previous.root.w_axis.distance(current.root.w_axis)>5. {return pose;}
    let alpha=alpha.clamp(0.,1.);
    pose.root=blend_matrix(previous.root,current.root,alpha);
    for ((out,a),b) in pose.bones.iter_mut().zip(&previous.bones).zip(&current.bones){*out=blend_matrix(*a,*b,alpha);}
    pose.velocity=previous.velocity.lerp(current.velocity,alpha);
    if let (Some((pa,ba,fa)),Some((pb,bb,fb)))=(&previous.camera,&current.camera){
        if pa.distance(*pb)<5. {
            let a=Mat4::from_mat3(*ba);let b=Mat4::from_mat3(*bb);
            pose.camera=Some((pa.lerp(*pb,alpha),Mat3::from_mat4(blend_matrix(a,b,alpha)),fa+(fb-fa)*alpha));
        }
    }
    pose
}
pub fn find_rails(triangles:&[[[f32;3];3]])->Vec<Vec<[f32;3]>>{
    // Upstream rail finder expects inches with Z up, simulation expects metres/Y up.
    let inch_tris:Vec<_>=triangles.iter().map(|t|t.map(|p|Vec3::new(p[0],-p[2],p[1])/0.0254)).collect();
    let (rails,census)=crate::rails::find(&inch_tris);
    eprintln!("SM64 rails={} from {} triangles ({} candidate edges)",census.rails,triangles.len(),census.candidates);
    rails.into_iter().map(|r|r.into_iter().map(|v|[v.x*0.0254,v.z*0.0254,-v.y*0.0254]).collect()).collect()
}
pub fn floor()->Vec<[[f32;3];3]>{vec![[[-20.,0.,-20.],[-20.,0.,20.],[20.,0.,20.]],[[-20.,0.,-20.],[20.,0.,20.],[20.,0.,-20.]]]}
pub fn run(root:&Path,pid:u32)->Result<(),String>{
    let link=Connection::open(pid)?;
    unsafe{timeBeginPeriod(1);}
    link.publish(2,0,"");
    let mut session=match Session::new(root,floor(),vec![],[0.;3],0.){
        Ok(s)=>s,Err(e)=>{link.publish(3,0,&e);return Err(e);}
    };
    let reference=session.retarget_reference()?;
    let mut controller=ControllerTransport::default();
    let mut geometry=0;let mut epoch=0;let mut heartbeat=0;let mut active=false;
    let mut last_frame=Instant::now();let mut accumulator=0.;let mut old_keys=0;let mut flick_frames=0;
    let mut last_time=None;let mut previous=session.pose();let mut current=session.pose();
    let mut pending:Option<std::thread::JoinHandle<Result<(u32,PreparedCollision),String>>>=None;
    let mut poisoned=false;let mut tuning_revision=0;let mut tuning=TrainerTuning::default();let mut score=ScorePublication::default();
    link.publish(0,0,"");
    eprintln!("SM64_HOST_READY period={}",session.period());
    while link.alive(){
        std::thread::sleep(Duration::from_micros(500));
        let Some(snap)=link.read(geometry,pending.is_none())else{continue};let h=snap.header;
        if h[7]==heartbeat {
            if active&&last_frame.elapsed()>Duration::from_millis(500){session.suspend_input();accumulator=0.;}
            continue;
        }
        heartbeat=h[7];last_frame=Instant::now();link.seen.set(heartbeat);
        if h[TUNING_REVISION]!=tuning_revision {
            tuning_revision=h[TUNING_REVISION];tuning=tuning_from_words(&h[TUNING_REVISION+1..TUNING_REVISION+15]);
            session.set_tuning(tuning);eprintln!("SM64_TUNING revision={tuning_revision} {tuning:?}");
        }
        if h[3]==1&&epoch!=h[4]&&pending.is_some(){pending=None;geometry=0;continue;}
        let time=frame_time(&h);
        if !time.is_finite(){continue;}
        let dt=last_time.map(|old:f64|(time-old).clamp(0.,0.05) as f32).unwrap_or(0.);
        last_time=Some(time);
        if h[3]!=1 {
            if active {session.suspend_input();eprintln!("SM64_DEACTIVATE epoch={}",h[4]);}
            active=false;epoch=h[4];accumulator=0.;old_keys=0;pending=None;
            link.publish(0,epoch,"");continue;
        }
        let step=(||->Result<(),String>{
            if poisoned {
                // Activation alone does not reset every ragdoll body's rates.
                // Rebuild the failed session before accepting another mount.
                session=Session::new(root,floor(),vec![],[0.;3],0.)?;
                geometry=0;pending=None;accumulator=0.;poisoned=false;session.set_tuning(tuning);
                eprintln!("SM64_SESSION_RESET after simulation error");
                return Ok(());
            }
            if !current.state.starts_with("Grind")&&pending.as_ref().is_some_and(|job|job.is_finished()) {
                let (revision,prepared)=pending.take().unwrap().join().map_err(|_|"Collision worker failed")??;
                if active&&epoch==h[4] {session.install_collision(prepared)?;geometry=revision;}
            }
            if let Some(triangles)=snap.triangles {
                let explicit=snap.rails;
                if triangles.iter().flatten().flatten().any(|n|!n.is_finite()){return Err("Invalid collision coordinates".into());}
                let builder=session.collision_builder();let revision=h[5];
                if active&&epoch==h[4] {
                    pending=Some(std::thread::Builder::new().name("sm64-collision".into()).stack_size(8*1024*1024).spawn(move||{
                        let started=Instant::now();let mut rails=find_rails(&triangles);rails.extend(explicit);let prepared=builder.build(triangles,rails)?;
                        eprintln!("SM64_COLLISION_ASYNC revision={revision} build_ms={:.2}",started.elapsed().as_secs_f64()*1000.);
                        Ok((revision,prepared))
                    }).map_err(|e|e.to_string())?);
                }else{
                    let started=Instant::now();
                    let mut rails=find_rails(&triangles);rails.extend(explicit);let prepared=builder.build(triangles,rails)?;
                    session.install_collision(prepared)?;geometry=revision;
                    eprintln!("SM64_COLLISION revision={revision} build_ms={:.2}",started.elapsed().as_secs_f64()*1000.);
                }
            }
            if geometry==0{return Err("No level collision supplied".into());}
            if !active||epoch!=h[4]{
                epoch=h[4];accumulator=0.;old_keys=0;
                let spawn=[f(&h,10),f(&h,11),f(&h,12)];let heading=f(&h,13);
                if !spawn.iter().all(|v|v.is_finite())||!heading.is_finite(){return Err("Invalid spawn".into());}
                session.activate(spawn,heading)?;active=true;
                previous=session.pose();current=previous.clone();
                eprintln!("SM64_ACTIVATE epoch={epoch} spawn={spawn:?} heading={heading}");
            }
            // h[16]: menu or replay open. Brake and ignore the controller.
            let ui=h[16]!=0;
            let keys=if ui{2}else{h[8]};accumulator+=dt;
            if old_keys&16!=0&&keys&16==0 {flick_frames=4;}
            let mut pad=Controls::default();
            if keys&1!=0 {pad.buttons|=0x1000;}
            if keys&2!=0 {pad.buttons|=0x2000;}
            pad.left[0]=if keys&4!=0{-24000}else if keys&8!=0{24000}else{0};
            if keys&16!=0{pad.right[1]=-32767;}
            if flick_frames>0{pad.right=[if keys&32!=0{-26000}else if keys&64!=0{26000}else{0},32767];}
            // Prefer the bridge's copy of the controller: it removes Y, which the
            // mod uses for getting Mario on and off. Fall back to polling directly.
            let packet=if h[1]>=1&&h[17]!=0{forwarded_pad(&h).unwrap_or_else(||controller.poll())}else{controller.poll()};
            let use_controller=packet.controller().is_some()&&!ui&&keys==0&&flick_frames==0;
            if use_controller {session.collect(packet,dt);}
            let period=session.period();
            let mut steps=0;
            while accumulator>=period&&steps<8 {
                if use_controller{session.advance()?;}else{session.tick(pad)?;}
                previous=std::mem::replace(&mut current,session.pose());
                score.observe(&session.score());
                accumulator-=period;steps+=1;
                if flick_frames>0{flick_frames-=1;}
            }
            old_keys=keys;
            let pose=render_pose(&previous,&current,accumulator/period);
            if !pose.root.is_finite()||!pose.velocity.is_finite(){return Err("Invalid simulation pose".into());}
            let board=pose.names.iter().position(|n|n=="SKATEBOARD_ROOT").and_then(|i|pose.bones.get(i)).map(|local|pose.root * *local).unwrap_or(pose.root);
            if pose.bones.iter().any(|m|!m.is_finite()){return Err("Nonfinite skeleton pose".into());}
            let aspect=f(&h,23);if aspect.is_finite()&&aspect>0.5&&aspect<4.{session.set_aspect_ratio(aspect);}
            link.publish_pose(1,epoch,pose.tick as u32,pose.root,board,pose.velocity,&pose.state,"",Some((&pose.bones,&reference)),pose.camera,Some(&score));
            if steps>0&&pose.tick%120==0{eprintln!("SM64_POSE tick={} state={} root={:?} vel={:?} pad={}",pose.tick,pose.state,pose.root.w_axis,pose.velocity,use_controller);}
            Ok(())
        })();
        if let Err(e)=step {
            eprintln!("SM64_ERROR {e}");active=false;poisoned=true;pending=None;
            link.publish(3,epoch,&e);
            // A rejected activation remains rejected until the command epoch changes.
            loop {std::thread::sleep(Duration::from_millis(20));if !link.alive(){return Ok(());}if let Some(s)=link.read(geometry,false){if s.header[3]!=1||s.header[4]!=epoch{break;}}}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use bevy_math::Quat;
    fn pose(x:f32)->Pose{Pose{root:Mat4::from_translation(Vec3::X*x),bones:vec![Mat4::IDENTITY;36],names:vec![],camera:None,velocity:Vec3::X,tick:0,state:String::new()}}
    #[test]
    fn rotation_interpolation_stays_rigid(){
        let a=Mat4::IDENTITY;let b=Mat4::from_quat(Quat::from_rotation_y(2.));
        let m=blend_matrix(a,b,0.5);assert!((m.determinant()-1.).abs()<0.0001);
        assert!(m.abs_diff_eq(Mat4::from_quat(Quat::from_rotation_y(1.)),0.0001));
    }
    #[test]
    fn teleport_does_not_sweep_character_across_world(){assert_eq!(render_pose(&pose(0.),&pose(100.),0.5).root.w_axis.x,100.);}
    #[test]
    fn ipc_clock_keeps_submillisecond_precision(){
        let value=683456.123456789_f64;let bits=value.to_bits();let mut h=[0;2048];h[14]=bits as u32;h[15]=(bits>>32) as u32;
        assert_eq!(frame_time(&h),value);
    }
}
