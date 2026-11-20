//! Save a rendered egui frame as a PNG.
//!
//! The screenshot cap is taken from the original program's real rule, read from
//! its decompiled tool definitions:
//!   get_window_state::def  0x10059b558  (per-call long-edge override)
//!   get_desktop_state::def 0x100596ae4  (session/global max_image_dimension)
//!
//! Rule: the long edge is capped in pixels and the aspect ratio is preserved.
//! An explicit per-call value wins over the session/global setting; 0 returns
//! native resolution. Both `max_image_dimension` properties say the cap is
//! "applied on top of" a tighter ceiling, so the tighter of the two wins.

use egui::ColorImage;
use std::fs::File;
use std::io::{Error, ErrorKind};
use std::path::Path;

/// Apply the original's long-edge rule and return the output dimensions.
/// `override_edge`: None = use the session/global ceiling, Some(0) = native,
/// Some(n) = use n (an explicit per-call value wins).
pub fn long_edge_size(w: u32, h: u32, ceiling: u32, override_edge: Option<u32>) -> (u32, u32) {
    let cap = match override_edge {
        Some(0) => return (w, h),
        Some(n) => n,
        None => ceiling,
    };
    if cap == 0 {
        return (w, h);
    }
    let long = w.max(h);
    if long <= cap {
        return (w, h);
    }
    let scale = cap as f32 / long as f32;
    let nw = ((w as f32 * scale).round() as u32).max(1);
    let nh = ((h as f32 * scale).round() as u32).max(1);
    (nw, nh)
}

pub fn save_png(
    path: &str,
    image: &ColorImage,
    ceiling: u32,
    override_edge: Option<u32>,
) -> Result<(), Error> {
    if let Some(parent) = Path::new(path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let (w, h) = (image.size[0] as u32, image.size[1] as u32);
    if w == 0 || h == 0 {
        return Err(Error::new(ErrorKind::InvalidData, "empty frame"));
    }
    let (nw, nh) = long_edge_size(w, h, ceiling, override_edge);

    // Nearest-neighbour resample keeps the aspect ratio and needs no extra
    // image crate; when the cap does not bite this is a straight copy.
    let mut rgba = Vec::with_capacity(nw as usize * nh as usize * 4);
    for y in 0..nh {
        let sy = (y as u64 * h as u64 / nh as u64) as usize;
        for x in 0..nw {
            let sx = (x as u64 * w as u64 / nw as u64) as usize;
            let px = &image.pixels[sy * w as usize + sx];
            rgba.extend_from_slice(&[px.r(), px.g(), px.b(), px.a()]);
        }
    }

    let file = File::create(path)?;
    let mut encoder = png::Encoder::new(file, nw, nh);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder
        .write_header()
        .map_err(|e| Error::new(ErrorKind::Other, e.to_string()))?;
    writer
        .write_image_data(&rgba)
        .map_err(|e| Error::new(ErrorKind::Other, e.to_string()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::long_edge_size;

    #[test]
    fn explicit_zero_is_native() {
        assert_eq!(long_edge_size(1180, 800, 640, Some(0)), (1180, 800));
    }

    #[test]
    fn explicit_value_wins_over_ceiling() {
        assert_eq!(long_edge_size(1180, 800, 640, Some(400)), (400, 271));
    }

    #[test]
    fn ceiling_caps_long_edge_and_preserves_aspect() {
        assert_eq!(long_edge_size(1180, 800, 590, None), (590, 400));
        assert_eq!(long_edge_size(800, 1180, 590, None), (400, 590));
    }

    #[test]
    fn native_when_already_small_enough() {
        assert_eq!(long_edge_size(320, 200, 640, None), (320, 200));
    }
}
