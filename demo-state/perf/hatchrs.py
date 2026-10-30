p="dwgscene_fast_src/src/lib.rs"; s=open(p).read()
code = r'''
/// flat.py Flattener._hatch boundary loops: list of flat transformed point lists, or None when a path holds anything not handled here
/// (SPLINE edges, odd shapes): the caller then runs the unchanged Python loop code.
fn pt2(v: &Bound<'_, PyAny>) -> Option<(f64, f64)> {
    Some((v.get_item(0).ok()?.extract::<f64>().ok()?, v.get_item(1).ok()?.extract::<f64>().ok()?))
}
#[pyfunction]
#[pyo3(signature = (paths, elev, mat, ax=None))]
fn hatch_loops(paths: &Bound<'_, PyAny>, elev: f64, mat: M, ax: Option<Ax>) -> PyResult<Option<Vec<Vec<f64>>>> {
    let mut loops: Vec<Vec<f64>> = Vec::new();
    for p in paths.iter()? {
        let p = p?;
        let segs = match p.get_item("segs") { Ok(s) => s, Err(_) => return Ok(None) };
        let mut sv: Vec<Bound<'_, PyAny>> = Vec::new();
        for sg in segs.iter()? { sv.push(sg?); }
        let kinds: Vec<String> = match sv.iter().map(|sg| sg.get_item(0).and_then(|k| k.extract::<String>())).collect::<Result<Vec<_>, _>>() { Ok(k) => k, Err(_) => return Ok(None) };
        if kinds.is_empty() { continue; }
        let mut pts: Vec<(f64, f64)> = Vec::new();
        if kinds.iter().all(|k| k == "P") {
            let mut vs: Vec<((f64, f64), f64)> = Vec::new();
            for sg in &sv {
                let q = match sg.get_item(1).ok().and_then(|v| pt2(&v)) { Some(q) => q, None => return Ok(None) };
                let b = if sg.len()? > 2 { match sg.get_item(2).ok().and_then(|v| v.extract::<f64>().ok()) { Some(b) => b, None => return Ok(None) } } else { 0.0 };
                vs.push((q, b));
            }
            let n = vs.len();
            pts.push(vs[0].0);
            for i in 0..n { pts.extend(bulge_raw(vs[i].0, vs[(i + 1) % n].0, vs[i].1)); }
            if pts.len() > 1 && pts[pts.len() - 1] == pts[0] { pts.pop(); }
            if pts.len() > 2 { loops.push(flat(pts.into_iter().map(|(x, y)| wpt(&mat, &ax, x, y, elev)).collect())); }
            continue;
        }
        for (sg, k) in sv.iter().zip(kinds.iter()) {
            match k.as_str() {
                "P" => match sg.get_item(1).ok().and_then(|v| pt2(&v)) { Some(q) => pts.push(q), None => return Ok(None) },
                "L" => {
                    let (a, b) = match (sg.get_item(1).ok().and_then(|v| pt2(&v)), sg.get_item(2).ok().and_then(|v| pt2(&v))) { (Some(a), Some(b)) => (a, b), _ => return Ok(None) };
                    pts.push(a); pts.push(b);
                }
                "A" => {
                    let g = |i: usize| sg.get_item(i).ok().and_then(|v| v.extract::<f64>().ok());
                    let (c, r, mut a0, mut a1) = match (sg.get_item(1).ok().and_then(|v| pt2(&v)), g(2), g(3), g(4)) { (Some(c), Some(r), Some(a), Some(b)) => (c, r, a, b), _ => return Ok(None) };
                    let ccw = match sg.get_item(5).and_then(|v| v.is_truthy()) { Ok(t) => t, Err(_) => return Ok(None) };
                    if !ccw { let (o0, o1) = (a0, a1); a0 = 2.0 * PI - o1; a1 = 2.0 * PI - o0; }
                    let mut ap_ = arc_raw(c.0, c.1, r, a0, a1, true);
                    if !ccw { ap_.reverse(); }
                    pts.extend(ap_);
                }
                "E" => {
                    let g = |i: usize| sg.get_item(i).ok().and_then(|v| v.extract::<f64>().ok());
                    let (c, mj, r, mut a0, mut a1) = match (sg.get_item(1).ok().and_then(|v| pt2(&v)), sg.get_item(2).ok().and_then(|v| pt2(&v)), g(3), g(4), g(5)) { (Some(c), Some(m), Some(r), Some(a), Some(b)) => (c, m, r, a, b), _ => return Ok(None) };
                    let has6 = sg.len()? > 6;
                    let ccw6 = if has6 { match sg.get_item(6).and_then(|v| v.is_truthy()) { Ok(t) => t, Err(_) => return Ok(None) } } else { true };
                    if has6 && !ccw6 { let (o0, o1) = (a0, a1); a0 = 2.0 * PI - o1; a1 = 2.0 * PI - o0; }
                    if a1 <= a0 { a1 += 2.0 * PI; }
                    let mut ep: Vec<(f64, f64)> = Vec::with_capacity(33);
                    for i in 0..33 {
                        let t = a0 + ((a1 - a0) * (i as f64)) / 32.0;
                        ep.push((c.0 + mj.0 * t.cos() - mj.1 * r * t.sin(), c.1 + mj.1 * t.cos() + mj.0 * r * t.sin()));
                    }
                    if has6 && !ccw6 { ep.reverse(); }
                    pts.extend(ep);
                }
                _ => return Ok(None),
            }
        }
        if pts.len() > 2 { loops.push(flat(pts.into_iter().map(|(x, y)| wpt(&mat, &ax, x, y, elev)).collect())); }
    }
    Ok(Some(loops))
}
'''
marker="/// Mat.apply over a flat list [x0,y0,x1,y1,...]"
assert s.count(marker)==1
s=s.replace(marker, code+"\n"+marker)
reg="    m.add_function(wrap_pyfunction!(sane, m)?)?;"
assert s.count(reg)==1
s=s.replace(reg, reg+"\n    m.add_function(wrap_pyfunction!(hatch_loops, m)?)?;")
open(p,"w").write(s)
