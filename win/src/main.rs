//! Windows 贴边壳。界面按 macOS 版的纸色、倾角和扇形节奏画在透明窗口里，
//! 采集在后台线程。macOS 上也能跑起来，用来对质感。

mod sample;

use sample::{kill_pid, Sampler};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tao::dpi::LogicalSize;
#[cfg(not(target_os = "macos"))]
use tao::dpi::LogicalPosition;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::WindowBuilder;
use wry::WebViewBuilder;

const HTML: &str = include_str!("../ui/dock.html");

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Settings {
    edge: String,
    hover_reveals: bool,
    always_shown: bool,
    cards: Vec<String>,
    offset: f64,
    glm_key: String,
    note: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            edge: "right".into(),
            hover_reveals: true,
            always_shown: false,
            cards: ["CPU", "内存", "网络", "磁盘", "I/O", "电池", "智谱", "Java", "进程", "便签"]
                .into_iter()
                .map(str::to_string)
                .collect(),
            offset: 16.0,
            glm_key: String::new(),
            note: String::new(),
        }
    }
}

struct Shared {
    settings: Mutex<Settings>,
    watch: AtomicBool,
    glm: Mutex<Option<sample::Glm>>,
    dock_mode: Mutex<String>,
    zones: Mutex<Zones>,
    hits: Mutex<HitMap>,
}

#[derive(Clone, Copy)]
struct Zone {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

impl Zone {
    fn contains(self, px: f64, py: f64, pad: f64) -> bool {
        self.w > 1.0
            && self.h > 1.0
            && px >= self.x - pad
            && py >= self.y - pad
            && px <= self.x + self.w + pad
            && py <= self.y + self.h + pad
    }
}

#[derive(Clone)]
struct Zones {
    pill: Zone,
    /// 扇形热区：贴边 70pt、跟窗口一样高。离开它才收起，不看整条透明窗。
    open: Zone,
    frame: Zone,
    strip: bool,
}

impl Default for Zones {
    fn default() -> Self {
        Self {
            pill: Zone { x: 0.0, y: 0.0, w: 0.0, h: 0.0 },
            open: Zone { x: 0.0, y: 0.0, w: 0.0, h: 0.0 },
            frame: Zone { x: 0.0, y: 0.0, w: 0.0, h: 0.0 },
            strip: false,
        }
    }
}

#[derive(Clone, Default)]
struct HitMap {
    cards: Vec<CardHit>,
    cog: Option<BoxHit>,
    panel: Option<BoxHit>,
}

enum UserEvent {
    Sample(String),
    Ipc(String),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Ipc {
    cmd: String,
    w: Option<f64>,
    h: Option<f64>,
    pin: Option<String>,
    pill_h: Option<f64>,
    watch: Option<bool>,
    pid: Option<u32>,
    offset: Option<f64>,
    settings: Option<Settings>,
    note: Option<String>,
    mode: Option<String>,
    cards: Option<Vec<CardHit>>,
    cog: Option<BoxHit>,
    panel: Option<BoxHit>,
}

#[derive(Clone, Deserialize)]
struct CardHit {
    kind: String,
    top: f64,
    bottom: f64,
    left: f64,
    right: f64,
}

#[derive(Clone, Deserialize)]
struct BoxHit {
    top: f64,
    bottom: f64,
    left: f64,
    right: f64,
}

fn main() {
    let shared = Arc::new(Shared {
        settings: Mutex::new(load_settings()),
        watch: AtomicBool::new(false),
        glm: Mutex::new(None),
        dock_mode: Mutex::new("rest".into()),
        zones: Mutex::new(Zones::default()),
        hits: Mutex::new(HitMap::default()),
    });

    let mut event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    #[cfg(target_os = "macos")]
    {
        use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
        event_loop.set_activation_policy(ActivationPolicy::Accessory);
    }

    let proxy = event_loop.create_proxy();
    let sampler_shared = Arc::clone(&shared);
    let sampler_proxy = proxy.clone();
    thread::spawn(move || {
        let mut sampler = Sampler::new();
        loop {
            let settings = sampler_shared.settings.lock().unwrap().clone();
            let glm = sampler_shared.glm.lock().unwrap().clone();
            let watch = sampler_shared.watch.load(Ordering::Relaxed);
            let snap = sampler.take(watch, glm, &settings.cards);
            if let Ok(json) = serde_json::to_string(&snap) {
                let _ = sampler_proxy.send_event(UserEvent::Sample(json));
            }
            thread::sleep(Duration::from_secs(1));
        }
    });

    let glm_shared = Arc::clone(&shared);
    thread::spawn(move || {
        let mut last = String::new();
        let mut ticks = 60u32;
        loop {
            let key = glm_shared.settings.lock().unwrap().glm_key.clone();
            if key != last || ticks >= 60 {
                last = key.clone();
                ticks = 0;
                let next = if key.trim().is_empty() { None } else { Some(sample::fetch_glm(&key)) };
                *glm_shared.glm.lock().unwrap() = next;
            }
            ticks += 1;
            thread::sleep(Duration::from_secs(1));
        }
    });

    let ipc_proxy = proxy.clone();
    let mut builder = WindowBuilder::new()
        .with_title("SysMon")
        .with_decorations(false)
        .with_transparent(true)
        .with_always_on_top(true)
        .with_resizable(false)
        .with_visible(false)
        .with_inner_size(LogicalSize::new(14.0, 180.0));
    #[cfg(target_os = "windows")]
    {
        use tao::platform::windows::WindowBuilderExtWindows;
        builder = builder.with_skip_taskbar(true).with_undecorated_shadow(false);
    }
    #[cfg(target_os = "macos")]
    {
        use tao::platform::macos::WindowBuilderExtMacOS;
        builder = builder.with_has_shadow(false);
    }
    let window = builder.build(&event_loop).expect("创建贴边窗口失败");
    #[cfg(target_os = "windows")]
    disarm_activation(&window);

    let webview = WebViewBuilder::new()
        .with_transparent(true)
        .with_html(HTML)
        .with_ipc_handler(move |req| {
            let _ = ipc_proxy.send_event(UserEvent::Ipc(req.body().clone()));
        })
        .build(&window)
        .expect("创建界面失败");

    let shared_loop = shared;
    let mut outside_for = Duration::ZERO;
    let mut last_cursor = Instant::now();
    let mut last_hover = String::new();
    let mut hover_ready = false;
    let mut ignoring = false;
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::WaitUntil(Instant::now() + Duration::from_millis(32));
        if last_cursor.elapsed() >= Duration::from_millis(32) {
            last_cursor = Instant::now();
            let mode = shared_loop.dock_mode.lock().unwrap().clone();
            let always = shared_loop.settings.lock().unwrap().always_shown;
            let zones = shared_loop.zones.lock().unwrap().clone();
            let hits = shared_loop.hits.lock().unwrap().clone();
            let cursor = cursor_logical(&window);
            let on_pill = cursor.map(|(x, y)| zones.pill.contains(x, y, 6.0)).unwrap_or(false);
            let on_hot = cursor.map(|(x, y)| zones.open.contains(x, y, 8.0)).unwrap_or(false);
            let local = cursor.map(|(x, y)| (x - zones.frame.x, y - zones.frame.y));
            let hover = local.as_ref().and_then(|(lx, ly)| {
                if !zones.strip {
                    return None;
                }
                hits.cards.iter().rev().find(|card| {
                    in_box(*lx, *ly, card.left, card.right, card.top, card.bottom)
                }).map(|card| card.kind.clone())
            });
            let on_panel = local
                .as_ref()
                .and_then(|(lx, ly)| {
                    hits.panel.as_ref().map(|panel| {
                        in_box(*lx, *ly, panel.left, panel.right, panel.top, panel.bottom)
                    })
                })
                .unwrap_or(false);
            // 扇形窗口比热区宽。空白穿透；详情面板在热区外侧，得点得着。
            // 卡片缝在热区里面，不要来回开关穿透，否则会触发展开/收回。
            let want_ignore = zones.strip && !on_hot && !on_pill && !on_panel;
            if want_ignore != ignoring {
                ignoring = want_ignore;
                let _ = window.set_ignore_cursor_events(want_ignore);
            }
            let hover_key = hover.clone().unwrap_or_default();
            if !hover_ready || hover_key != last_hover {
                hover_ready = true;
                last_hover = hover_key;
                let js = match &hover {
                    Some(kind) => format!(
                        "window.setHover && window.setHover({})",
                        serde_json::to_string(kind).unwrap_or_else(|_| "null".into())
                    ),
                    None => "window.setHover && window.setHover(null)".into(),
                };
                let _ = webview.evaluate_script(&js);
            }
            match mode.as_str() {
                "rest" | "menu" if on_pill => {
                    outside_for = Duration::ZERO;
                    *shared_loop.dock_mode.lock().unwrap() = "fan".into();
                    let _ = webview.evaluate_script("window.forceFan && window.forceFan()");
                }
                "closing" if on_hot => {
                    outside_for = Duration::ZERO;
                    *shared_loop.dock_mode.lock().unwrap() = "fan".into();
                    let _ = webview.evaluate_script("window.forceFan && window.forceFan()");
                }
                "fan" | "peek" if !always && zones.open.w > 1.0 && !on_hot => {
                    outside_for += Duration::from_millis(32);
                    if outside_for >= Duration::from_millis(160) {
                        outside_for = Duration::ZERO;
                        *shared_loop.dock_mode.lock().unwrap() = "closing".into();
                        let _ = webview.evaluate_script("window.forceRest && window.forceRest()");
                    }
                }
                _ => outside_for = Duration::ZERO,
            }
        }
        match event {
            Event::UserEvent(UserEvent::Sample(json)) => {
                let _ = webview.evaluate_script(&format!("window.onSample({json})"));
            }
            Event::UserEvent(UserEvent::Ipc(body)) => {
                handle_ipc(&window, &shared_loop, &webview, &body);
            }
            Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => {
                *control_flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}

fn handle_ipc(window: &tao::window::Window, shared: &Shared, webview: &wry::WebView, body: &str) {
    let Ok(msg) = serde_json::from_str::<Ipc>(body) else { return };
    match msg.cmd.as_str() {
        "ready" => {
            let settings = shared.settings.lock().unwrap().clone();
            if let Ok(json) = serde_json::to_string(&settings) {
                let _ = webview.evaluate_script(&format!("window.onSettings({json})"));
            }
        }
        "place" => {
            let settings = shared.settings.lock().unwrap();
            place(window, shared, &settings, msg.w.unwrap_or(14.0), msg.h.unwrap_or(180.0), msg.pin.as_deref().unwrap_or("bottom"), msg.pill_h.unwrap_or(180.0));
        }
        "settings" => {
            if let Some(next) = msg.settings {
                let mut guard = shared.settings.lock().unwrap();
                *guard = next;
                let saved = guard.clone();
                drop(guard);
                save_settings(&saved);
                if let Ok(json) = serde_json::to_string(&saved) {
                    let _ = webview.evaluate_script(&format!("window.onSettings({json})"));
                }
            }
        }
        "note" => {
            if let Some(text) = msg.note {
                let mut guard = shared.settings.lock().unwrap();
                guard.note = text;
                let saved = guard.clone();
                drop(guard);
                save_settings(&saved);
            }
        }
        "offset" => {
            if let Some(offset) = msg.offset {
                let mut guard = shared.settings.lock().unwrap();
                guard.offset = offset.clamp(0.0, 4000.0);
                let saved = guard.clone();
                drop(guard);
                save_settings(&saved);
            }
        }
        "watch" => shared.watch.store(msg.watch.unwrap_or(false), Ordering::Relaxed),
        "mode" => {
            if let Some(mode) = msg.mode {
                *shared.dock_mode.lock().unwrap() = mode;
            }
        }
        "hits" => {
            *shared.hits.lock().unwrap() = HitMap {
                cards: msg.cards.unwrap_or_default(),
                cog: msg.cog,
                panel: msg.panel,
            };
        }
        "kill" => {
            if let Some(pid) = msg.pid {
                let ok = kill_pid(pid);
                let _ = webview.evaluate_script(&format!("window.onKill({ok})"));
            }
        }
        "quit" => std::process::exit(0),
        _ => {}
    }
}

#[derive(Clone, Copy)]
struct Rect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

impl Rect {
    fn right(&self) -> f64 { self.x + self.w }
    fn bottom(&self) -> f64 { self.y + self.h }
}

fn cursor_logical(window: &tao::window::Window) -> Option<(f64, f64)> {
    #[cfg(target_os = "macos")]
    {
        // 全局坐标是主屏左上角为原点的 point，和贴边窗口同一套。
        // tao 的 cursor_position 在 Retina 上把像素高度和 point 混在一起，悬停会对不准。
        let _ = window;
        let source = core_graphics::event_source::CGEventSource::new(
            core_graphics::event_source::CGEventSourceStateID::CombinedSessionState,
        )
        .ok()?;
        let event = core_graphics::event::CGEvent::new(source).ok()?;
        let point = event.location();
        return Some((point.x, point.y));
    }
    #[cfg(not(target_os = "macos"))]
    {
        let cursor = window.cursor_position().ok()?;
        let scale = window.scale_factor().max(1.0);
        Some((cursor.x / scale, cursor.y / scale))
    }
}

fn in_box(x: f64, y: f64, left: f64, right: f64, top: f64, bottom: f64) -> bool {
    x >= left && x <= right && y >= top && y <= bottom
}

fn place(window: &tao::window::Window, shared: &Shared, settings: &Settings, w: f64, h: f64, pin: &str, pill_h: f64) {
    let (_full, work) = screen_of(window);
    let w = w.max(8.0);
    let strip = pin == "strip";
    // 扇形和详情同一条贴边窗口，高度是整段可见区。换面板不再改窗口。
    let (x, y, h) = if strip {
        let h = work.h.max(8.0);
        let x = if settings.edge == "left" { work.x } else { work.right() - w };
        (x, work.y, h)
    } else {
        let h = h.max(8.0);
        let y = (work.bottom() - settings.offset - h).max(work.y);
        let x = if settings.edge == "left" { work.x } else { work.right() - w };
        (x, y, h)
    };
    {
        let mut zones = shared.zones.lock().unwrap();
        zones.frame = Zone { x, y, w, h };
        // 展开后的窗口比卡片宽。热区只留贴边那一条，空白穿透，否则光标
        // 在透明区里也被当成还在扇形上，卡片收不回去。
        let open = w > 40.0;
        zones.strip = open;
        if open {
            // 热区只贴边 70pt。窗口为了面板预先加宽，空白不能算还在扇形里。
            let depth = 70.0_f64.min(w);
            let open_x = if settings.edge == "left" { x } else { x + w - depth };
            zones.open = Zone { x: open_x, y, w: depth, h };
            let pill_h = pill_h.max(14.0);
            let pill_y = (y + h - pill_h).max(y);
            zones.pill = Zone {
                x: if settings.edge == "left" { x } else { x + w - 14.0 },
                y: pill_y,
                w: 14.0,
                h: pill_h,
            };
        } else {
            zones.pill = Zone { x, y, w, h };
            zones.open = Zone { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
        }
    }
    let key = (
        x.round() as i32,
        y.round() as i32,
        w.round() as i32,
        h.round() as i32,
    );
    {
        static LAST: std::sync::OnceLock<Mutex<(i32, i32, i32, i32)>> = std::sync::OnceLock::new();
        let last = LAST.get_or_init(|| Mutex::new((0, 0, 0, 0)));
        let mut guard = last.lock().unwrap();
        if *guard == key {
            return;
        }
        *guard = key;
    }
    #[cfg(target_os = "macos")]
    set_mac_frame(window, x, y, w, h);
    #[cfg(not(target_os = "macos"))]
    {
        window.set_outer_position(LogicalPosition::new(x, y));
        window.set_inner_size(LogicalSize::new(w, h));
    }
    window.set_visible(true);
}

#[cfg(target_os = "macos")]
fn set_mac_frame(window: &tao::window::Window, x: f64, y: f64, w: f64, h: f64) {
    use objc2::MainThreadMarker;
    use objc2_app_kit::{NSScreen, NSWindow};
    use objc2_foundation::NSRect;
    use tao::platform::macos::WindowExtMacOS;

    let Some(mtm) = MainThreadMarker::new() else { return };
    let Some(screen) = NSScreen::mainScreen(mtm) else { return };
    let frame = screen.frame();
    let top = frame.origin.y + frame.size.height;
    let raw = window.ns_window() as *mut NSWindow;
    if raw.is_null() {
        return;
    }
    let rect = NSRect::new(
        objc2_foundation::NSPoint::new(x, top - y - h),
        objc2_foundation::NSSize::new(w, h),
    );
    let ns = unsafe { &*raw };
    ns.setOpaque(false);
    if let Some(color) = clear_color() {
        ns.setBackgroundColor(Some(color));
    }
    // 改尺寸时先藏起来再摆好。网页视图在变高时会先铺一块不透明底，
    // 那一块从右缘穿过屏幕中部，然后才变透明。
    ns.orderOut(None);
    ns.setFrame_display(rect, true);
    ns.orderFrontRegardless();
}

#[cfg(target_os = "macos")]
fn clear_color() -> Option<&'static objc2_app_kit::NSColor> {
    unsafe {
        objc2::msg_send![
            objc2::class!(NSColor),
            clearColor
        ]
    }
}

fn screen_of(window: &tao::window::Window) -> (Rect, Rect) {
    #[cfg(target_os = "macos")]
    {
        let _ = window;
        return mac_screen();
    }
    #[cfg(not(target_os = "macos"))]
    {
        screen_of_tao(window)
    }
}

#[cfg(target_os = "macos")]
fn mac_screen() -> (Rect, Rect) {
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSScreen;
    let fallback = (
        Rect { x: 0.0, y: 0.0, w: 1470.0, h: 956.0 },
        Rect { x: 0.0, y: 34.0, w: 1470.0, h: 876.0 },
    );
    let Some(mtm) = MainThreadMarker::new() else { return fallback };
    let Some(screen) = NSScreen::mainScreen(mtm) else { return fallback };
    let frame = screen.frame();
    let visible = screen.visibleFrame();
    let full = Rect {
        x: frame.origin.x,
        y: 0.0,
        w: frame.size.width,
        h: frame.size.height,
    };
    let top = frame.origin.y + frame.size.height - (visible.origin.y + visible.size.height);
    let work = Rect {
        x: visible.origin.x,
        y: top,
        w: visible.size.width,
        h: visible.size.height,
    };
    (full, work)
}

#[cfg(not(target_os = "macos"))]
fn screen_of_tao(window: &tao::window::Window) -> (Rect, Rect) {
    let monitor = window.current_monitor().or_else(|| window.available_monitors().next());
    let Some(monitor) = monitor else {
        return (Rect { x: 0.0, y: 0.0, w: 1440.0, h: 900.0 }, Rect { x: 0.0, y: 32.0, w: 1440.0, h: 790.0 });
    };
    let scale = monitor.scale_factor();
    let pos = monitor.position();
    let size = monitor.size();
    let full = Rect {
        x: pos.x as f64 / scale,
        y: pos.y as f64 / scale,
        w: size.width as f64 / scale,
        h: size.height as f64 / scale,
    };
    #[cfg(windows)]
    if let Some(work) = windows_work_area(&window, scale) {
        return (full, work);
    }
    let mut work = full;
    work.y += 32.0;
    work.h = (work.h - 32.0 - 78.0).max(240.0);
    let _ = window;
    (full, work)
}

#[cfg(windows)]
fn windows_work_area(window: &tao::window::Window, scale: f64) -> Option<Rect> {
    use tao::platform::windows::WindowExtWindows;
    #[repr(C)]
    struct WinRect { left: i32, top: i32, right: i32, bottom: i32 }
    #[repr(C)]
    struct MonitorInfo {
        cb_size: u32,
        monitor: WinRect,
        work: WinRect,
        flags: u32,
    }
    extern "system" {
        fn MonitorFromWindow(hwnd: isize, flags: u32) -> isize;
        fn GetMonitorInfoW(monitor: isize, info: *mut MonitorInfo) -> i32;
    }
    let hwnd = window.hwnd();
    let monitor = unsafe { MonitorFromWindow(hwnd, 2) };
    if monitor == 0 { return None; }
    let mut info = MonitorInfo {
        cb_size: std::mem::size_of::<MonitorInfo>() as u32,
        monitor: WinRect { left: 0, top: 0, right: 0, bottom: 0 },
        work: WinRect { left: 0, top: 0, right: 0, bottom: 0 },
        flags: 0,
    };
    if unsafe { GetMonitorInfoW(monitor, &mut info) } == 0 { return None; }
    Some(Rect {
        x: info.work.left as f64 / scale,
        y: info.work.top as f64 / scale,
        w: (info.work.right - info.work.left) as f64 / scale,
        h: (info.work.bottom - info.work.top) as f64 / scale,
    })
}

#[cfg(windows)]
fn disarm_activation(window: &tao::window::Window) {
    use tao::platform::windows::WindowExtWindows;
    const GWL_EXSTYLE: i32 = -20;
    const WS_EX_TOOLWINDOW: isize = 0x0000_0080;
    const WS_EX_NOACTIVATE: isize = 0x0800_0000;
    extern "system" {
        fn GetWindowLongPtrW(hwnd: isize, index: i32) -> isize;
        fn SetWindowLongPtrW(hwnd: isize, index: i32, value: isize) -> isize;
    }
    let hwnd = window.hwnd();
    unsafe {
        let style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
    }
}

fn config_path() -> PathBuf {
    #[cfg(windows)]
    let base = std::env::var("APPDATA").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."));
    #[cfg(target_os = "macos")]
    let base = std::env::var("HOME")
        .map(|h| PathBuf::from(h).join("Library/Application Support"))
        .unwrap_or_else(|_| PathBuf::from("."));
    #[cfg(not(any(windows, target_os = "macos")))]
    let base = PathBuf::from(".");
    base.join("SysMon").join("windows-settings.json")
}

fn load_settings() -> Settings {
    let path = config_path();
    let mut settings: Settings = fs::read_to_string(&path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default();
    if settings.edge != "left" && settings.edge != "right" {
        settings.edge = "right".into();
    }
    settings
}

fn save_settings(settings: &Settings) {
    let path = config_path();
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string_pretty(settings) {
        let _ = fs::write(path, text);
    }
}
