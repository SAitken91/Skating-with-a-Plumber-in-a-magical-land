use skate_host::bridge::{Session,Controls};
mod ipc;
mod rails;
fn run()->Result<(),String>{
    let args:Vec<_>=std::env::args().collect();
    let root=std::path::Path::new(args.get(1).ok_or("assets path required")?);
    if args.get(2).map(String::as_str)==Some("--ipc") {
        return ipc::run(root,args.get(3).ok_or("PID required")?.parse().map_err(|_|"bad PID")?);
    }
    if args.get(2).map(String::as_str)==Some("--buttons") {
        // Which buttons take the skater off the board, and back on?
        for (name,bit) in [("A",0x1000u16),("B",0x2000),("X",0x4000),("Y",0x8000),("LB",0x100),("RB",0x200),("BACK",0x20),("LS",0x40),("RS",0x80)] {
            let mut session=Session::new(root,ipc::floor(),vec![],[0.;3],0.)?;
            session.activate([0.;3],0.)?;
            let mut states=Vec::new();
            for tick in 0..360 {
                let mut pad=Controls::default();
                if (60..70).contains(&tick)||(200..210).contains(&tick){pad.buttons=bit;}
                session.tick(pad)?;
                let st=session.pose().state;
                if states.last()!=Some(&st){states.push(st.clone());println!("{name} tick={tick} state={st}");}
            }
        }
        return Ok(());
    }
    // Offline check on a flat floor: push forward, then ollie. Prints the axes
    // the Lua side relies on (root height above the floor, facing, board layout).
    let heading=args.get(2).and_then(|s|s.parse::<f32>().ok()).unwrap_or(0.);
    let mut session=Session::new(root,ipc::floor(),vec![],[0.;3],heading)?;
    session.activate([0.;3],heading)?;
    for tick in 0..480 {
        let mut pad=Controls::default();
        if tick>30&&tick<300 {pad.buttons=0x1000;}
        if tick>340&&tick<390 {pad.right=[0,-32767];}
        if tick>=390&&tick<396 {pad.right=[0,32767];}
        session.tick(pad)?;
        let p=session.pose();
        if !p.root.is_finite()||!p.velocity.is_finite(){return Err("nonfinite pose".into());}
        if tick%40==0||tick==395 {
            let board=p.names.iter().position(|n|n=="SKATEBOARD_ROOT").map(|i|p.root*p.bones[i]).unwrap_or(p.root);
            println!("tick={tick} state={} root_pos={:?} root_x={:?} root_z={:?} vel={:?}",p.state,p.root.w_axis.truncate(),p.root.x_axis.truncate(),p.root.z_axis.truncate(),p.velocity);
            println!("   board_pos={:?} bx={:?} by={:?} bz={:?}",board.w_axis.truncate(),board.x_axis.truncate(),board.y_axis.truncate(),board.z_axis.truncate());
            if let Some((c,b,fov))=p.camera {println!("   camera={c:?} forward(z)={:?} fov={fov}",b.z_axis);}
        }
        if tick==0 {
            for (i,(n,b)) in p.names.iter().zip(&p.bones).enumerate(){println!("BONE {i} {n} {:?}",b.w_axis.truncate());}
        }
    }
    Ok(())
}
fn main(){let result=std::thread::Builder::new().stack_size(32*1024*1024).spawn(run).unwrap().join().unwrap();if let Err(e)=result{eprintln!("ERROR: {e}");std::process::exit(1);}}
