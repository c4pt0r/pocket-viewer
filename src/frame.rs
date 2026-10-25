//! A video frame from either camera, and the conversions the rest of the app
//! needs: JPEG for the browser and snapshots, RGB / BGRA (scaled) for plugins.
//! Conversions are computed once per frame, on first use.

use std::sync::{Arc, OnceLock};

use bytes::Bytes;

/// Pixels as the camera delivered them.
pub enum Pixels {
    Jpeg(Bytes),
    /// Packed 4:2:2, Y0 U Y1 V.
    Yuyv(Vec<u8>),
    /// Packed 4:2:2, U Y0 V Y1 (macOS "2vuy").
    Uyvy(Vec<u8>),
    /// Planar Y, then interleaved UV at half resolution.
    Nv12(Vec<u8>),
    Rgb(Vec<u8>),
}

pub struct Frame {
    /// Seconds on the app clock (see `crate::now`), taken at receipt.
    pub pts: f64,
    pub width: u32,
    pub height: u32,
    pub pixels: Pixels,
    rgb: OnceLock<Option<Arc<Vec<u8>>>>,
    preview: OnceLock<Option<Bytes>>,
}

/// The browser preview is capped at this width; 4K JPEGs cost more to encode
/// than they show on a laptop screen.
const PREVIEW_MAX_WIDTH: u32 = 1920;

impl Frame {
    pub fn new(pts: f64, width: u32, height: u32, pixels: Pixels) -> Self {
        Frame { pts, width, height, pixels, rgb: OnceLock::new(), preview: OnceLock::new() }
    }

    /// Full-resolution RGB, 3 bytes per pixel, top row first.
    pub fn rgb(&self) -> Option<Arc<Vec<u8>>> {
        self.rgb
            .get_or_init(|| {
                let (w, h) = (self.width as usize, self.height as usize);
                let out = match &self.pixels {
                    Pixels::Jpeg(data) => decode_jpeg(data).map(|(_, _, rgb)| rgb),
                    Pixels::Yuyv(d) => Some(packed422_to_rgb(d, w, h, [0, 1, 2, 3])),
                    Pixels::Uyvy(d) => Some(packed422_to_rgb(d, w, h, [1, 0, 3, 2])),
                    Pixels::Nv12(d) => Some(nv12_to_rgb(d, w, h)),
                    Pixels::Rgb(d) => Some(d.clone()),
                };
                out.filter(|v| v.len() >= w * h * 3).map(Arc::new)
            })
            .clone()
    }

    /// A JPEG for the browser: the camera's own when it sends JPEG, else
    /// encoded at up to 1920 wide.
    pub fn preview_jpeg(&self) -> Option<Bytes> {
        self.preview
            .get_or_init(|| match &self.pixels {
                Pixels::Jpeg(data) => Some(data.clone()),
                _ => {
                    let rgb = self.rgb()?;
                    let (w, h) = fit_width(self.width, self.height, PREVIEW_MAX_WIDTH);
                    let scaled = resize_rgb(&rgb, self.width, self.height, w, h);
                    encode_jpeg(&scaled, w, h, 80).map(Bytes::from)
                }
            })
            .clone()
    }

    /// A full-resolution JPEG, for snapshots.
    pub fn full_jpeg(&self, quality: u8) -> Option<Bytes> {
        match &self.pixels {
            Pixels::Jpeg(data) => Some(data.clone()),
            _ => encode_jpeg(&self.rgb()?, self.width, self.height, quality).map(Bytes::from),
        }
    }
}

/// Width and height scaled down (never up) to at most `max_w` wide.
pub fn fit_width(w: u32, h: u32, max_w: u32) -> (u32, u32) {
    if w <= max_w {
        return (w, h);
    }
    let nh = ((h as u64 * max_w as u64 + w as u64 / 2) / w as u64).max(1) as u32;
    (max_w, nh)
}

pub fn decode_jpeg(data: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    use zune_jpeg::zune_core::{colorspace::ColorSpace, options::DecoderOptions};
    let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGB);
    let mut dec = zune_jpeg::JpegDecoder::new_with_options(data, options);
    let rgb = dec.decode().ok()?;
    let (w, h) = dec.dimensions()?;
    Some((w as u32, h as u32, rgb))
}

pub fn encode_jpeg(rgb: &[u8], w: u32, h: u32, quality: u8) -> Option<Vec<u8>> {
    if w > u16::MAX as u32 || h > u16::MAX as u32 {
        return None;
    }
    let mut out = Vec::with_capacity((w * h / 4) as usize);
    let enc = jpeg_encoder::Encoder::new(&mut out, quality.clamp(1, 100));
    enc.encode(rgb, w as u16, h as u16, jpeg_encoder::ColorType::Rgb).ok()?;
    Some(out)
}

/// The width and height in a JPEG's start-of-frame header, without decoding it.
pub fn jpeg_size(data: &[u8]) -> Option<(u32, u32)> {
    let mut i = 2;
    while i + 9 < data.len() {
        if data[i] != 0xFF {
            return None;
        }
        let marker = data[i + 1];
        let len = u16::from_be_bytes([data[i + 2], data[i + 3]]) as usize;
        if (0xC0..=0xCF).contains(&marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
            let h = u16::from_be_bytes([data[i + 5], data[i + 6]]) as u32;
            let w = u16::from_be_bytes([data[i + 7], data[i + 8]]) as u32;
            return Some((w, h));
        }
        i += 2 + len;
    }
    None
}

#[inline]
fn yuv_to_rgb(y: i32, u: i32, v: i32, out: &mut [u8]) {
    // BT.601 limited range, as webcams send.
    let c = (y - 16).max(0) * 298;
    let d = u - 128;
    let e = v - 128;
    out[0] = ((c + 409 * e + 128) >> 8).clamp(0, 255) as u8;
    out[1] = ((c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255) as u8;
    out[2] = ((c + 516 * d + 128) >> 8).clamp(0, 255) as u8;
}

/// 4:2:2 packed; `order` gives the offsets of Y0, U, Y1, V within each 4 bytes.
fn packed422_to_rgb(d: &[u8], w: usize, h: usize, order: [usize; 4]) -> Vec<u8> {
    let mut out = vec![0u8; w * h * 3];
    let pairs = (w / 2) * h;
    if d.len() < pairs * 4 {
        return out;
    }
    for (p, rgb) in out.chunks_exact_mut(6).take(pairs).enumerate() {
        let s = &d[p * 4..p * 4 + 4];
        let (y0, u, y1, v) = (s[order[0]] as i32, s[order[1]] as i32, s[order[2]] as i32, s[order[3]] as i32);
        let (a, b) = rgb.split_at_mut(3);
        yuv_to_rgb(y0, u, v, a);
        yuv_to_rgb(y1, u, v, b);
    }
    out
}

fn nv12_to_rgb(d: &[u8], w: usize, h: usize) -> Vec<u8> {
    let mut out = vec![0u8; w * h * 3];
    if d.len() < w * h * 3 / 2 {
        return out;
    }
    let (luma, chroma) = d.split_at(w * h);
    for y in 0..h {
        let crow = &chroma[(y / 2) * w..];
        for x in 0..w {
            let u = crow[x & !1] as i32;
            let v = crow[(x & !1) + 1] as i32;
            yuv_to_rgb(luma[y * w + x] as i32, u, v, &mut out[(y * w + x) * 3..]);
        }
    }
    out
}

/// Area-average downscale (or nearest upscale) of packed 3-byte pixels.
pub fn resize_rgb(src: &[u8], sw: u32, sh: u32, dw: u32, dh: u32) -> Vec<u8> {
    if sw == dw && sh == dh {
        return src.to_vec();
    }
    let (sw, sh, dw, dh) = (sw as usize, sh as usize, dw as usize, dh as usize);
    let mut out = vec![0u8; dw * dh * 3];
    for y in 0..dh {
        let y0 = y * sh / dh;
        let y1 = ((y + 1) * sh / dh).max(y0 + 1).min(sh);
        for x in 0..dw {
            let x0 = x * sw / dw;
            let x1 = ((x + 1) * sw / dw).max(x0 + 1).min(sw);
            let mut acc = [0u32; 3];
            for sy in y0..y1 {
                let row = &src[(sy * sw + x0) * 3..(sy * sw + x1) * 3];
                for px in row.chunks_exact(3) {
                    acc[0] += px[0] as u32;
                    acc[1] += px[1] as u32;
                    acc[2] += px[2] as u32;
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as u32;
            let o = &mut out[(y * dw + x) * 3..(y * dw + x) * 3 + 3];
            o[0] = (acc[0] / n) as u8;
            o[1] = (acc[1] / n) as u8;
            o[2] = (acc[2] / n) as u8;
        }
    }
    out
}

/// Scales packed 3-byte pixels to fill dw×dh, cropping the middle of the
/// longer side to keep the aspect ratio.
pub fn cover_rgb(src: &[u8], sw: u32, sh: u32, dw: u32, dh: u32) -> Vec<u8> {
    let (sw, sh) = (sw as u64, sh as u64);
    let (cw, ch) = if sw * dh as u64 > sh * dw as u64 { ((sh * dw as u64 / dh as u64).max(1), sh) } else { (sw, (sw * dh as u64 / dw as u64).max(1)) };
    let (x0, y0) = ((sw - cw) / 2, (sh - ch) / 2);
    let mut crop = Vec::with_capacity((cw * ch * 3) as usize);
    for y in y0..y0 + ch {
        let row = ((y * sw + x0) * 3) as usize;
        crop.extend_from_slice(&src[row..row + (cw * 3) as usize]);
    }
    resize_rgb(&crop, cw as u32, ch as u32, dw, dh)
}

pub fn rgb_to_bgra(rgb: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(rgb.len() / 3 * 4);
    for px in rgb.chunks_exact(3) {
        out.extend_from_slice(&[px[2], px[1], px[0], 255]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jpeg_round_trip_and_size() {
        let (w, h) = (64u32, 48u32);
        let rgb: Vec<u8> = (0..w * h).flat_map(|i| [(i % 256) as u8, 100, 200]).collect();
        let jpeg = encode_jpeg(&rgb, w, h, 90).unwrap();
        assert_eq!(jpeg_size(&jpeg), Some((w, h)));
        let (dw, dh, out) = decode_jpeg(&jpeg).unwrap();
        assert_eq!((dw, dh, out.len()), (w, h, rgb.len()));
    }

    #[test]
    fn yuv_grey_and_colours() {
        // Y=235 white, Y=16 black, U=V=128 neutral.
        let white = packed422_to_rgb(&[235, 128, 235, 128], 2, 1, [0, 1, 2, 3]);
        assert!(white.iter().all(|&c| c >= 254));
        let black = packed422_to_rgb(&[128, 16, 128, 16], 2, 1, [1, 0, 3, 2]);
        assert!(black.iter().all(|&c| c <= 1));
        // Pure red in BT.601: Y=81 U=90 V=240.
        let red = nv12_to_rgb(&[81, 81, 81, 81, 90, 240], 2, 2);
        assert!(red[0] > 240 && red[1] < 15 && red[2] < 15, "{red:?}");
    }

    #[test]
    fn resize_averages() {
        let src = [0, 0, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255];
        assert_eq!(resize_rgb(&src, 2, 2, 1, 1), vec![127, 127, 127]);
        assert_eq!(fit_width(3840, 2160, 1920), (1920, 1080));
        assert_eq!(fit_width(320, 240, 640), (320, 240));
    }

    #[test]
    fn cover_crops_the_middle() {
        // 4×1: red, green, green, blue → 2×1 keeps the green middle.
        let src = [255, 0, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255];
        assert_eq!(cover_rgb(&src, 4, 1, 2, 1), vec![0, 255, 0, 0, 255, 0]);
        // 1×4 → 1×1 likewise.
        assert_eq!(cover_rgb(&src, 1, 4, 1, 1), vec![0, 255, 0]);
    }
}
