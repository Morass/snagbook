// Ported one for one from the macOS app's CaptureMathTests.
use snagbook_core::capture_math::*;

#[test]
fn output_size_is_even_and_capped() {
    assert_eq!(output_size(5120.0, 2880.0, 1920), (1920, 1080));
    assert_eq!(output_size(801.0, 601.0, 1920), (800, 600));
    assert_eq!(output_size(1.0, 1.0, 1920), (2, 2));
}

#[test]
fn stills() {
    assert_eq!(still_times(3.5, 60), [0.0, 1.0, 2.0, 3.0]);
    assert_eq!(still_times(3.0, 60), [0.0, 1.0, 2.0, 2.95]);
    let long = still_times(600.0, 60);
    assert_eq!(long.len(), 60);
    assert_eq!(long[0], 0.0);
    assert!((long[59] - 599.95).abs() < 1e-9);
    assert_eq!(still_times(0.4, 60), [0.0]);
    assert!(still_times(10.0, 0).is_empty());
}

#[test]
fn sheet_and_grid() {
    assert_eq!(sheet_times(60.0, 16).len(), 16);
    assert_eq!(sheet_times(1.0, 16).len(), 3);
    assert_eq!(grid(16), (4, 4));
    assert_eq!(grid(3), (2, 2));
    assert_eq!(grid(5), (3, 2));
}

#[test]
fn stamps() {
    assert_eq!(stamp(7.46), "0:07.5");
    assert_eq!(stamp(3723.0), "1:02:03.0");
    assert_eq!(duration(65.4), "1:05");
}
