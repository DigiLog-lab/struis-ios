use std::alloc::{GlobalAlloc, Layout, System};
use std::io::Cursor;
use std::sync::atomic::{AtomicUsize, Ordering};
use image::{ImageFormat, ImageReader};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;

// Cold-cache test shim: production cache and hashing are checked structurally.
struct ColdCache;
static ORIGINAL_IMAGE_ESTIMATE_CACHE: ColdCache = ColdCache;
impl ColdCache {
    fn get_or_insert_with(&self, _key: [u8; 20], operation: impl FnOnce() -> Option<i64>) -> Option<i64> { operation() }
}
fn sha1_digest(_bytes: &[u8]) -> [u8; 20] { [0; 20] }
include!("generated_estimator.rs");

struct Counting;
static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

fn add(bytes: usize) {
    let live = LIVE.fetch_add(bytes, Ordering::Relaxed) + bytes;
    PEAK.fetch_max(live, Ordering::Relaxed);
}
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let pointer = unsafe { System.alloc(layout) };
        if !pointer.is_null() { add(layout.size()); }
        pointer
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let pointer = unsafe { System.alloc_zeroed(layout) };
        if !pointer.is_null() { add(layout.size()); }
        pointer
    }
    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { System.dealloc(pointer, layout); }
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
    }
    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        let replacement = unsafe { System.realloc(pointer, layout, size) };
        if !replacement.is_null() {
            LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
            add(size);
        }
        replacement
    }
}
#[global_allocator]
static ALLOCATOR: Counting = Counting;

fn full(bytes: &[u8]) -> Option<(u32, u32)> {
    image::load_from_memory(bytes).ok().map(|image| (image.width(), image.height()))
}

fn header(bytes: &[u8]) -> Option<(u32, u32)> {
    ImageReader::new(Cursor::new(bytes)).with_guessed_format().ok()?.into_dimensions().ok()
}

fn estimate(dimensions: Option<(u32, u32)>) -> Option<i64> {
    dimensions.map(|(width, height)| {
        let patches_wide = i64::from(width).saturating_add(31) / 32;
        let patches_high = i64::from(height).saturating_add(31) / 32;
        let count = usize::try_from(patches_wide.saturating_mul(patches_high)).unwrap_or(usize::MAX).min(10_000);
        i64::try_from(count.saturating_mul(4)).unwrap_or(i64::MAX)
    })
}

fn measure(bytes: &[u8], decoder: fn(&[u8]) -> Option<(u32, u32)>) -> (Option<(u32, u32)>, usize) {
    let baseline = LIVE.load(Ordering::Relaxed);
    PEAK.store(baseline, Ordering::Relaxed);
    let dimensions = decoder(bytes);
    let peak = PEAK.load(Ordering::Relaxed).saturating_sub(baseline);
    (dimensions, peak)
}

fn encoded(width: u32, height: u32, format: ImageFormat) -> Vec<u8> {
    let image = image::RgbImage::from_fn(width, height, |x, y| {
        image::Rgb([(x % 251) as u8, (y % 239) as u8, ((x / 8 + y / 8) % 227) as u8])
    });
    let mut buffer = Cursor::new(Vec::new());
    image::DynamicImage::ImageRgb8(image).write_to(&mut buffer, format).unwrap();
    buffer.into_inner()
}

fn main() {
    // Synthetic data only. Construction is outside the measured allocation window.
    for (format, width, height) in [(ImageFormat::Jpeg, 6000, 4000), (ImageFormat::Png, 1601, 901), (ImageFormat::WebP, 1601, 901)] {
        let bytes = encoded(width, height, format);
        let url = format!("data:image/{};base64,{}", match format { ImageFormat::Jpeg => "jpeg", ImageFormat::Png => "png", _ => "webp" }, BASE64_STANDARD.encode(&bytes));
        let actual = estimate_original_image_bytes(&url);
        let reference = reference_estimate_original_image_bytes(&url);
        assert_eq!(actual, reference);
        assert_eq!(actual, estimate(Some((width, height))));
        let (old, old_peak) = measure(&bytes, full);
        let (new, new_peak) = measure(&bytes, header);
        assert_eq!(old, Some((width, height)));
        assert_eq!(new, old);
        assert_eq!(estimate(old), estimate(new));
        if format == ImageFormat::Jpeg { assert!(new_peak < old_peak / 10); }
        println!("PASS format={format:?} dimensions={width}x{height} compressed_bytes={} full_incremental_peak_bytes={old_peak} header_incremental_peak_bytes={new_peak} estimated_bytes={}", bytes.len(), estimate(new).unwrap());
        if format == ImageFormat::Jpeg {
            let short = &bytes[..bytes.len() / 2];
            println!("INFO truncated_jpeg full_dimensions_present={} header_dimensions_present={} (estimator behavior only)", full(short).is_some(), header(short).is_some());
        }
    }
    for bytes in [&b""[..], &b"invalid synthetic image"[..], &[0xff, 0xd8, 0xff][..]] {
        let url = format!("data:image/jpeg;base64,{}", BASE64_STANDARD.encode(bytes));
        assert!(estimate_original_image_bytes(&url).is_none());
        assert!(reference_estimate_original_image_bytes(&url).is_none());
        assert!(full(bytes).is_none());
        assert!(header(bytes).is_none());
    }
    assert!(estimate_original_image_bytes("data:image/jpeg;base64,@@@").is_none());
    assert!(estimate_original_image_bytes("https://invalid.example/image.jpg").is_none());
    println!("PASS compiled actual generated estimator cfg={} valid JPEG/PNG/WebP formula parity and invalid-header/base64/data-URL fallback", if cfg!(target_os = "ios") { "ios-host-probe" } else { "non-ios-host" });
    println!("INFO allocator windows compare dimension extraction only; actual estimator parity runs separately with real base64 and cold-cache shim");
    println!("PASS unrecognized/invalid header returns None for existing resized-image estimate fallback");
    println!("LIMIT allocator requested-byte peaks on Linux; excludes common base64/input storage and allocator overhead; no iOS footprint/jetsam measurement");
}
