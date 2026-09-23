//! Windows（以及本机预览）上的采样。系统 CPU 是全核聚合 0–100，
//! 进程 CPU 与活动监视器一致：100% = 一颗核跑满。

use serde::Serialize;
use std::collections::HashMap;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use sysinfo::{Disks, Networks, Pid, ProcessesToUpdate, System, Users};

const HISTORY: usize = 150;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Volume {
    pub name: String,
    pub mount: String,
    pub total: u64,
    pub free: u64,
}

#[derive(Clone, Serialize)]
pub struct Addr {
    pub name: String,
    pub ip: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Battery {
    pub percent: f64,
    pub charging: bool,
    pub on_ac: bool,
    pub minutes: Option<i32>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcRow {
    pub pid: u32,
    pub name: String,
    pub display_name: String,
    pub user: String,
    pub cpu: f64,
    pub memory: u64,
    pub threads: u32,
    pub mine: bool,
    pub java: bool,
    pub java_label: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Digest {
    pub count: u32,
    pub java_count: u32,
    pub java_memory: u64,
    pub java_cpu: f64,
    pub dominant_name: Option<String>,
    pub dominant_cpu: f64,
    pub busiest_name: Option<String>,
}

#[derive(Clone, Serialize)]
pub struct Dash {
    pub cpu: f64,
    pub memory: f64,
    pub network: f64,
    pub disk: f64,
    pub io: f64,
    pub battery: f64,
    pub glm: f64,
    pub java: f64,
    pub processes: f64,
    pub note: f64,
}

#[derive(Clone, Serialize)]
pub struct GlmWindow {
    pub label: String,
    pub used: f64,
    pub remaining: f64,
    pub extra: Option<String>,
    pub five_hour: bool,
}

#[derive(Clone, Serialize)]
pub struct Glm {
    pub level: Option<String>,
    pub error: Option<String>,
    pub windows: Vec<GlmWindow>,
    pub five_remaining: Option<f64>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub cpu: f64,
    pub cores: u32,
    pub uptime_sec: u64,
    pub load1: f64,
    pub mem_used: u64,
    pub mem_total: u64,
    pub mem_free: u64,
    pub mem_avail: u64,
    pub swap_used: u64,
    pub swap_total: u64,
    pub net_in: f64,
    pub net_out: f64,
    pub ips: Vec<Addr>,
    pub volumes: Vec<Volume>,
    pub io_read: f64,
    pub io_write: f64,
    pub io_read_total: u64,
    pub io_write_total: u64,
    pub battery: Option<Battery>,
    pub has_battery: bool,
    pub cpu_hist: Vec<f64>,
    pub mem_hist: Vec<f64>,
    pub net_down_hist: Vec<f64>,
    pub net_up_hist: Vec<f64>,
    pub io_read_hist: Vec<f64>,
    pub io_write_hist: Vec<f64>,
    pub digest: Digest,
    pub dash: Dash,
    pub attention: Option<String>,
    pub peak: Option<String>,
    pub processes: Option<Vec<ProcRow>>,
    pub glm: Option<Glm>,
}

pub struct Sampler {
    sys: System,
    nets: Networks,
    disks: Disks,
    users: Users,
    last_net: HashMap<String, (u64, u64)>,
    last_net_at: Option<Instant>,
    cpu_hist: Vec<f64>,
    mem_hist: Vec<f64>,
    down_hist: Vec<f64>,
    up_hist: Vec<f64>,
    io_r_hist: Vec<f64>,
    io_w_hist: Vec<f64>,
    attention: Attention,
    load: f64,
    battery_at: Option<Instant>,
    battery: Option<Battery>,
    slow_at: Option<Instant>,
    volumes: Vec<Volume>,
    ips: Vec<Addr>,
    latched: Option<String>,
    peak_cpu: f64,
    peak_name: Option<String>,
    peak_at: u64,
    peak_day: String,
}

impl Sampler {
    pub fn new() -> Self {
        let mut sys = System::new_all();
        sys.refresh_cpu_usage();
        sys.refresh_memory();
        std::thread::sleep(sysinfo::MINIMUM_CPU_UPDATE_INTERVAL);
        sys.refresh_cpu_usage();
        Self {
            sys,
            nets: Networks::new_with_refreshed_list(),
            disks: Disks::new_with_refreshed_list(),
            users: Users::new_with_refreshed_list(),
            last_net: HashMap::new(),
            last_net_at: None,
            cpu_hist: Vec::new(),
            mem_hist: Vec::new(),
            down_hist: Vec::new(),
            up_hist: Vec::new(),
            io_r_hist: Vec::new(),
            io_w_hist: Vec::new(),
            attention: Attention::default(),
            load: 0.0,
            battery_at: None,
            battery: None,
            slow_at: None,
            volumes: Vec::new(),
            ips: Vec::new(),
            latched: None,
            peak_cpu: 0.0,
            peak_name: None,
            peak_at: 0,
            peak_day: String::new(),
        }
    }

    pub fn take(&mut self, watch_procs: bool, glm: Option<Glm>, cards: &[String]) -> Snapshot {
        self.sys.refresh_cpu_usage();
        self.sys.refresh_memory();
        self.sys.refresh_processes(ProcessesToUpdate::All, true);
        let now = Instant::now();
        let cpu = self.sys.global_cpu_usage() as f64;
        let cores = self.sys.cpus().len().max(1) as u32;
        let alpha = 1.0 - (-1.0_f64 / 60.0).exp();
        let instant_load = (cpu / 100.0) * cores as f64;
        self.load = if self.load == 0.0 {
            instant_load
        } else {
            self.load * (1.0 - alpha) + instant_load * alpha
        };

        let (net_in, net_out) = self.network(now);
        if self.battery_at.map(|t| t.elapsed() >= Duration::from_secs(10)).unwrap_or(true) {
            self.battery = read_battery();
            self.battery_at = Some(now);
        }
        self.disks.refresh(true);
        let (io_read, io_write, io_read_total, io_write_total) = disk_io(&self.disks);
        if self.slow_at.map(|t| t.elapsed() >= Duration::from_secs(30)).unwrap_or(true) {
            self.volumes = read_volumes(&self.disks);
            self.ips = read_ips();
            self.slow_at = Some(now);
        }

        let me = std::env::var("USER")
            .or_else(|_| std::env::var("USERNAME"))
            .unwrap_or_default();
        let mut rows = Vec::new();
        let mut digest = Digest {
            count: 0,
            java_count: 0,
            java_memory: 0,
            java_cpu: 0.0,
            dominant_name: None,
            dominant_cpu: 0.0,
            busiest_name: None,
        };
        let mut ranked: Vec<(String, f64)> = Vec::new();
        for proc in self.sys.processes().values() {
            let pid = proc.pid().as_u32();
            if pid == 0 {
                continue;
            }
            let comm = proc.name().to_string_lossy().to_string();
            if comm.is_empty() {
                continue;
            }
            digest.count += 1;
            let exe = proc.exe().map(|p| p.to_path_buf());
            let cmd: Vec<String> = proc.cmd().iter().map(|s| s.to_string_lossy().to_string()).collect();
            let base = exe
                .as_ref()
                .and_then(|p| p.file_name())
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| comm.clone());
            let is_java = base.eq_ignore_ascii_case("java") || base.eq_ignore_ascii_case("java.exe");
            let is_script = is_script_runtime(&base);
            let java_label = if is_java { java_label(&cmd) } else { None };
            let script = if is_script { script_label(&cmd) } else { None };
            let display = if is_java {
                java_label.clone().unwrap_or_else(|| pretty_name(exe.as_deref(), &comm))
            } else if let Some(script) = script.clone() {
                script
            } else {
                pretty_name(exe.as_deref(), &comm)
            };
            let cpu_p = proc.cpu_usage() as f64;
            let memory = proc.memory();
            if is_java {
                digest.java_count += 1;
                digest.java_memory += memory;
                digest.java_cpu += cpu_p;
            }
            let user = proc
                .user_id()
                .and_then(|id| self.users.get_user_by_id(id))
                .map(|u| u.name().to_string())
                .unwrap_or_default();
            if !is_noise(&comm) && !is_noise(&display) {
                ranked.push((display.clone(), cpu_p));
            }
            if watch_procs {
                rows.push(ProcRow {
                    pid,
                    name: comm,
                    display_name: display,
                    user: user.clone(),
                    cpu: cpu_p,
                    memory,
                    threads: 0,
                    mine: !me.is_empty() && user.eq_ignore_ascii_case(&me),
                    java: is_java,
                    java_label,
                });
            }
        }
        ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        if let Some((name, cpu_p)) = ranked.first() {
            if *cpu_p > 0.0 {
                digest.busiest_name = Some(name.clone());
            }
        }
        let top = ranked.first();
        let second = ranked.get(1).map(|r| r.1).unwrap_or(0.0);
        let chosen = if let Some(latched) = &self.latched {
            ranked.iter().find(|(n, c)| n == latched && *c >= 50.0 && (top.map(|(n, _)| n == latched).unwrap_or(false) || *c >= top.map(|t| t.1).unwrap_or(0.0) * 0.75)).cloned()
        } else {
            None
        };
        let chosen = chosen.or_else(|| {
            top.filter(|(_, c)| *c >= 50.0 && *c >= second.max(0.1) * 1.8).cloned()
        });
        self.latched = chosen.as_ref().map(|(n, _)| n.clone());
        if let Some((name, cpu_p)) = chosen {
            digest.dominant_name = card_token(&name);
            digest.dominant_cpu = cpu_p;
        }

        push(&mut self.cpu_hist, cpu);
        push(&mut self.mem_hist, self.sys.used_memory() as f64 / 1_073_741_824.0);
        push(&mut self.down_hist, net_in);
        push(&mut self.up_hist, net_out);
        push(&mut self.io_r_hist, io_read);
        push(&mut self.io_w_hist, io_write);

        let day = day_key();
        if day != self.peak_day {
            self.peak_day = day;
            self.peak_cpu = 0.0;
            self.peak_name = None;
        }
        if cpu > self.peak_cpu {
            self.peak_cpu = cpu;
            self.peak_name = digest.busiest_name.clone();
            self.peak_at = unix_now();
        }
        let peak = if self.peak_cpu > 0.0 {
            Some(peak_sentence(self.peak_cpu, self.peak_name.as_deref(), self.peak_at))
        } else {
            None
        };

        let disk_frac = self.volumes.first().map(|v| {
            if v.total == 0 { 0.0 } else { 1.0 - v.free as f64 / v.total as f64 }
        }).unwrap_or(0.0);
        let mem_frac = if self.sys.total_memory() == 0 {
            0.0
        } else {
            self.sys.used_memory() as f64 / self.sys.total_memory() as f64
        };
        let glm_used = glm.as_ref().and_then(|g| g.five_remaining).map(|r| 1.0 - r / 100.0);
        let java_level = (digest.java_memory as f64 / (2.0 * 1_073_741_824.0)).min(1.0);
        let dash = Dash {
            cpu: bucket(cpu / 100.0),
            memory: bucket(mem_frac),
            network: bucket(traffic(net_in)),
            disk: bucket(disk_frac),
            io: bucket(traffic(io_read + io_write)),
            battery: bucket(self.battery.as_ref().map(|b| b.percent).unwrap_or(100.0) / 100.0),
            glm: bucket(glm_used.unwrap_or(0.0)),
            java: bucket(java_level),
            processes: 0.75,
            note: 0.8,
        };
        self.attention.note_cpu(cpu);
        let mut active = cards.to_vec();
        if self.battery.is_none() {
            active.retain(|c| c != "电池");
        }
        let attention = self.attention.resolve(self.battery.as_ref(), glm.as_ref().and_then(|g| g.five_remaining), &active);

        Snapshot {
            cpu,
            cores,
            uptime_sec: System::uptime(),
            load1: self.load,
            mem_used: self.sys.used_memory(),
            mem_total: self.sys.total_memory(),
            mem_free: self.sys.free_memory(),
            mem_avail: self.sys.available_memory(),
            swap_used: self.sys.used_swap(),
            swap_total: self.sys.total_swap(),
            net_in,
            net_out,
            ips: self.ips.clone(),
            volumes: self.volumes.clone(),
            io_read,
            io_write,
            io_read_total,
            io_write_total,
            battery: self.battery.clone(),
            has_battery: self.battery.is_some(),
            cpu_hist: self.cpu_hist.clone(),
            mem_hist: self.mem_hist.clone(),
            net_down_hist: self.down_hist.clone(),
            net_up_hist: self.up_hist.clone(),
            io_read_hist: self.io_r_hist.clone(),
            io_write_hist: self.io_w_hist.clone(),
            digest,
            dash,
            attention,
            peak,
            processes: if watch_procs { Some(rows) } else { None },
            glm,
        }
    }

    fn network(&mut self, now: Instant) -> (f64, f64) {
        self.nets.refresh(false);
        let elapsed = self.last_net_at.map(|t| now.duration_since(t).as_secs_f64()).unwrap_or(0.0);
        let mut next = HashMap::new();
        for (name, data) in &self.nets {
            let key = name.to_string();
            if is_loopback(&key) {
                continue;
            }
            let inn = data.received();
            let out = data.transmitted();
            next.insert(key, (inn, out));
        }
        let rates = if elapsed > 0.05 {
            let mut din = 0u64;
            let mut dout = 0u64;
            for (k, (inn, out)) in &next {
                if let Some((pin, pout)) = self.last_net.get(k) {
                    din += inn.saturating_sub(*pin);
                    dout += out.saturating_sub(*pout);
                }
            }
            (din as f64 / elapsed, dout as f64 / elapsed)
        } else {
            (0.0, 0.0)
        };
        self.last_net = next;
        self.last_net_at = Some(now);
        rates
    }
}

pub fn kill_pid(pid: u32) -> bool {
    let mut sys = System::new();
    let id = Pid::from_u32(pid);
    sys.refresh_processes(ProcessesToUpdate::Some(&[id]), false);
    sys.process(id).map(|p| p.kill()).unwrap_or(false)
}

fn disk_io(disks: &Disks) -> (f64, f64, u64, u64) {
    let mut read = 0u64;
    let mut write = 0u64;
    let mut total_r = 0u64;
    let mut total_w = 0u64;
    for disk in disks.list() {
        let u = disk.usage();
        read += u.read_bytes;
        write += u.written_bytes;
        total_r += u.total_read_bytes;
        total_w += u.total_written_bytes;
    }
    // Disks 的增量是两次 refresh 之间的字节。采样间隔约 1 秒，直接当每秒。
    (read as f64, write as f64, total_r, total_w)
}

fn read_volumes(disks: &Disks) -> Vec<Volume> {
    let mut vols: Vec<Volume> = disks
        .list()
        .iter()
        .filter(|d| d.total_space() > 1_000_000_000)
        .map(|d| Volume {
            name: d.name().to_string_lossy().to_string(),
            mount: d.mount_point().to_string_lossy().to_string(),
            total: d.total_space(),
            free: d.available_space(),
        })
        .collect();
    vols.sort_by_key(|v| volume_rank(&v.mount));
    vols
}

fn volume_rank(mount: &str) -> u8 {
    if mount == "/" || mount.eq_ignore_ascii_case("C:\\") || mount.eq_ignore_ascii_case("C:") {
        0
    } else {
        1
    }
}

fn read_ips() -> Vec<Addr> {
    let Ok(list) = if_addrs::get_if_addrs() else { return Vec::new() };
    list.into_iter()
        .filter(|iface| !iface.is_loopback())
        .filter_map(|iface| match iface.addr {
            if_addrs::IfAddr::V4(v) => Some(Addr { name: iface.name, ip: v.ip.to_string() }),
            if_addrs::IfAddr::V6(_) => None,
        })
        .collect()
}

fn read_battery() -> Option<Battery> {
    let manager = battery::Manager::new().ok()?;
    let mut bats = manager.batteries().ok()?;
    let bat = bats.next()?.ok()?;
    let percent = bat.state_of_charge().get::<battery::units::ratio::percent>();
    let state = bat.state();
    let charging = state == battery::State::Charging;
    let on_ac = !matches!(state, battery::State::Discharging | battery::State::Empty);
    let minutes = if charging {
        bat.time_to_full()
    } else {
        bat.time_to_empty()
    }
    .map(|t| t.get::<battery::units::time::minute>() as i32)
    .filter(|m| *m >= 0);
    Some(Battery { percent: percent as f64, charging, on_ac, minutes })
}

fn push(buf: &mut Vec<f64>, value: f64) {
    buf.push(value);
    if buf.len() > HISTORY {
        buf.drain(0..buf.len() - HISTORY);
    }
}

fn bucket(value: f64) -> f64 {
    (value.clamp(0.0, 1.0) * 8.0).round() / 8.0
}

fn traffic(bytes_per_sec: f64) -> f64 {
    let mb = bytes_per_sec / 1_048_576.0;
    if mb <= 0.0 {
        0.0
    } else {
        (1.0 + mb).log10() / (1.0 + 20.0_f64).log10()
    }
    .min(1.0)
}

fn is_loopback(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    n == "lo" || n == "lo0" || n.contains("loopback")
}

fn is_noise(name: &str) -> bool {
    matches!(
        name,
        "kernel_task"
            | "WindowServer"
            | "loginwindow"
            | "sysmond"
            | "corespotlightd"
            | "mds"
            | "mds_stores"
            | "SysMon"
            | "System"
            | "Idle"
            | "Registry"
            | "Secure System"
            | "Memory Compression"
            | "smss.exe"
            | "csrss.exe"
            | "wininit.exe"
            | "winlogon.exe"
            | "services.exe"
            | "lsass.exe"
            | "dwm.exe"
            | "SysMon.exe"
            | "sysmon.exe"
    )
}

fn card_token(name: &str) -> Option<String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return None;
    }
    let count = trimmed.chars().count();
    if count <= 14 {
        Some(trimmed.to_string())
    } else {
        Some(trimmed.chars().take(12).collect())
    }
}

fn pretty_name(path: Option<&std::path::Path>, comm: &str) -> String {
    if let Some(path) = path {
        let text = path.to_string_lossy();
        if let Some(app) = text.split(['/', '\\']).find(|p| p.ends_with(".app")) {
            return app.trim_end_matches(".app").to_string();
        }
        if let Some(file) = path.file_name() {
            let n = file.to_string_lossy();
            let n = n.trim_end_matches(".exe");
            if !n.is_empty() {
                return n.to_string();
            }
        }
    }
    if comm.is_empty() { "进程".into() } else { comm.to_string() }
}

fn is_script_runtime(base: &str) -> bool {
    matches!(base, "node" | "nodejs" | "python" | "Python" | "node.exe" | "python.exe")
        || base.starts_with("python3")
}

fn java_label(argv: &[String]) -> Option<String> {
    let args = argv.iter().skip(1);
    let list: Vec<&str> = args.map(|s| s.as_str()).collect();
    if let Some(i) = list.iter().position(|s| *s == "-jar") {
        if let Some(path) = list.get(i + 1) {
            return std::path::Path::new(path)
                .file_name()
                .map(|s| s.to_string_lossy().into_owned());
        }
    }
    let class = list.iter().find(|s| {
        !s.starts_with('-') && !s.ends_with(".jar") && !s.contains('/') && !s.contains(':') && !s.contains('\\') && s.contains('.')
    });
    if let Some(cls) = class {
        return cls.split('.').next_back().map(|s| s.to_string());
    }
    list.iter().find(|s| !s.starts_with('-')).map(|s| (*s).to_string())
}

fn script_label(argv: &[String]) -> Option<String> {
    for arg in argv.iter().skip(1) {
        if arg.starts_with('-') {
            continue;
        }
        let base = std::path::Path::new(arg)
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        if base.ends_with(".js")
            || base.ends_with(".mjs")
            || base.ends_with(".cjs")
            || base.ends_with(".ts")
            || base.ends_with(".py")
        {
            return Some(base);
        }
    }
    None
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn day_key() -> String {
    let secs = unix_now();
    let days = secs / 86400;
    format!("{days}")
}

fn peak_sentence(cpu: f64, name: Option<&str>, at: u64) -> String {
    let time = clock(at);
    let cpu_text = format!("{cpu:.1} %");
    if let Some(name) = name {
        if !name.is_empty() {
            return format!("今天 {time} CPU 到过 {cpu_text}，当时是 {name}");
        }
    }
    format!("今天 {time} CPU 到过 {cpu_text}")
}

fn clock(at: u64) -> String {
    let day = ((at as i64 + local_offset()) % 86400 + 86400) % 86400;
    let h = day / 3600;
    let m = (day % 3600) / 60;
    format!("{h:02}:{m:02}")
}

fn local_offset() -> i64 {
    #[cfg(unix)]
    {
        let t = unsafe { libc::time(std::ptr::null_mut()) };
        let mut tm = unsafe { std::mem::zeroed::<libc::tm>() };
        unsafe { libc::localtime_r(&t, &mut tm) };
        tm.tm_gmtoff
    }
    #[cfg(windows)]
    {
        #[repr(C)]
        struct SystemTime {
            year: u16, month: u16, dow: u16, day: u16,
            hour: u16, minute: u16, second: u16, ms: u16,
        }
        #[repr(C)]
        struct TimeZone {
            bias: i32,
            standard_name: [u16; 32],
            standard_date: SystemTime,
            standard_bias: i32,
            daylight_name: [u16; 32],
            daylight_date: SystemTime,
            daylight_bias: i32,
        }
        extern "system" {
            fn GetTimeZoneInformation(tz: *mut TimeZone) -> u32;
        }
        let mut tz = unsafe { std::mem::zeroed::<TimeZone>() };
        let kind = unsafe { GetTimeZoneInformation(&mut tz) };
        let extra = if kind == 2 { tz.daylight_bias } else { tz.standard_bias };
        -((tz.bias + extra) as i64) * 60
    }
}

#[derive(Default)]
struct Attention {
    cpu: f64,
    cpu_hot: u32,
    latched: Option<String>,
}

impl Attention {
    fn note_cpu(&mut self, value: f64) {
        self.cpu = value;
        if value >= 85.0 {
            self.cpu_hot += 1;
        } else if value < 70.0 {
            self.cpu_hot = 0;
        }
    }

    fn resolve(&mut self, battery: Option<&Battery>, glm_remaining: Option<f64>, cards: &[String]) -> Option<String> {
        let has = |name: &str| cards.iter().any(|c| c == name);
        let cpu_wanted = has("CPU") && self.cpu_hot >= 3;
        let cpu_clear = self.cpu < 70.0 || !has("CPU");
        let battery_wanted = has("电池")
            && battery.map(|b| b.percent <= 20.0 && !b.charging && !b.on_ac).unwrap_or(false);
        let battery_clear = battery.map(|b| b.percent >= 30.0 || b.charging || b.on_ac).unwrap_or(true);
        let glm_wanted = has("智谱") && glm_remaining.map(|v| v <= 15.0).unwrap_or(false);
        let glm_clear = !has("智谱") || glm_remaining.map(|v| v >= 25.0).unwrap_or(true);

        if let Some(latched) = &self.latched {
            let still = match latched.as_str() {
                "CPU" => !cpu_clear,
                "电池" => !battery_clear,
                "智谱" => !glm_clear,
                _ => false,
            };
            if still {
                return Some(latched.clone());
            }
            self.latched = None;
        }
        let next = if battery_wanted {
            Some("电池".to_string())
        } else if glm_wanted {
            Some("智谱".to_string())
        } else if cpu_wanted {
            Some("CPU".to_string())
        } else {
            None
        };
        self.latched = next.clone();
        next
    }
}

pub fn fetch_glm(key: &str) -> Glm {
    let key = key.trim();
    if key.is_empty() {
        return Glm { level: None, error: Some("未设置 API Key".into()), windows: Vec::new(), five_remaining: None };
    }
    let result = ureq::get("https://open.bigmodel.cn/api/monitor/usage/quota/limit")
        .header("Authorization", key)
        .header("Accept-Language", "zh-CN")
        .header("Content-Type", "application/json")
        .call();
    match result {
        Ok(mut res) => match res.body_mut().read_to_string() {
            Ok(text) => parse_glm(&text),
            Err(err) => Glm { level: None, error: Some(format!("网络错误:{err}")), windows: Vec::new(), five_remaining: None },
        },
        Err(err) => Glm { level: None, error: Some(format!("网络错误:{err}")), windows: Vec::new(), five_remaining: None },
    }
}

#[derive(serde::Deserialize)]
struct Envelope {
    code: Option<i32>,
    msg: Option<String>,
    success: Option<bool>,
    data: Option<GlmData>,
}

#[derive(serde::Deserialize)]
struct GlmData {
    limits: Option<Vec<RawLimit>>,
    level: Option<String>,
}

#[derive(serde::Deserialize)]
struct RawLimit {
    #[serde(rename = "type")]
    kind: String,
    unit: Option<i32>,
    number: Option<i32>,
    percentage: Option<f64>,
    usage: Option<f64>,
    #[serde(rename = "currentValue")]
    current_value: Option<f64>,
    remaining: Option<f64>,
}

fn parse_glm(text: &str) -> Glm {
    let Ok(envelope) = serde_json::from_str::<Envelope>(text) else {
        return Glm { level: None, error: Some("返回格式无法解析".into()), windows: Vec::new(), five_remaining: None };
    };
    if envelope.success == Some(false) || envelope.code.map(|c| c != 200).unwrap_or(false) {
        return Glm {
            level: None,
            error: Some(envelope.msg.unwrap_or_else(|| "接口返回失败".into())),
            windows: Vec::new(),
            five_remaining: None,
        };
    }
    let mut token_slots = 0;
    let mut windows = Vec::new();
    for raw in envelope.data.as_ref().and_then(|d| d.limits.as_ref()).into_iter().flatten() {
        if raw.kind != "TOKENS_LIMIT" && raw.kind != "TIME_LIMIT" {
            continue;
        }
        let slot = if raw.kind == "TOKENS_LIMIT" { token_slots } else { 0 };
        if raw.kind == "TOKENS_LIMIT" {
            token_slots += 1;
        }
        let used = raw.percentage.unwrap_or(0.0);
        let remaining = (100.0 - used).max(0.0);
        let label = glm_label(&raw.kind, slot, raw.unit, raw.number);
        let extra = if raw.kind == "TIME_LIMIT" {
            raw.usage.filter(|u| *u > 0.0).map(|usage| {
                let left = raw.remaining.unwrap_or((usage - raw.current_value.unwrap_or(0.0)).max(0.0));
                format!("{} / {} 次", left as i64, usage as i64)
            })
        } else {
            None
        };
        windows.push(GlmWindow {
            five_hour: raw.kind == "TOKENS_LIMIT" && slot == 0,
            label,
            used,
            remaining,
            extra,
        });
    }
    if windows.is_empty() {
        return Glm { level: None, error: Some("接口没有返回任何配额窗口".into()), windows, five_remaining: None };
    }
    let five_remaining = windows.iter().find(|w| w.five_hour).map(|w| w.remaining);
    Glm { level: envelope.data.and_then(|d| d.level), error: None, windows, five_remaining }
}

fn glm_label(kind: &str, slot: i32, unit: Option<i32>, number: Option<i32>) -> String {
    match kind {
        "TOKENS_LIMIT" => {
            if unit == Some(3) {
                if let Some(n) = number.filter(|n| *n > 0) {
                    return format!("每 {n} 小时");
                }
            }
            if unit == Some(6) {
                return "本周".into();
            }
            if slot == 0 { "每 5 小时".into() } else { "本周".into() }
        }
        _ => "本月工具".into(),
    }
}
